#!/bin/bash

# Скрипт для Debian 10-12 и Ubuntu 20.04-24.04

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Константы путей и настроек
INSTALL_PATH="/usr/local/bin"
SCRIPT_NAME="$(basename "$0")"
INSTALLED_SCRIPT_PATH="$INSTALL_PATH/$SCRIPT_NAME"

MTPROXY_USER="mtproxy"
MTPROXY_GROUP="mtproxy"
MTPROXY_BINARY="/usr/local/bin/mtproto-proxy"
CONFIG_DIR="/etc/mtproxy"
CONFIG_FILE="$CONFIG_DIR/config"
PROXY_SECRET_FILE="$CONFIG_DIR/proxy-secret"
PROXY_MULTI_CONF_FILE="$CONFIG_DIR/proxy-multi.conf"
SERVICE_FILE="/etc/systemd/system/mtproxy.service"
STATE_DIR="/var/lib/mtproxy"
LOG_DIR="/var/log/mtproxy"
UPDATE_SCRIPT="/usr/local/bin/mtproxy-update"
CRON_FILE="/etc/cron.d/mtproxy-update"
LOGROTATE_FILE="/etc/logrotate.d/mtproxy"
SYSCTL_FILE="/etc/sysctl.conf"
SYSCTL_SETTING="net.core.somaxconn = 1024"

DEFAULT_EXTERNAL_PORT=443
DEFAULT_INTERNAL_PORT=8008
PUBLIC_IP_PLACEHOLDER="ВАШ_ПУБЛИЧНЫЙ_IP_АДРЕС"

CURRENT_SECRET=""
CURRENT_EXTERNAL_PORT=""
CURRENT_INTERNAL_PORT=""
CURRENT_ADTAG=""
MANAGEMENT_SCRIPT_PATH=""

COMMAND="install"
CLI_ADTAG_VALUE=""
CLI_ADTAG_PROVIDED=false

print_status() {
    echo -e "${GREEN}* ${NC}$1"
}

print_warning() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
}

print_error() {
    echo -e "${RED}[ОШИБКА]${NC} $1"
}

print_header() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================${NC}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_management_script_path() {
    if [ -n "$MANAGEMENT_SCRIPT_PATH" ]; then
        printf '%s\n' "$MANAGEMENT_SCRIPT_PATH"
        return 0
    fi

    if [ -x "$INSTALLED_SCRIPT_PATH" ]; then
        MANAGEMENT_SCRIPT_PATH="$INSTALLED_SCRIPT_PATH"
    else
        MANAGEMENT_SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || true)"

        if [ -z "$MANAGEMENT_SCRIPT_PATH" ] && command_exists realpath; then
            MANAGEMENT_SCRIPT_PATH="$(realpath "$0" 2>/dev/null || true)"
        fi

        if [ -z "$MANAGEMENT_SCRIPT_PATH" ]; then
            MANAGEMENT_SCRIPT_PATH="$0"
        fi
    fi

    printf '%s\n' "$MANAGEMENT_SCRIPT_PATH"
}

format_script_command() {
    local script_path=""
    local arg=""

    script_path="$(get_management_script_path)"
    printf 'sudo %q' "$script_path"

    for arg in "$@"; do
        printf ' %s' "$arg"
    done

    printf '\n'
}

ensure_script_available() {
    if [ "$(readlink -f "$0")" = "$INSTALLED_SCRIPT_PATH" ]; then
        return 0
    fi

    print_header "Подготовка скрипта"
    print_status "Установка скрипта в $INSTALL_PATH для удобных команд управления..."

    if [ ! -d "$INSTALL_PATH" ]; then
        print_error "Каталог $INSTALL_PATH не существует. Установка скрипта невозможна."
        print_warning "Команды управления будут доступны только при запуске скрипта по текущему пути."
        return 0
    fi

    if sudo install -m 755 "$0" "$INSTALLED_SCRIPT_PATH"; then
        print_status "Скрипт скопирован. Перезапуск из $INSTALL_PATH..."
        exec sudo "$INSTALLED_SCRIPT_PATH" "$@"
    fi

    print_error "Не удалось установить скрипт в $INSTALL_PATH."
    print_warning "Команды управления будут доступны только при запуске скрипта по текущему пути."
}

confirm_action() {
    local message="$1"
    local confirmation=""

    print_warning "$message"
    echo "Введите 'y' или '+' для подтверждения и нажмите Enter:"
    read -r confirmation

    [[ "$confirmation" == "y" || "$confirmation" == "Y" || "$confirmation" == "+" ]]
}

generate_secret() {
    head -c 16 /dev/urandom | xxd -ps
}

canonicalize_adtag_input() {
    local value="$1"

    value="$(echo "$value" | tr -d '[:space:]')"
    case "${value,,}" in
        "")
            printf '%s\n' ""
            return 0
            ;;
        clear|none|disable|off|remove|-)
            printf '%s\n' ""
            return 0
            ;;
    esac

    value="$(echo "$value" | tr '[:upper:]' '[:lower:]')"
    if [[ "$value" =~ ^[a-f0-9]{32}$ ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    return 1
}

prompt_for_adtag_value() {
    local __resultvar="$1"
    local allow_empty="${2:-true}"
    local input=""
    local normalized=""

    while true; do
        echo "Введите adtag (32 hex-символа)."
        if [ "$allow_empty" = true ]; then
            echo "Оставьте поле пустым, чтобы пропустить настройку или удалить текущий adtag."
        fi
        echo -n "adtag: "
        read -r input

        if [ -z "$input" ] && [ "$allow_empty" = true ]; then
            printf -v "$__resultvar" '%s' ""
            return 0
        fi

        if normalized="$(canonicalize_adtag_input "$input")"; then
            printf -v "$__resultvar" '%s' "$normalized"
            return 0
        fi

        print_error "adtag должен содержать ровно 32 шестнадцатеричных символа."
    done
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 <= 65535 ))
}

is_port_in_use() {
    local port="$1"
    sudo ss -tulnp | grep -q ":${port}\b"
}

prompt_for_port() {
    local __resultvar="$1"
    local port_label="$2"
    local default_port="$3"
    local conflicting_port="${4:-}"
    local conflicting_label="${5:-}"
    local input=""

    while true; do
        print_header "Выбор ${port_label} порта"
        echo "Напишите желаемый ${port_label} порт (по умолчанию используется ${default_port})."
        echo -n "Если порт подходит — просто нажмите Enter: "
        read -r input

        if [ -z "$input" ]; then
            input="$default_port"
        fi

        if ! is_valid_port "$input"; then
            print_error "Неверный порт: $input."
            continue
        fi

        if [ -n "$conflicting_port" ] && [ "$input" -eq "$conflicting_port" ]; then
            print_error "Порт не может совпадать с ${conflicting_label} портом (${conflicting_port})."
            continue
        fi

        print_status "Проверка занятости порта $input..."
        if is_port_in_use "$input"; then
            print_error "Порт $input занят. Выберите другой."
            continue
        fi

        print_status "Порт $input свободен."
        printf -v "$__resultvar" '%s' "$input"
        return 0
    done
}

sanitize_ip_candidate() {
    local value="$1"

    value="$(printf '%s\n' "$value" | head -n 1)"
    value="${value//$'\r'/}"
    value="${value//[[:space:]]/}"

    printf '%s\n' "$value"
}

is_valid_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a octets=()
    local octet=""

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1

    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done

    return 0
}

is_valid_ipv6() {
    local ip="$1"

    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" =~ [0-9A-Fa-f] ]] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1

    return 0
}

fetch_public_ip() {
    local ip_version="$1"
    local validator="$2"
    shift 2

    local url=""
    local response=""

    for url in "$@"; do
        response="$(curl "-${ip_version}" -fsSL --connect-timeout 3 --max-time 5 "$url" 2>/dev/null || true)"
        response="$(sanitize_ip_candidate "$response")"

        if [ -n "$response" ] && "$validator" "$response"; then
            printf '%s\n' "$response"
            return 0
        fi
    done

    return 1
}

get_public_ipv4() {
    fetch_public_ip 4 is_valid_ipv4 \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://ifconfig.me/ip" || true
}

get_public_ipv6() {
    fetch_public_ip 6 is_valid_ipv6 \
        "https://api6.ipify.org" \
        "https://ipv6.icanhazip.com" \
        "https://ifconfig.me/ip" || true
}

get_config_value() {
    local key="$1"

    if [ ! -f "$CONFIG_FILE" ]; then
        return 0
    fi

    sudo grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | head -n 1 | cut -d '=' -f 2- || true
}

extract_service_option() {
    local option="$1"

    if [ ! -f "$SERVICE_FILE" ]; then
        return 0
    fi

    sudo sed -n "s/^ExecStart=.* ${option} \([^ ]*\).*/\1/p" "$SERVICE_FILE" 2>/dev/null | head -n 1 || true
}

require_existing_installation() {
    if [ ! -f "$SERVICE_FILE" ] || [ ! -x "$MTPROXY_BINARY" ]; then
        print_error "MTProxy не найден. Сначала выполните установку."
        exit 1
    fi
}

load_current_settings() {
    CURRENT_SECRET="$(get_config_value SECRET)"
    CURRENT_EXTERNAL_PORT="$(get_config_value EXTERNAL_PORT)"
    CURRENT_INTERNAL_PORT="$(get_config_value INTERNAL_PORT)"
    CURRENT_ADTAG="$(get_config_value ADTAG)"

    if [ -z "$CURRENT_SECRET" ]; then
        CURRENT_SECRET="$(extract_service_option "-S")"
    fi
    if [ -z "$CURRENT_EXTERNAL_PORT" ]; then
        CURRENT_EXTERNAL_PORT="$(extract_service_option "-H")"
    fi
    if [ -z "$CURRENT_INTERNAL_PORT" ]; then
        CURRENT_INTERNAL_PORT="$(extract_service_option "-p")"
    fi
    if [ -z "$CURRENT_ADTAG" ]; then
        CURRENT_ADTAG="$(extract_service_option "-P")"
    fi

    if [ -n "$CURRENT_ADTAG" ]; then
        if ! CURRENT_ADTAG="$(canonicalize_adtag_input "$CURRENT_ADTAG")"; then
            print_warning "Текущий adtag в конфигурации выглядит некорректно и будет проигнорирован."
            CURRENT_ADTAG=""
        fi
    fi

    if [ -z "$CURRENT_SECRET" ] || [ -z "$CURRENT_EXTERNAL_PORT" ] || [ -z "$CURRENT_INTERNAL_PORT" ]; then
        print_error "Не удалось определить текущие параметры MTProxy."
        print_error "Проверьте файлы $CONFIG_FILE и $SERVICE_FILE."
        exit 1
    fi
}

write_mtproxy_config() {
    local secret="$1"
    local external_port="$2"
    local internal_port="$3"
    local adtag="$4"

    sudo mkdir -p "$CONFIG_DIR"
    {
        echo "SECRET=$secret"
        echo "EXTERNAL_PORT=$external_port"
        echo "INTERNAL_PORT=$internal_port"
        echo "ADTAG=$adtag"
    } | sudo tee "$CONFIG_FILE" >/dev/null

    sudo chown "$MTPROXY_USER:$MTPROXY_GROUP" "$CONFIG_FILE" 2>/dev/null || true
    sudo chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

build_execstart() {
    local internal_port="$1"
    local external_port="$2"
    local secret="$3"
    local adtag="$4"
    local command="$MTPROXY_BINARY -u $MTPROXY_USER -p $internal_port -H $external_port -S $secret"

    if [ -n "$adtag" ]; then
        command="$command -P $adtag"
    fi

    command="$command --aes-pwd $PROXY_SECRET_FILE $PROXY_MULTI_CONF_FILE -M 1"
    printf '%s\n' "$command"
}

write_systemd_service() {
    local internal_port="$1"
    local external_port="$2"
    local secret="$3"
    local adtag="$4"
    local exec_start=""

    exec_start="$(build_execstart "$internal_port" "$external_port" "$secret" "$adtag")"

    {
        cat <<UNIT_FILE_EOF
[Unit]
Description=MTProxy
After=network.target

[Service]
Type=simple
User=$MTPROXY_USER
Group=$MTPROXY_GROUP
WorkingDirectory=$STATE_DIR
ExecStart=$exec_start
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtproxy
UNIT_FILE_EOF

        if (( external_port <= 1024 )); then
            echo "AmbientCapabilities=CAP_NET_BIND_SERVICE"
            echo "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
        fi

        cat <<UNIT_FILE_EOF
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT_FILE_EOF
    } | sudo tee "$SERVICE_FILE" >/dev/null
}

configure_binary_capability() {
    local external_port="$1"

    print_status "Настройка привилегий портов..."
    if (( external_port <= 1024 )); then
        sudo setcap 'cap_net_bind_service=+ep' "$MTPROXY_BINARY"
        print_status "Права CAP_NET_BIND_SERVICE установлены."
    else
        sudo setcap -r "$MTPROXY_BINARY" 2>/dev/null || true
        print_status "CAP_NET_BIND_SERVICE не требуется."
    fi
}

mtproxy_supports_adtag() {
    [ -x "$MTPROXY_BINARY" ] || return 1
    "$MTPROXY_BINARY" --help 2>&1 | grep -q -- "proxy-tag"
}

restart_mtproxy_service() {
    local success_message="$1"

    print_status "Перезагрузка unit файлов systemd..."
    sudo systemctl daemon-reload
    print_status "Перезапуск сервиса MTProxy..."

    if sudo systemctl restart mtproxy; then
        print_status "$success_message"
    else
        print_error "Не удалось перезапустить сервис MTProxy."
        print_error "Проверьте логи: sudo journalctl -u mtproxy"
        exit 1
    fi
}

start_mtproxy_service() {
    print_status "Перезагрузка systemd..."
    sudo systemctl daemon-reload
    print_status "Включение сервиса в автозагрузку..."
    sudo systemctl enable mtproxy >/dev/null

    print_status "Запуск сервиса MTProxy..."
    if sudo systemctl start mtproxy; then
        print_status "Сервис MTProxy запущен."
    else
        print_error "Не удалось запустить сервис MTProxy. Проверьте логи: sudo journalctl -u mtproxy -f"
        exit 1
    fi
}

print_management_commands() {
    print_header "Команды управления"
    echo "• Старт:"
    echo "sudo systemctl start mtproxy"
    echo "• Стоп:"
    echo "sudo systemctl stop mtproxy"
    echo "• Перезапуск:"
    echo "sudo systemctl restart mtproxy"
    echo "• Статус:"
    echo "sudo systemctl status mtproxy"
    echo "• Логи:"
    echo "sudo journalctl -u mtproxy -f"
    echo "• Обновить конфиги Telegram:"
    echo "sudo mtproxy-update"
    echo "• Проверить работу внешнего порта:"
    echo "sudo ss -tulnp | grep mtproto-proxy"
    echo "• Изменить порт:"
    format_script_command reinstall
    echo "• Изменить секрет:"
    format_script_command update-secret
    echo "• Изменить или установить adtag:"
    format_script_command update-adtag
    echo "• Удалить adtag:"
    format_script_command update-adtag clear
    echo "• Удалить полностью:"
    format_script_command delete
}

print_proxy_links() {
    local label="$1"
    local server_ip="$2"

    [ -n "$server_ip" ] || return 0

    echo -e "${GREEN}*${NC} Ссылка (${label}):"
    echo -e "${GREEN}*${NC} https://t.me/proxy?server=${server_ip}&port=${CURRENT_EXTERNAL_PORT}&secret=${CURRENT_SECRET}"
    echo -e "${GREEN}*${NC} Ссылка ТОЛЬКО для приложения (${label}):"
    echo -e "${GREEN}*${NC} tg://proxy?server=${server_ip}&port=${CURRENT_EXTERNAL_PORT}&secret=${CURRENT_SECRET}"
}

print_mtproxy_details() {
    local public_ipv4=""
    local public_ipv6=""

    public_ipv4="$(get_public_ipv4)"
    public_ipv6="$(get_public_ipv6)"

    print_header "Сведения о MTProxy"
    echo -e "${BLUE}ВАЖНОЕ НАПОМИНАНИЕ!${NC}"
    echo -e "${BLUE}Откройте выбранный ВНЕШНИЙ порт (${CURRENT_EXTERNAL_PORT}/tcp) в Firewall и/или у вашего провайдера, если это необходимо!${NC}"
    echo -e "${GREEN}*${NC} Внешний порт (Интернет <-> MTProxy): ${CURRENT_EXTERNAL_PORT}"
    echo -e "${GREEN}*${NC} Внутренний порт (MTProxy <-> Telegram): ${CURRENT_INTERNAL_PORT}"

    if [ -z "$public_ipv4" ] && [ -z "$public_ipv6" ]; then
        print_warning "Не удалось определить публичные IPv4 и IPv6 адреса. Используйте ваш реальный публичный IP вместо 'ВАШ_ПУБЛИЧНЫЙ_IP_АДРЕС'."
    elif [ -z "$public_ipv4" ] && [ -n "$public_ipv6" ]; then
        print_warning "Публичный IPv4 определить не удалось. Выведены ссылки только для IPv6."
    fi

    if [ -n "$public_ipv4" ]; then
        echo -e "${GREEN}*${NC} Публичный IPv4 сервера: ${public_ipv4}"
    fi

    if [ -n "$public_ipv6" ]; then
        echo -e "${GREEN}*${NC} Публичный IPv6 сервера: ${public_ipv6}"
    fi

    echo -e "${GREEN}*${NC} Секрет MTProxy: ${CURRENT_SECRET}"

    if [ -n "$CURRENT_ADTAG" ]; then
        echo -e "${GREEN}*${NC} adtag: ${CURRENT_ADTAG}"
    else
        print_warning "adtag пока не задан. После регистрации прокси в @MTProxybot выполните: $(format_script_command update-adtag)"
    fi

    if [ -n "$public_ipv4" ]; then
        print_proxy_links "IPv4" "$public_ipv4"
    fi

    if [ -n "$public_ipv6" ]; then
        print_proxy_links "IPv6" "$public_ipv6"
    fi

    if [ -z "$public_ipv4" ] && [ -z "$public_ipv6" ]; then
        print_proxy_links "укажите адрес вручную" "$PUBLIC_IP_PLACEHOLDER"
    fi
}

print_adtag_help() {
    print_header "Реклама через @MTProxybot"
    echo "adtag можно получить только после того, как секрет уже известен и прокси зарегистрирован в @MTProxybot."
    echo "Поэтому базовая установка сначала запускает прокси, а adtag можно применить сразу после получения или позже отдельной командой."
    echo "Команда для смены adtag: $(format_script_command update-adtag)"
}

apply_adtag_change() {
    local requested_adtag="$1"
    local context="$2"
    local normalized_adtag=""

    require_existing_installation
    load_current_settings

    if ! normalized_adtag="$(canonicalize_adtag_input "$requested_adtag")"; then
        print_error "adtag должен содержать ровно 32 шестнадцатеричных символа."
        exit 1
    fi

    if [ -n "$normalized_adtag" ] && ! mtproxy_supports_adtag; then
        print_error "Собранный бинарник MTProxy не поддерживает параметр -P/--proxy-tag."
        exit 1
    fi

    if [ "$normalized_adtag" = "$CURRENT_ADTAG" ]; then
        if [ -n "$normalized_adtag" ]; then
            print_status "Указанный adtag уже применяется. Изменения не требуются."
        else
            print_status "adtag уже не задан. Изменения не требуются."
        fi
        return 0
    fi

    write_mtproxy_config "$CURRENT_SECRET" "$CURRENT_EXTERNAL_PORT" "$CURRENT_INTERNAL_PORT" "$normalized_adtag"
    write_systemd_service "$CURRENT_INTERNAL_PORT" "$CURRENT_EXTERNAL_PORT" "$CURRENT_SECRET" "$normalized_adtag"
    configure_binary_capability "$CURRENT_EXTERNAL_PORT"
    restart_mtproxy_service "Сервис MTProxy успешно перезапущен."
    load_current_settings

    if [ -n "$CURRENT_ADTAG" ]; then
        print_status "adtag успешно применён (${context})."
    else
        print_status "adtag удалён (${context})."
    fi
}

update_mtproxy_secret() {
    local new_secret=""

    print_header "Обновление секрета MTProxy"
    require_existing_installation
    load_current_settings

    print_status "Генерация нового секрета..."
    new_secret="$(generate_secret)"

    if [ -n "$CURRENT_ADTAG" ]; then
        print_warning "Текущий adtag будет сброшен, потому что после смены секрета для него нужен новый тег от @MTProxybot."
    fi

    write_mtproxy_config "$new_secret" "$CURRENT_EXTERNAL_PORT" "$CURRENT_INTERNAL_PORT" ""
    write_systemd_service "$CURRENT_INTERNAL_PORT" "$CURRENT_EXTERNAL_PORT" "$new_secret" ""
    configure_binary_capability "$CURRENT_EXTERNAL_PORT"
    restart_mtproxy_service "Сервис MTProxy успешно перезапущен с новым секретом."
    load_current_settings

    echo
    print_header "Обновление секрета MTProxy успешно завершено!"
    print_warning "Удалите старый MTProxy в Telegram. Если используете adtag, получите новый тег в @MTProxybot и примените его отдельной командой."
    print_mtproxy_details
}

update_mtproxy_adtag() {
    local requested_adtag=""

    print_header "Изменение adtag MTProxy"

    if [ "$CLI_ADTAG_PROVIDED" = true ]; then
        requested_adtag="$CLI_ADTAG_VALUE"
    else
        if [ ! -t 0 ]; then
            print_error "Для неинтерактивного режима передайте adtag так: $(format_script_command update-adtag ADTAG)"
            print_error "Чтобы удалить adtag, используйте: $(format_script_command update-adtag clear)"
            exit 1
        fi

        prompt_for_adtag_value requested_adtag true
    fi

    apply_adtag_change "$requested_adtag" "через команду update-adtag"
}

uninstall_mtproxy() {
    local silent_prompt=false

    if [ "${1:-}" = "--silent-prompt" ]; then
        silent_prompt=true
    else
        print_header "Удаление MTProxy"
        if ! confirm_action "Это полностью удалит MTProxy и все его файлы."; then
            print_status "Удаление отменено."
            exit 0
        fi
    fi

    print_status "Остановка и отключение сервиса..."
    sudo systemctl stop mtproxy 2>/dev/null || true
    sudo systemctl disable mtproxy 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE" 2>/dev/null || true
    sudo systemctl daemon-reload || true

    print_status "Удаление бинарника..."
    sudo rm -f "$MTPROXY_BINARY" 2>/dev/null || true
    print_status "Очистка привилегий бинарника..."
    sudo setcap -r "$MTPROXY_BINARY" 2>/dev/null || true

    print_status "Удаление конфигов и каталогов..."
    sudo rm -rf "$CONFIG_DIR" 2>/dev/null || true
    sudo rm -rf "$STATE_DIR" 2>/dev/null || true
    sudo rm -rf "$LOG_DIR" 2>/dev/null || true
    print_status "Удаление конфига logrotate..."
    sudo rm -f "$LOGROTATE_FILE" 2>/dev/null || true
    print_status "Удаление скрипта обновления..."
    sudo rm -f "$UPDATE_SCRIPT" 2>/dev/null || true
    print_status "Удаление задачи cron..."
    sudo rm -f "$CRON_FILE" 2>/dev/null || true

    print_status "Удаление пользователя '$MTPROXY_USER'..."
    if id "$MTPROXY_USER" &>/dev/null; then
        sudo userdel "$MTPROXY_USER" 2>/dev/null || print_warning "Не удалось удалить пользователя '$MTPROXY_USER'. Возможно, он все еще владеет файлами."
    fi

    print_status "Очистка sysctl..."
    if grep -q "^net.core.somaxconn[[:space:]]*=.*1024" "$SYSCTL_FILE"; then
        sudo sed -i '/^net.core.somaxconn[[:space:]]*=.*1024/d' "$SYSCTL_FILE"
        sudo sysctl -p || print_warning "Не удалось применить изменения sysctl."
    fi

    print_warning "Настройки файрвола (UFW/iptables/облачные) НЕ удалены."
    if [ "$silent_prompt" = false ]; then
        print_header "Удаление MTProxy завершено."
    fi
}

reinstall_mtproxy() {
    print_header "Переустановка MTProxy"
    if ! confirm_action "Это полностью удалит текущую установку MTProxy и начнет новую установку."; then
        print_status "Переустановка отменена."
        exit 0
    fi

    uninstall_mtproxy --silent-prompt
    print_header "Запуск новой установки MTProxy..."
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            delete)
                COMMAND="delete"
                ;;
            reinstall)
                COMMAND="reinstall"
                ;;
            update-secret)
                COMMAND="update-secret"
                ;;
            update-adtag|set-adtag|change-adtag)
                COMMAND="update-adtag"
                ;;
            --adtag)
                if [ "$COMMAND" != "update-adtag" ]; then
                    print_error "Параметр --adtag поддерживается только вместе с командой update-adtag."
                    exit 1
                fi
                shift
                if [ $# -eq 0 ]; then
                    print_error "После --adtag нужно указать значение."
                    exit 1
                fi
                CLI_ADTAG_VALUE="$1"
                CLI_ADTAG_PROVIDED=true
                ;;
            --adtag=*)
                if [ "$COMMAND" != "update-adtag" ]; then
                    print_error "Параметр --adtag поддерживается только вместе с командой update-adtag."
                    exit 1
                fi
                CLI_ADTAG_VALUE="${1#*=}"
                CLI_ADTAG_PROVIDED=true
                ;;
            --clear-adtag)
                if [ "$COMMAND" != "update-adtag" ]; then
                    print_error "Параметр --clear-adtag поддерживается только вместе с командой update-adtag."
                    exit 1
                fi
                CLI_ADTAG_VALUE=""
                CLI_ADTAG_PROVIDED=true
                ;;
            *)
                if [ "$COMMAND" = "update-adtag" ] && [ "$CLI_ADTAG_PROVIDED" = false ]; then
                    CLI_ADTAG_VALUE="$1"
                    CLI_ADTAG_PROVIDED=true
                else
                    print_error "Неизвестный аргумент: $1"
                    print_warning "Доступные команды: delete, reinstall, update-secret, update-adtag"
                    exit 1
                fi
                ;;
        esac
        shift
    done
}

validate_supported_os() {
    if ! grep -q -E "Debian|Ubuntu" /etc/os-release; then
        print_error "Скрипт предназначен только для Debian или Ubuntu."
        exit 1
    fi
}

fix_ubuntu_23_repositories() {
    local distro_version=""

    distro_version="$(grep "VERSION_ID" /etc/os-release | cut -d '"' -f 2)"
    if [[ "$distro_version" =~ ^23 ]]; then
        print_header "Обнаружена Ubuntu $distro_version, вносим исправления"
        sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
        print_status "Резервная копия sources.list создана."

        sudo sed -i 's|http://.*archive.ubuntu.com|http://old-releases.ubuntu.com|g' /etc/apt/sources.list
        sudo sed -i 's|http://security.ubuntu.com|http://old-releases.ubuntu.com|g' /etc/apt/sources.list
        sudo sed -i 's|http://archive.ubuntu.com|http://old-releases.ubuntu.com|g' /etc/apt/sources.list
        print_status "Файл sources.list обновлён для поддержки устаревших репозиториев."

        print_status "Обновляем список пакетов..."
        sudo apt update
    fi
}

install_dependencies() {
    print_status "Обновление пакетов..."
    sudo apt update
    sudo apt upgrade -y

    print_status "Установка зависимостей..."
    sudo apt install -y git build-essential libssl-dev zlib1g-dev curl wget \
        libc6-dev gcc-multilib make cmake pkg-config netcat-openbsd xxd iproute2 dos2unix
}

ensure_mtproxy_user() {
    print_status "Пользователь mtproxy (для безопасности)..."
    if ! id "$MTPROXY_USER" &>/dev/null; then
        sudo useradd -r -s /bin/false -d "$STATE_DIR" -M "$MTPROXY_USER"
        sudo mkdir -p "$STATE_DIR"
        sudo chown "$MTPROXY_USER:$MTPROXY_GROUP" "$STATE_DIR"
        print_status "'$MTPROXY_USER' создан."
    else
        print_status "'$MTPROXY_USER' уже существует."
    fi
}

relax_makefile_flags() {
    if [ -f "Makefile" ]; then
        sed -i 's/-Werror//g' Makefile 2>/dev/null || true
    fi
}

prepare_telegram_source_tree() {
    relax_makefile_flags
    if [ -f "Makefile" ]; then
        grep -q -- "-fcommon" Makefile || sed -i 's/CFLAGS =/CFLAGS = -fcommon/g' Makefile 2>/dev/null || true
        sed -i 's/-march=native/-march=native -fcommon/g' Makefile 2>/dev/null || true
    fi

    find . -name "*.c" -exec sed -i '1i#include <string.h>' {} \; 2>/dev/null || true
    find . -name "*.c" -exec sed -i '1i#include <unistd.h>' {} \; 2>/dev/null || true
}

find_built_binary() {
    local candidate=""

    for candidate in objs/bin/mtproto-proxy mtproto-proxy bin/mtproto-proxy; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

build_mtproxy() {
    local build_success=false
    local build_dir=""

    print_header "Сборка MTProxy"
    cd /tmp
    rm -rf MTProxy MTProxy-community 2>/dev/null || true

    print_status "Сборка из GetPageSpeed/MTProxy..."
    if git clone https://github.com/GetPageSpeed/MTProxy.git MTProxy-community; then
        cd MTProxy-community
        relax_makefile_flags
        if make -j"$(nproc)" 2>/dev/null; then
            build_success=true
            build_dir="$(pwd)"
            print_status "Успех (GetPageSpeed)."
        else
            print_warning "Не удалось (GetPageSpeed). Вывод make:"
            make -j"$(nproc)"
            cd /tmp
        fi
    fi

    if [ "$build_success" = false ]; then
        print_status "Сборка из TelegramMessenger/MTProxy..."
        if git clone https://github.com/TelegramMessenger/MTProxy.git; then
            cd MTProxy
            prepare_telegram_source_tree
            if make -j"$(nproc)" CFLAGS="-fcommon -Wno-error" 2>/dev/null; then
                build_success=true
                build_dir="$(pwd)"
                print_status "Успех (TelegramMessenger)."
            else
                print_warning "Не удалось (TelegramMessenger). Вывод make:"
                make -j"$(nproc)" CFLAGS="-fcommon -Wno-error"
                print_warning "Попытка с минимальными флагами..."
                if make CC=gcc CFLAGS="-O2 -fcommon -w"; then
                    build_success=true
                    build_dir="$(pwd)"
                    print_status "Успех (минимальные флаги)."
                fi
            fi
        fi
    fi

    if [ "$build_success" = false ] || [ -z "$build_dir" ]; then
        print_error "Не удалось собрать MTProxy."
        print_error "Проверьте вывод make выше."
        exit 1
    fi

    cd "$build_dir"
}

install_built_binary() {
    local binary_path=""

    print_header "Установка и настройка"
    sudo mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true

    print_status "Копирование бинарника..."
    if ! binary_path="$(find_built_binary)"; then
        print_error "Бинарник mtproto-proxy не найден после сборки."
        exit 1
    fi

    sudo cp "$binary_path" "$MTPROXY_BINARY"
    sudo chmod +x "$MTPROXY_BINARY"
    print_status "Бинарник установлен."
}

download_telegram_configs() {
    print_status "Загрузка конфигов Telegram..."
    sudo curl -fsSL https://core.telegram.org/getProxySecret -o "$PROXY_SECRET_FILE" || print_warning "Не удалось скачать proxy-secret."
    sudo curl -fsSL https://core.telegram.org/getProxyConfig -o "$PROXY_MULTI_CONF_FILE" || print_warning "Не удалось скачать proxy-multi.conf."
}

apply_mtproxy_permissions() {
    print_status "Установка прав доступа..."
    sudo chown -R "$MTPROXY_USER:$MTPROXY_GROUP" "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
    sudo chmod 600 "$CONFIG_DIR"/* 2>/dev/null || true
}

create_update_script() {
    print_status "Создание скрипта обновления..."
    sudo tee "$UPDATE_SCRIPT" >/dev/null <<'UPDATE_SCRIPT_EOF'
#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_DIR="/etc/mtproxy"
PROXY_SECRET_FILE="$CONFIG_DIR/proxy-secret"
PROXY_MULTI_CONF_FILE="$CONFIG_DIR/proxy-multi.conf"
UPDATED_ANYTHING=false

print_status() {
    echo -e "${GREEN}* ${NC}$1"
}

print_warning() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
}

print_error() {
    echo -e "${RED}[ОШИБКА]${NC} $1"
}

download_file() {
    local url="$1"
    local target="$2"
    local temp_file=""

    temp_file="$(mktemp)"
    if curl -fsSL "$url" -o "$temp_file"; then
        install -o mtproxy -g mtproxy -m 600 "$temp_file" "$target"
        rm -f "$temp_file"
        UPDATED_ANYTHING=true
        print_status "$(basename "$target") обновлен."
    else
        rm -f "$temp_file"
        print_warning "Не удалось скачать $(basename "$target")."
    fi
}

print_status "Обновление конфигурации MTProxy..."
if ! command -v curl >/dev/null 2>&1; then
    print_error "Ошибка: curl не найден."
    exit 1
fi

if [ ! -d "$CONFIG_DIR" ]; then
    print_error "Ошибка: Каталог $CONFIG_DIR не существует."
    exit 1
fi

download_file https://core.telegram.org/getProxySecret "$PROXY_SECRET_FILE"
download_file https://core.telegram.org/getProxyConfig "$PROXY_MULTI_CONF_FILE"

if [ "$UPDATED_ANYTHING" = true ]; then
    print_status "Перезапуск сервиса..."
    if systemctl restart mtproxy; then
        print_status "Сервис перезапущен."
    else
        print_error "Не удалось перезапустить сервис. Проверьте логи."
        exit 1
    fi
else
    print_warning "Новые конфиги не получены. Перезапуск не требуется."
fi

print_status "Обновление конфигурации завершено."
UPDATE_SCRIPT_EOF

    sudo chmod +x "$UPDATE_SCRIPT"
    print_status "Скрипт обновления создан."
}

configure_daily_updates() {
    print_status "Настройка ежедневного обновления конфигурации (cron)..."
    if [ ! -f "$CRON_FILE" ] || ! grep -q "$UPDATE_SCRIPT" "$CRON_FILE"; then
        sudo tee "$CRON_FILE" >/dev/null <<CRON_FILE_EOF
0 3 * * * root $UPDATE_SCRIPT > /dev/null 2>&1
CRON_FILE_EOF
        print_status "Ежедневное обновление настроено на 03:00 UTC."
    else
        print_status "Задача cron для ежедневного обновления уже существует."
    fi
}

configure_logrotate() {
    print_status "Настройка ротации логов..."
    sudo tee "$LOGROTATE_FILE" >/dev/null <<LOGROTATE_EOF
/var/log/mtproxy/*.log {
    daily
    missingok
    rotate 52
    compress
    delaycompress
    notifempty
    create 640 mtproxy mtproxy
    postrotate
        systemctl try-reload-or-restart mtproxy > /dev/null 2>&1 || true
    endscript
}
LOGROTATE_EOF
    print_status "Настройка logrotate добавлена."
}

configure_firewall() {
    local external_port="$1"

    if command_exists ufw; then
        print_status "Настройка файрвола UFW..."
        sudo ufw allow "${external_port}/tcp" comment "MTProxy External Port" || print_warning "Не удалось добавить правило UFW для порта $external_port."
        print_status "Правило UFW добавлено для внешнего порта ${external_port}/tcp."
        print_warning "Если UFW выключен, включите его: sudo ufw enable"
    elif command_exists iptables; then
        print_status "Обнаружен iptables. Добавьте правила для ${external_port}/tcp вручную."
    else
        print_warning "Файрвол не обнаружен. Откройте внешний порт ${external_port}/tcp вручную в вашей системе и у провайдера."
    fi
}

apply_sysctl_optimization() {
    print_header "Оптимизации"
    print_status "Лимиты дескрипторов установлены в systemd юните."
    print_status "Настройка сетевых параметров (net.core.somaxconn)..."

    if grep -q "^net.core.somaxconn[[:space:]]*=" "$SYSCTL_FILE"; then
        sudo sed -i 's/^net.core.somaxconn[[:space:]]*=.*$/net.core.somaxconn = 1024/' "$SYSCTL_FILE"
        print_status "Обновлено net.core.somaxconn."
    else
        echo "$SYSCTL_SETTING" | sudo tee -a "$SYSCTL_FILE" >/dev/null
        print_status "Добавлено net.core.somaxconn = 1024."
    fi

    print_status "Применение сетевых параметров..."
    sudo sysctl -p || print_warning "Не удалось применить sysctl -p."
}

install_mtproxy() {
    local secret=""
    local external_port=""
    local internal_port=""

    print_header "Запуск установки MTProxy"
    validate_supported_os
    fix_ubuntu_23_repositories
    install_dependencies
    ensure_mtproxy_user

    prompt_for_port external_port "внешнего" "$DEFAULT_EXTERNAL_PORT"
    prompt_for_port internal_port "внутреннего" "$DEFAULT_INTERNAL_PORT" "$external_port" "внешним"

    build_mtproxy
    install_built_binary

    print_status "Генерация секрета..."
    secret="$(generate_secret)"
    write_mtproxy_config "$secret" "$external_port" "$internal_port" ""
    print_status "Секрет сгенерирован."

    download_telegram_configs
    apply_mtproxy_permissions
    configure_binary_capability "$external_port"

    print_status "Создание systemd сервиса..."
    write_systemd_service "$internal_port" "$external_port" "$secret" ""
    print_status "systemd сервис создан."

    create_update_script
    configure_daily_updates
    configure_logrotate
    configure_firewall "$external_port"
    start_mtproxy_service
    apply_sysctl_optimization

    load_current_settings
    print_header "Установка MTProxy завершена!"
    echo -e "${GREEN}* ${NC}MTProxy успешно установлен и запущен в фоновом режиме."
    print_adtag_help
    print_management_commands
    print_mtproxy_details
    print_header "Приятного использования!"
}

ensure_script_available "$@"
parse_arguments "$@"

case "$COMMAND" in
    delete)
        uninstall_mtproxy
        exit 0
        ;;
    reinstall)
        reinstall_mtproxy
        install_mtproxy
        ;;
    update-secret)
        update_mtproxy_secret
        exit 0
        ;;
    update-adtag)
        update_mtproxy_adtag
        exit 0
        ;;
    install)
        install_mtproxy
        ;;
esac
