#!/usr/bin/env bash
# setup.sh — Initial VPS setup: WireGuard + Guacamole (fully Dockerized)
# Run once after: make check passes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/.env"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; }
info() { echo -e "  ${CYAN}→${NC}  $*"; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }
step() { echo ""; echo -e "${BOLD}${CYAN}── $* ──${NC}"; }
die()  { echo -e "\n${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

echo ""
echo -e "${BOLD}  POS Remote Control — VPS Setup${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
step "1/6  UFW Firewall"
# ═══════════════════════════════════════════════════════════════
bash "$SCRIPT_DIR/scripts/open-firewall.sh"
ok "Firewall configured"

# ═══════════════════════════════════════════════════════════════
step "2/6  WireGuard Server"
# ═══════════════════════════════════════════════════════════════
WG_PRIVKEY_FILE="/etc/wireguard/server-private.key"
WG_PUBKEY_FILE="/etc/wireguard/server-public.key"
WG_CONF="/etc/wireguard/wg0.conf"

if [[ ! -f "$WG_PRIVKEY_FILE" ]]; then
    wg genkey | tee "$WG_PRIVKEY_FILE" | wg pubkey > "$WG_PUBKEY_FILE"
    chmod 600 "$WG_PRIVKEY_FILE" "$WG_PUBKEY_FILE"
    ok "WireGuard server keypair generated"
else
    ok "WireGuard server keypair already exists"
fi

WG_SERVER_PRIVKEY=$(cat "$WG_PRIVKEY_FILE")
WG_SERVER_PUBKEY=$(cat "$WG_PUBKEY_FILE")

if [[ ! -f "$WG_CONF" ]]; then
    sed \
        -e "s|SERVER_PRIVATE_KEY_PLACEHOLDER|${WG_SERVER_PRIVKEY}|g" \
        -e "s|WG_SERVER_IP_PLACEHOLDER|${WG_SERVER_IP}|g" \
        -e "s|WG_PORT_PLACEHOLDER|${WG_PORT}|g" \
        -e "s|WG_INET_IFACE_PLACEHOLDER|${WG_INET_IFACE}|g" \
        "$SCRIPT_DIR/wireguard/wg0.conf.template" > "$WG_CONF"
    chmod 600 "$WG_CONF"
    ok "WireGuard config written: /etc/wireguard/wg0.conf"
else
    ok "WireGuard config already exists (skipped)"
fi

if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p -q
fi
ok "IPv4 forwarding enabled"

systemctl enable --now wg-quick@wg0
ok "WireGuard service active"

# ═══════════════════════════════════════════════════════════════
step "3/6  Guacamole — TOTP Extension"
# ═══════════════════════════════════════════════════════════════
mkdir -p "$SCRIPT_DIR/guacamole/extensions"
TOTP_JAR=$(ls "$SCRIPT_DIR/guacamole/extensions"/guacamole-auth-totp-*.jar 2>/dev/null | head -1 || echo "")

if [[ -z "$TOTP_JAR" ]]; then
    info "Downloading Guacamole TOTP extension..."
    TOTP_URL="https://downloads.apache.org/guacamole/${GUACAMOLE_VERSION}/binary/guacamole-auth-totp-${GUACAMOLE_VERSION}.tar.gz"
    TMP=$(mktemp -d)
    if curl -fsSL "$TOTP_URL" | tar -xz -C "$TMP"; then
        cp "$TMP"/guacamole-auth-totp-*/guacamole-auth-totp-*.jar \
           "$SCRIPT_DIR/guacamole/extensions/"
        rm -rf "$TMP"
        ok "TOTP extension downloaded"
    else
        rm -rf "$TMP"
        die "Failed to download TOTP extension from:\n  ${TOTP_URL}\n  Download manually and place in guacamole/extensions/"
    fi
else
    ok "TOTP extension already present"
fi

# ═══════════════════════════════════════════════════════════════
step "4/6  Guacamole — Database Schema"
# ═══════════════════════════════════════════════════════════════
mkdir -p "$SCRIPT_DIR/guacamole/init"
INITDB_SQL="$SCRIPT_DIR/guacamole/init/001-initdb.sql"

if [[ ! -f "$INITDB_SQL" ]]; then
    info "Generating Guacamole database schema..."
    docker run --rm \
        "guacamole/guacamole:${GUACAMOLE_VERSION}" \
        /opt/guacamole/bin/initdb.sh --postgresql > "$INITDB_SQL"
    ok "Schema SQL generated: guacamole/init/001-initdb.sql"
else
    ok "Schema SQL already exists (skipped)"
fi

# ═══════════════════════════════════════════════════════════════
step "5/6  Guacamole — Properties"
# ═══════════════════════════════════════════════════════════════
GUAC_PROPS="$SCRIPT_DIR/guacamole/guacamole.properties"
if [[ ! -f "$GUAC_PROPS" ]]; then
    sed \
        -e "s|POSTGRES_DB_PLACEHOLDER|${POSTGRES_DB}|g" \
        -e "s|POSTGRES_USER_PLACEHOLDER|${POSTGRES_USER}|g" \
        -e "s|POSTGRES_PASSWORD_PLACEHOLDER|${POSTGRES_PASSWORD}|g" \
        "$SCRIPT_DIR/guacamole/guacamole.properties.template" > "$GUAC_PROPS"
    ok "guacamole.properties generated"
else
    ok "guacamole.properties already exists (skipped)"
fi

# ═══════════════════════════════════════════════════════════════
step "6/6  Docker Stack (Traefik-adapted)"
# ═══════════════════════════════════════════════════════════════

# Start full Docker stack using production overlay
info "Starting Docker stack with Traefik integration..."
cd "$SCRIPT_DIR"
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
ok "Docker stack started"

# Wait for PostgreSQL to be ready (up to 60 s)
info "Waiting for PostgreSQL..."
for i in $(seq 1 30); do
    docker exec pos-postgres pg_isready -U "${POSTGRES_USER}" -q 2>/dev/null && break
    sleep 2
done
docker exec pos-postgres pg_isready -U "${POSTGRES_USER}" -q 2>/dev/null \
    || die "PostgreSQL did not become ready in time"
ok "PostgreSQL ready"

# Compute Guacamole password hash: SHA-256(password_bytes + salt_bytes) stored as bytea
HASH_DATA=$(python3 - "${GUAC_ADMIN_PASSWORD}" << 'PYEOF'
import hashlib, os, binascii, sys
password = sys.argv[1].encode('utf-8')
salt = os.urandom(32)
hash_val = hashlib.sha256(password + salt).digest()
print(binascii.hexlify(hash_val).decode() + ':' + binascii.hexlify(salt).decode())
PYEOF
)
HASH_HEX="${HASH_DATA%%:*}"
SALT_HEX="${HASH_DATA##*:}"

# Rename guacadmin → GUAC_ADMIN_USER (if different)
if [[ "${GUAC_ADMIN_USER}" != "guacadmin" ]]; then
    docker exec pos-postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -q \
        -c "UPDATE guacamole_entity SET name = '${GUAC_ADMIN_USER}'
            WHERE name = 'guacadmin' AND type = 'USER';" \
        2>/dev/null || warn "Admin rename skipped"
fi

# Update password with correct hash
docker exec pos-postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -q \
    -c "UPDATE guacamole_user u
        SET password_hash = decode('${HASH_HEX}', 'hex'),
            password_salt = decode('${SALT_HEX}', 'hex'),
            password_date = NOW()
        FROM guacamole_entity e
        WHERE u.entity_id = e.entity_id
          AND e.name = '${GUAC_ADMIN_USER}'
          AND e.type = 'USER';" \
    2>/dev/null || warn "Admin password update skipped — change it manually on first login"

ok "Guacamole admin credentials set"

# Save server pubkey for add-device.sh
echo "$WG_SERVER_PUBKEY" > "$SCRIPT_DIR/wireguard/server-public.key"

# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}  ✓ Setup complete!${NC}"
echo ""
echo -e "  ${BOLD}Access:${NC}     https://${DOMAIN}/guacamole/"
echo -e "  ${BOLD}Login:${NC}      ${GUAC_ADMIN_USER}"
echo -e "  ${BOLD}Password:${NC}   <set in .env>"
echo ""
echo -e "  ${BOLD}WireGuard server public key:${NC}"
echo -e "  ${CYAN}${WG_SERVER_PUBKEY}${NC}"
echo ""
echo -e "  ${BOLD}Next:${NC}  make add-device  (to register a POS device)"
echo ""
