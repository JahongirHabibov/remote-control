#!/usr/bin/env bash
# check-deps.sh — Verify all required dependencies are present
# Does NOT install anything. Shows ✓/✗ status for each dependency.
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; MISSING=$((MISSING+1)); }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }
info() { echo -e "  ${CYAN}→${NC}  $*"; }

MISSING=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env if present
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

echo ""
echo -e "${BOLD}  POS Remote Control — Dependency Check${NC}"
echo -e "  ──────────────────────────────────────"
echo ""

# ── System ────────────────────────────────────────────────────────────────────
echo -e "  ${BOLD}System:${NC}"

OS_ID=$(. /etc/os-release && echo "$ID")
OS_VER=$(. /etc/os-release && echo "$VERSION_ID")
if [[ "$OS_ID" == "ubuntu" && "$OS_VER" == "24.04" ]]; then
    ok "Ubuntu 24.04"
else
    warn "Ubuntu 24.04 expected — found ${OS_ID} ${OS_VER} (may still work)"
fi

if [[ $EUID -eq 0 ]]; then
    ok "Running as root"
elif sudo -n true 2>/dev/null; then
    ok "sudo available (passwordless)"
else
    warn "sudo available (password required for setup)"
fi

echo ""
echo -e "  ${BOLD}Required packages:${NC}"

check_cmd() {
    local cmd="$1" pkg="$2" hint="${3:-}"
    if command -v "$cmd" &>/dev/null; then
        local ver
        ver=$("$cmd" --version 2>/dev/null | head -1 || echo "")
        ok "${cmd}  ${ver:+(${ver})}"
    else
        fail "${cmd}  — install: sudo apt-get install ${pkg}${hint:+  ($hint)}"
    fi
}

# wireguard-tools: only host-native dep (manages /etc/wireguard/ and wg-quick)
check_cmd "wg"     "wireguard-tools" ""
check_cmd "ufw"    "ufw"             ""
check_cmd "openssl" "openssl"        "used to generate passwords"
check_cmd "jq"     "jq"              "used by device scripts"

# docker: all other services run in containers
check_cmd "docker" "docker.io"       "or install Docker CE"

echo ""
echo -e "  ${BOLD}Docker Compose plugin:${NC}"
if docker compose version &>/dev/null 2>&1; then
    ver=$(docker compose version --short 2>/dev/null || echo "")
    ok "docker compose plugin  ${ver:+(v${ver})}"
else
    fail "docker compose plugin — install Docker CE (includes compose plugin)"
fi

echo ""
echo -e "  ${BOLD}Configuration:${NC}"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    ok ".env file found"
    for var in DOMAIN CERTBOT_EMAIL POSTGRES_PASSWORD GUAC_ADMIN_PASSWORD WG_PORT WG_INET_IFACE; do
        val="${!var:-}"
        if [[ -z "$val" ]]; then
            fail "${var} not set in .env"
        elif [[ "$val" == *"CHANGE_ME"* ]]; then
            fail "${var} still has placeholder value — update .env"
        else
            ok "${var} is set"
        fi
    done
else
    fail ".env not found — run: cp .env.example .env"
fi

echo ""
echo -e "  ${BOLD}DNS:${NC}"
DOMAIN="${DOMAIN:-}"
if [[ -n "$DOMAIN" ]]; then
    if command -v dig &>/dev/null; then
        RESOLVED=$(dig +short "$DOMAIN" 2>/dev/null | head -1 || echo "")
    elif command -v host &>/dev/null; then
        RESOLVED=$(host "$DOMAIN" 2>/dev/null | grep 'has address' | awk '{print $4}' | head -1 || echo "")
    else
        RESOLVED=$(nslookup "$DOMAIN" 2>/dev/null | grep -A1 'Name:' | grep 'Address:' | awk '{print $2}' | head -1 || echo "")
    fi
    VPS_IP=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    if [[ -n "$RESOLVED" && -n "$VPS_IP" && "$RESOLVED" == "$VPS_IP" ]]; then
        ok "${DOMAIN} → ${RESOLVED}  (matches VPS IP)"
    elif [[ -n "$RESOLVED" ]]; then
        warn "${DOMAIN} → ${RESOLVED}  (VPS IP: ${VPS_IP:-unknown} — verify DNS)"
    else
        fail "${DOMAIN} — DNS not resolving  (add A record pointing to this VPS)"
    fi
else
    warn "DOMAIN not set — skip DNS check"
fi

echo ""
echo -e "  ${BOLD}Guacamole TOTP extension:${NC}"
if ls "$SCRIPT_DIR/guacamole/extensions"/guacamole-auth-totp-*.jar &>/dev/null 2>&1; then
    ok "TOTP extension JAR found"
else
    warn "TOTP extension JAR missing — will be downloaded automatically by: make setup"
    info "Or manually: https://guacamole.apache.org/releases/"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ $MISSING -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All checks passed.${NC}  Run: ${CYAN}make setup${NC}"
else
    echo -e "  ${RED}${BOLD}${MISSING} issue(s) found.${NC}  Fix above, then run: ${CYAN}make check${NC}"
fi
echo ""
exit $MISSING
