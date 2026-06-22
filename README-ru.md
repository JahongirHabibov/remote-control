# POS Remote Control

Автоматизированная настройка VPS для удалённого управления POS-терминалами за NAT/LAN.

**Стек:** WireGuard VPN · Apache Guacamole · nginx · fail2ban · Let's Encrypt

**Доступ из любого браузера:** VNC (графический рабочий стол) + SSH (терминал) для каждого POS-устройства.

---

## Архитектура

```
Браузер администратора (HTTPS)
        │
        ▼
  nginx  ──  fail2ban, rate limiting, TLS 1.2/1.3
        │
        ▼
  Apache Guacamole  (Docker)  ──  TOTP 2FA
        │
  WireGuard VPN  (wg0)
        │  10.8.0.0/24
   ┌────┴────┬────────┐
POS-001   POS-002   POS-N ...
(Ubuntu, за NAT)
```

---

## Требования

| Требование | Детали |
|---|---|
| ОС сервера | Ubuntu 24.04 |
| Домен | A-запись, указывающая на VPS (например, `remote.legisell.de`) |
| Docker | Установлен с плагином Compose |
| Открытые порты | 22/tcp · 80/tcp · 443/tcp · 51820/udp |

Проверить все зависимости:
```bash
make check
```

Установить недостающие пакеты:
```bash
sudo apt-get install wireguard-tools nginx certbot python3-certbot-nginx \
                     fail2ban ufw jq postgresql-client
```

---

## Быстрый старт

```bash
# 1. Клонировать и настроить
git clone <repo-url>
cd remote-control
cp .env.example .env
nano .env            # заполнить DOMAIN, пароли, WG_INET_IFACE

# 2. Проверить зависимости
make check

# 3. Начальная настройка VPS (один раз)
make setup

# 4. Добавить первое POS-устройство
make add-device

# 5. Скопировать сгенерированный конфиг на POS-устройство
scp devices/pos-berlin-01/remote-access.conf user@<pos-ip>:~/
```

---

## Команды

| Команда | Описание |
|---|---|
| `make check` | Проверить все зависимости — без изменений |
| `make setup` | Первоначальная настройка VPS |
| `make status` | Статус всех сервисов + подключённых устройств |
| `make add-device` | Добавить новое POS-устройство (интерактивно) |
| `make remove-device` | Удалить устройство |
| `make list-devices` | Список всех устройств со статусом online/offline |
| `make restart` | Перезапустить все сервисы |
| `make logs` | Просматривать логи Docker |
| `make backup` | Резервная копия БД Guacamole + конфигов WireGuard |
| `make update` | Обновить Docker-образы |
| `make open-firewall` | Настроить правила UFW |

---

## Добавление POS-устройства

```bash
make add-device
```

Будет запрошено:
- **Имя устройства** (например, `pos-berlin-01`)
- **Расположение** (опционально)
- **VNC-пароль** (для GUI-доступа)
- **SSH логин + пароль** (для терминального доступа)

Результат:
- WireGuard peer добавлен на сервер
- Подключения в Guacamole созданы (VNC + SSH)
- Сгенерирован `devices/<name>/remote-access.conf`

Затем на **POS-устройстве** (используя [pos-deployment](../pos-deployment)):
```bash
scp devices/pos-berlin-01/remote-access.conf user@<pos-ip>:~/
ssh user@<pos-ip>
sudo ./setup-remote-access.sh --config ~/remote-access.conf
```

---

## Безопасность

| Уровень | Защита |
|---|---|
| TLS | Только 1.2/1.3, строгие наборы шифров, HSTS |
| Аутентификация | Guacamole TOTP (двухфакторная) |
| Брутфорс | fail2ban — SSH + вход в Guacamole |
| Rate limiting | nginx — 20 req/s общий, 5 req/min для входа |
| Лимит соединений | макс. 30 одновременных с одного IP |
| Поверхность атаки | Guacamole не доступен напрямую — только через nginx |
| VNC/SSH | Доступны только внутри туннеля WireGuard (10.8.0.0/24) |
| Брандмауэр | UFW — открыты только 22, 80, 443, 51820 |

---

## Структура файлов

```
remote-control/
├── Makefile                         # все команды здесь
├── .env.example                     # шаблон конфигурации
├── docker-compose.yml               # Guacamole + guacd + postgres
├── nginx/
│   ├── conf.d/guacamole.conf        # reverse proxy + заголовки безопасности
│   ├── conf.d/security.conf         # зоны rate limiting
│   └── snippets/ssl-params.conf     # усиление TLS
├── wireguard/
│   └── wg0.conf.template            # шаблон конфигурации WG-сервера
├── guacamole/
│   ├── guacamole.properties.template
│   └── extensions/                  # TOTP JAR (скачивается при setup)
├── fail2ban/
│   ├── jail.local
│   └── filter.d/guacamole.conf
├── scripts/
│   ├── check-deps.sh
│   ├── setup.sh
│   ├── add-device.sh
│   ├── remove-device.sh
│   ├── list-devices.sh
│   ├── status.sh
│   └── backup.sh
└── devices/                         # в .gitignore — конфиги устройств
    └── pos-berlin-01/
        ├── meta.conf
        ├── wg-pubkey.txt
        └── remote-access.conf       # копируется на POS-устройство
```

---

## Резервное копирование и восстановление

```bash
make backup            # создаёт backups/YYYYMMDD-HHMMSS.tar.gz
```

Восстановление:
```bash
tar -xzf backups/20240115-143022.tar.gz
docker exec -i pos-postgres psql -U guacamole guacamole_db < 20240115-143022/guacamole-db.sql
```

---

## Лицензия

MIT — свободно использовать, изменять и распространять.
