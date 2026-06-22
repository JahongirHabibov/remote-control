#!/usr/bin/env bash
# list-devices.sh — List all registered POS devices with WG + connection status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

echo ""
echo -e "${BOLD}  Registered POS Devices${NC}"
echo ""

COUNT=0
for meta in "$SCRIPT_DIR/devices"/*/meta.conf; do
    [[ -f "$meta" ]] || continue
    source "$meta"
    COUNT=$((COUNT + 1))

    # WireGuard handshake status
    HS=$(sudo wg show wg0 latest-handshakes 2>/dev/null | grep "$WG_PUBKEY" | awk '{print $2}' || echo "0")
    if [[ -n "$HS" && "$HS" != "0" ]]; then
        AGO=$(( $(date +%s) - HS ))
        if [[ $AGO -lt 180 ]]; then
            WG_STATUS="${GREEN}online${NC}"
        elif [[ $AGO -lt 3600 ]]; then
            WG_STATUS="${YELLOW}${AGO}s ago${NC}"
        else
            HOURS=$((AGO / 3600))
            WG_STATUS="${YELLOW}${HOURS}h ago${NC}"
        fi
    else
        WG_STATUS="${RED}never / offline${NC}"
    fi

    echo -e "  ${BOLD}${DEVICE_NAME}${NC}${DEVICE_LOCATION:+  ${DIM}(${DEVICE_LOCATION})${NC}}"
    echo -e "    IP:      ${CYAN}${WG_IP}${NC}"
    echo -e "    WG:      $(echo -e "$WG_STATUS")"
    echo -e "    Created: ${CREATED}"
    echo ""
done

if [[ $COUNT -eq 0 ]]; then
    echo -e "  ${DIM}No devices registered yet.${NC}"
    echo -e "  Run: ${CYAN}make add-device${NC}"
else
    echo -e "  ${DIM}Total: ${COUNT} device(s)${NC}"
fi
echo ""
