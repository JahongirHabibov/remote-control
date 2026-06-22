# POS Remote Control

Automated VPS setup for remote management of POS devices behind NAT/LAN.

**Stack:** WireGuard VPN · Apache Guacamole · nginx · fail2ban · Let's Encrypt

**Access from any browser:** VNC (GUI desktop) + SSH (terminal) for every POS device.

---

## Architecture

```
Admin Browser (HTTPS)
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
(Ubuntu, behind NAT)
```

---

## Requirements

| Requirement | Details |
|---|---|
| VPS OS | Ubuntu 24.04 |
| Domain | A-record pointing to VPS (e.g. `remote.legisell.de`) |
| Docker | Installed with Compose plugin |
| Ports open | 22/tcp · 80/tcp · 443/tcp · 51820/udp |

Check all dependencies before setup:
```bash
make check
```

Missing packages to install:
```bash
sudo apt-get install wireguard-tools nginx certbot python3-certbot-nginx \
                     fail2ban ufw jq postgresql-client
```

---

## Quick Start

```bash
# 1. Clone and configure
git clone <repo-url>
cd remote-control
cp .env.example .env
nano .env            # fill in DOMAIN, passwords, WG_INET_IFACE

# 2. Check dependencies
make check

# 3. Initial VPS setup (run once)
make setup

# 4. Add your first POS device
make add-device

# 5. Copy generated config to POS device
scp devices/pos-berlin-01/remote-access.conf user@<pos-ip>:~/
```

---

## Commands

| Command | Description |
|---|---|
| `make check` | Verify all dependencies — no changes made |
| `make setup` | Initial VPS setup (WG + Guacamole + nginx + fail2ban) |
| `make status` | Show status of all services + connected devices |
| `make add-device` | Register new POS device (interactive) |
| `make remove-device` | Remove a device |
| `make list-devices` | List all devices with online/offline status |
| `make restart` | Restart all services |
| `make logs` | Stream Docker logs |
| `make backup` | Backup Guacamole DB + WireGuard configs |
| `make update` | Pull latest Docker images |
| `make open-firewall` | (Re)configure UFW rules |

---

## Adding a POS Device

```bash
make add-device
```

You will be prompted for:
- **Device name** (e.g. `pos-berlin-01`)
- **Location** (optional description)
- **VNC password** (for GUI access)
- **SSH username + password** (for terminal access)

Output:
- WireGuard peer added to server
- Guacamole connections created (VNC + SSH)
- `devices/<name>/remote-access.conf` generated

Then on the **POS device** (using [pos-deployment](../pos-deployment)):
```bash
scp devices/pos-berlin-01/remote-access.conf user@<pos-ip>:~/
ssh user@<pos-ip>
sudo ./setup-remote-access.sh --config ~/remote-access.conf
```

---

## Security

| Layer | Protection |
|---|---|
| TLS | 1.2/1.3 only, strong cipher suites, HSTS |
| Authentication | Guacamole TOTP (2FA) |
| Brute force | fail2ban — SSH + Guacamole login |
| Rate limiting | nginx — 20 req/s general, 5 req/min login |
| Connection limit | max 30 concurrent connections per IP |
| Attack surface | Guacamole not exposed directly — nginx proxy only |
| VNC/SSH | Only reachable inside WireGuard tunnel (10.8.0.0/24) |
| Firewall | UFW — only 22, 80, 443, 51820 open |

---

## File Structure

```
remote-control/
├── Makefile                         # all commands here
├── .env.example                     # configuration template
├── docker-compose.yml               # Guacamole + guacd + postgres
├── nginx/
│   ├── conf.d/guacamole.conf        # reverse proxy + security headers
│   ├── conf.d/security.conf         # rate limiting zones
│   └── snippets/ssl-params.conf     # TLS hardening
├── wireguard/
│   └── wg0.conf.template            # WG server config template
├── guacamole/
│   ├── guacamole.properties.template
│   └── extensions/                  # TOTP JAR (downloaded by setup)
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
└── devices/                         # gitignored — per-device configs
    └── pos-berlin-01/
        ├── meta.conf
        ├── wg-pubkey.txt
        └── remote-access.conf       # copy to POS device
```

---

## Backup & Restore

```bash
make backup            # creates backups/YYYYMMDD-HHMMSS.tar.gz
```

Restore:
```bash
tar -xzf backups/20240115-143022.tar.gz
docker exec -i pos-postgres psql -U guacamole guacamole_db < 20240115-143022/guacamole-db.sql
```

---

## License

MIT — free to use, modify, and distribute.
