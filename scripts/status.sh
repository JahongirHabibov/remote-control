#!/usr/bin/env bash
# status.sh — Show status of all services and connected devices
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}●${NC}  $*"; }
fail() { echo -e "  ${RED}●${NC}  $*"; }
warn() { echo -e "  ${YELLOW}●${NC}  $*"; }

svc_status() {
    local name="$1" label="$2"
    if systemctl is-active --quiet "$name" 2>/dev/null; then
        ok "${label}"
    elif systemctl is-enabled --quiet "$name" 2>/dev/null; then
        warn "${label}  (enabled but not running)"
    else
        fail "${label}  (not configured)"
    fi
}

container_status() {
    local name="$1" label="$2"
    local state
    state=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
    if [[ "$state" == "running" ]]; then
        ok "${label}"
    elif [[ "$state" != "missing" ]]; then
        warn "${label}  (${state})"
    else
        fail "${label}  (container not found)"
    fi
}

echo ""
echo -e "${BOLD}  POS Remote Control — Status${NC}"
echo -e "  ${DIM}$(date)${NC}"
echo ""

echo -e "  ${BOLD}Services:${NC}"
svc_status "wg-quick@wg0"  "WireGuard (wg0)"
svc_status "nginx"          "nginx"
svc_status "fail2ban"       "fail2ban"
echo ""

echo -e "  ${BOLD}Docker containers:${NC}"
container_status "pos-guacamole"  "Guacamole (web)"
container_status "pos-guacd"      "guacd (protocol daemon)"
container_status "pos-postgres"   "PostgreSQL"
echo ""

echo -e "  ${BOLD}WireGuard peers:${NC}"
if ip link show wg0 &>/dev/null; then
    PEERS=$(sudo wg show wg0 peers 2>/dev/null | wc -l)
    echo -e "  ${CYAN}→${NC}  ${PEERS} peer(s) configured"
    sudo wg show wg0 2>/dev/null | awk '
        /^peer:/ { peer=$2; name=""; ip=""; hs="never" }
        /latest handshake:/ { hs=substr($0, index($0,$3)) }
        /allowed ips:/ { ip=$3 }
        /^$/ && peer != "" {
            printf "     %-20s  %-18s  last seen: %s\n", ip, peer, hs
            peer=""
        }
    ' || true
    # Match with device names
    for device_dir in "$SCRIPT_DIR/devices"/*/; do
        [[ -f "${device_dir}meta.conf" ]] || continue
        source "${device_dir}meta.conf"
        PEER_KEY_FILE="${device_dir}wg-pubkey.txt"
        [[ -f "$PEER_KEY_FILE" ]] || continue
        PUBKEY=$(cat "$PEER_KEY_FILE")
        HS=$(sudo wg show wg0 latest-handshakes 2>/dev/null | grep "$PUBKEY" | awk '{print $2}' || echo "0")
        if [[ "$HS" != "0" && -n "$HS" ]]; then
            AGO=$(( $(date +%s) - HS ))
            if [[ $AGO -lt 180 ]]; then
                STATUS="${GREEN}online${NC}"
            else
                STATUS="${YELLOW}last seen ${AGO}s ago${NC}"
            fi
        else
            STATUS="${RED}never connected${NC}"
        fi
        echo -e "     ${BOLD}${DEVICE_NAME}${NC}  ${WG_IP}  — $(echo -e "$STATUS")"
    done
else
    fail "WireGuard interface wg0 not available"
fi
echo ""

echo -e "  ${BOLD}SSL certificate:${NC}"
DOMAIN="${DOMAIN:-}"
if [[ -n "$DOMAIN" && -f "/etc/letsencrypt/live/${DOMAIN}/cert.pem" ]]; then
    EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${DOMAIN}/cert.pem" | cut -d= -f2)
    ok "${DOMAIN}  — expires: ${EXPIRY}"
else
    fail "No certificate found for ${DOMAIN:-<DOMAIN not set>}"
fi
echo ""

echo -e "  ${BOLD}fail2ban bans:${NC}"
sudo fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*: //' | tr ',' '\n' | while read -r jail; do
    jail=$(echo "$jail" | xargs)
    [[ -z "$jail" ]] && continue
    BANNED=$(sudo fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned:" | awk '{print $NF}')
    if [[ "$BANNED" -gt 0 ]]; then
        warn "${jail}: ${BANNED} IP(s) currently banned"
    else
        ok "${jail}: no active bans"
    fi
done || warn "fail2ban not running"
echo ""
