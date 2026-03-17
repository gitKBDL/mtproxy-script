# MTProxy для Debian/Ubuntu

Этот репозиторий содержит один сценарий — `install_mtproxy.sh` — для установки, обслуживания и переустановки Telegram MTProxy как systemd-сервиса.

## Что делает скрипт

Сценарий:

- проверяет, что система относится к Debian или Ubuntu;
- обновляет пакеты (`apt update` и `apt upgrade -y`) и ставит зависимости для сборки;
- собирает MTProxy из `GetPageSpeed/MTProxy`, а при неудаче пытается собрать из `TelegramMessenger/MTProxy` с правками совместимости;
- создаёт системного пользователя `mtproxy`;
- спрашивает внешний порт (по умолчанию `443`) и внутренний порт (по умолчанию `8008`);
- генерирует секрет MTProxy;
- сохраняет текущие параметры в `/etc/mtproxy/config`;
- скачивает `proxy-secret` и `proxy-multi.conf` с `core.telegram.org`;
- создаёт и запускает сервис `mtproxy` через systemd;
- применяет сетевую оптимизацию `net.core.somaxconn = 1024` и лимит файловых дескрипторов для сервиса;
- устанавливает команду `mtproxy-update` для обновления конфигов Telegram и добавляет ежедневный запуск через cron в `03:00 UTC`;
- настраивает logrotate и пытается открыть внешний TCP-порт в UFW, если UFW установлен.

## Поддерживаемая среда

Скрипт ориентирован на:

- Debian `10`, `11`, `12`;
- Ubuntu `20.04`–`24.04`;
- сервер с systemd, публичным IP и доступом в интернет.

Практические требования:

- права `root` или `sudo`;
- возможность открыть внешний TCP-порт на сервере и у провайдера или в облачном firewall;
- доступ к GitHub и `https://core.telegram.org`.

## Быстрый запуск одной командой

Если не хотите клонировать репозиторий, можно сразу скачать и запустить установочный скрипт одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/gitKBDL/mtproxy-script/main/install_mtproxy.sh -o /tmp/install_mtproxy.sh && chmod +x /tmp/install_mtproxy.sh && sudo /tmp/install_mtproxy.sh
```

Эта команда скачивает актуальный `install_mtproxy.sh` напрямую из GitHub, делает его исполняемым и сразу запускает установку.

## Запуск из репозитория

Если репозиторий уже клонирован, запустите скрипт из каталога проекта:

```bash
chmod +x ./install_mtproxy.sh
sudo ./install_mtproxy.sh
```

Во время установки скрипт:

1. обновит систему и установит зависимости;
2. предложит выбрать внешний и внутренний порты;
3. соберёт и установит бинарник MTProxy;
4. сгенерирует секрет и запустит сервис `mtproxy`.

При первом запуске скрипт пытается скопировать себя в `/usr/local/bin/install_mtproxy.sh`. Если это удалось, дальнейшие команды управления можно выполнять как `sudo install_mtproxy.sh ...`.

## Что вы получите после установки

После успешного запуска скрипт выводит:

- внешний порт;
- внутренний порт;
- публичный IPv4 и, если доступен, IPv6-адрес сервера;
- секрет MTProxy;
- текущий adtag, если он уже задан;
- ссылки подключения для каждого найденного адреса:
  - `https://t.me/proxy?server=...&port=...&secret=...`
  - `tg://proxy?server=...&port=...&secret=...`

Скрипт старается отдельно определить публичные IPv4 и IPv6. Если найден только один адрес, будут показаны ссылки только для него. Если не удалось определить ни IPv4, ни IPv6, в выводе будет заглушка, и ссылку нужно собрать с вашим реальным публичным IP вручную.

## adtag: когда и как его задавать

adtag обычно задают **после** базовой установки. Причина в том, что adtag получают только после того, как:

1. MTProxy уже запущен;
2. у вас есть сгенерированный секрет;
3. прокси зарегистрирован через `@MTProxybot`.

Поэтому штатный workflow такой:

1. установить MTProxy без adtag;
2. взять секрет из финального вывода скрипта;
3. зарегистрировать прокси через `@MTProxybot`;
4. получить adtag;
5. применить его отдельной командой.

Во время обычной установки скрипт **не запрашивает adtag**. Сначала он поднимает прокси, показывает секрет и ссылки подключения, а adtag затем задаётся отдельно вручную, когда вы уже зарегистрировали прокси через `@MTProxybot` и получили нужное значение.

### Установка или смена adtag после установки

Интерактивный режим:

```bash
sudo install_mtproxy.sh update-adtag
```

Скрипт попросит ввести adtag. Допустимое значение — ровно `32` шестнадцатеричных символа.

Неинтерактивный режим:

```bash
sudo install_mtproxy.sh update-adtag ADTAG
```

После изменения adtag скрипт обновляет `/etc/mtproxy/config`, пересобирает `/etc/systemd/system/mtproxy.service` из актуальной конфигурации и перезапускает сервис.

### Очистка adtag

```bash
sudo install_mtproxy.sh update-adtag clear
```

Эта команда удаляет текущий adtag из конфигурации, пересобирает systemd unit и перезапускает сервис.

В интерактивном режиме команда `sudo install_mtproxy.sh update-adtag` тоже может очистить текущий adtag: для этого достаточно оставить ввод пустым.

## Команды управления

### Основные команды скрипта

```bash
sudo install_mtproxy.sh
```

Обычная установка.

```bash
sudo install_mtproxy.sh update-secret
```

Генерирует новый секрет, очищает текущий adtag, пересобирает сервис и перезапускает MTProxy. После этого старые ссылки перестают быть актуальными, а для рекламы через `@MTProxybot` нужен новый adtag.

```bash
sudo install_mtproxy.sh reinstall
```

Полностью удаляет текущую установку и запускает установку заново. Подходит для смены портов или чистой переустановки.

```bash
sudo install_mtproxy.sh delete
```

Полностью удаляет MTProxy, конфиги, systemd unit, cron-задачу и вспомогательные файлы. Настройки firewall скрипт не очищает.

```bash
sudo install_mtproxy.sh update-adtag
sudo install_mtproxy.sh update-adtag ADTAG
sudo install_mtproxy.sh update-adtag clear
```

Интерактивная установка или смена, неинтерактивная установка конкретного adtag и полное удаление adtag.

Дополнительно для этой команды поддерживаются алиасы `set-adtag` и `change-adtag`, а также формы `update-adtag --adtag ADTAG` и `update-adtag --clear-adtag`.

### Обслуживание сервиса

```bash
sudo systemctl start mtproxy
sudo systemctl stop mtproxy
sudo systemctl restart mtproxy
sudo systemctl status mtproxy
```

Логи:

```bash
sudo journalctl -u mtproxy -f
```

Проверка прослушиваемых портов:

```bash
sudo ss -tulnp | grep mtproto-proxy
```

### Обновление конфигов Telegram

```bash
sudo mtproxy-update
```

Команда заново скачивает `/etc/mtproxy/proxy-secret` и `/etc/mtproxy/proxy-multi.conf`. Если загрузка прошла успешно, сервис `mtproxy` будет автоматически перезапущен.

Дополнительно скрипт создаёт cron-задачу, которая выполняет это обновление ежедневно в `03:00 UTC`.

## Где хранится конфигурация

- `/etc/mtproxy/config` — текущие значения `SECRET`, `EXTERNAL_PORT`, `INTERNAL_PORT`, `ADTAG`;
- `/etc/mtproxy/proxy-secret` — секрет Telegram для MTProxy;
- `/etc/mtproxy/proxy-multi.conf` — конфиг Telegram;
- `/etc/systemd/system/mtproxy.service` — сгенерированный systemd unit;
- `/usr/local/bin/mtproxy-update` — вспомогательная команда для обновления конфигов Telegram;
- `/usr/local/bin/install_mtproxy.sh` — установленная копия скрипта управления.

## Примечания и troubleshooting

- Открывать наружу нужно выбранный внешний TCP-порт. Если у вас есть облачный firewall, security group или правила у провайдера, их нужно настроить отдельно.
- Если в системе есть UFW, скрипт пытается автоматически добавить правило только для внешнего порта. Для других firewall могут понадобиться ручные действия.
- После `update-secret` удалите старый прокси из Telegram, используйте новый секрет и при необходимости получите новый adtag через `@MTProxybot`.
- Если собранный бинарник MTProxy не поддерживает `proxy-tag`, команда обновления adtag завершится ошибкой — это проверяется самим скриптом.
- Команда `delete` не удаляет правила UFW, iptables и внешние firewall-настройки.
