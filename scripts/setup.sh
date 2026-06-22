#!/usr/bin/env bash
# setup.sh — Initial VPS setup: WireGuard + Guacamole + nginx + fail2ban
# Run once after: make check passes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/.env"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()      { echo -e "  ${GREEN}✓${NC}  $*"; }
fail()    { echo -e "  ${RED}✗${NC}  $*"; }
info()    { echo -e "  ${CYAN}→${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}!${NC}  $*"; }
step()    { echo ""; echo -e "${BOLD}${CYAN}── $* ──${NC}"; }
die()     { echo -e "\n${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

echo ""
echo -e "${BOLD}  POS Remote Control — VPS Setup${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
step "1/7  UFW Firewall"
# ═══════════════════════════════════════════════════════════════
bash "$SCRIPT_DIR/scripts/open-firewall.sh"
ok "Firewall configured"

# ═══════════════════════════════════════════════════════════════
step "2/7  WireGuard Server"
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

# Enable IPv4 forwarding for NAT
if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p -q
fi
ok "IPv4 forwarding enabled"

systemctl enable --now wg-quick@wg0
ok "WireGuard service active"

# ═══════════════════════════════════════════════════════════════
step "3/7  Guacamole — TOTP Extension"
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
step "4/7  Guacamole — Database Init"
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
step "5/7  Guacamole — Properties"
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
step "6/7  nginx + Let's Encrypt SSL"
# ═══════════════════════════════════════════════════════════════
NGINX_SITE="/etc/nginx/conf.d/${DOMAIN}.conf"
NGINX_SNIPPET_DIR="/etc/nginx/snippets"
NGINX_SECURITY_CONF="/etc/nginx/conf.d/security.conf"

mkdir -p "$NGINX_SNIPPET_DIR"
mkdir -p /var/www/certbot

# Copy security config (idempotent)
cp "$SCRIPT_DIR/nginx/conf.d/security.conf" "$NGINX_SECURITY_CONF"
cp "$SCRIPT_DIR/nginx/snippets/ssl-params.conf" "$NGINX_SNIPPET_DIR/ssl-params.conf"
ok "nginx security + TLS config deployed"

# Deploy site config with domain substituted
sed "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g" \
    "$SCRIPT_DIR/nginx/conf.d/guacamole.conf" > "$NGINX_SITE"
ok "nginx site config deployed: ${NGINX_SITE}"

# Obtain Let's Encrypt certificate (skip if already exists)
if [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    info "Obtaining Let's Encrypt certificate for ${DOMAIN}..."
    # Temporarily serve only HTTP for ACME challenge
    nginx -t && systemctl reload nginx
    certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --email "$CERTBOT_EMAIL" \
        --agree-tos \
        --no-eff-email \
        -d "$DOMAIN"
    ok "SSL certificate obtained"
else
    ok "SSL certificate already exists (skipped)"
fi

nginx -t && systemctl enable --now nginx && systemctl reload nginx
ok "nginx running with HTTPS"

# Certbot auto-renewal (cron)
if ! crontab -l 2>/dev/null | grep -q certbot; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    ok "Certbot auto-renewal cron added"
else
    ok "Certbot auto-renewal already configured"
fi

# ═══════════════════════════════════════════════════════════════
step "7/7  fail2ban + Docker Stack"
# ═══════════════════════════════════════════════════════════════
# Deploy fail2ban configs
cp "$SCRIPT_DIR/fail2ban/jail.local"                    /etc/fail2ban/jail.local
cp "$SCRIPT_DIR/fail2ban/filter.d/guacamole.conf"       /etc/fail2ban/filter.d/guacamole.conf
systemctl enable --now fail2ban && systemctl restart fail2ban
ok "fail2ban configured and running"

# Start Docker stack
cd "$SCRIPT_DIR"
docker compose up -d
ok "Guacamole stack started"

# Wait for PostgreSQL and Guacamole to be fully ready
info "Waiting for services to be ready..."
for i in $(seq 1 30); do
    docker exec pos-postgres pg_isready -U "${POSTGRES_USER}" -q 2>/dev/null && break
    sleep 2
done

# Compute correct Guacamole password hash: SHA-256(password_bytes + salt_bytes)
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

# Save server pubkey to a safe location for add-device.sh
echo "$WG_SERVER_PUBKEY" > "$SCRIPT_DIR/wireguard/server-public.key"
