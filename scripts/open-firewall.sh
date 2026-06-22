#!/usr/bin/env bash
# open-firewall.sh — Configure UFW for POS Remote Control VPS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"
[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"

WG_PORT="${WG_PORT:-51820}"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "SSH admin access"
ufw allow 80/tcp    comment "HTTP (Let's Encrypt ACME + redirect)"
ufw allow 443/tcp   comment "HTTPS (Guacamole)"
ufw allow "${WG_PORT}/udp" comment "WireGuard VPN"
ufw --force enable

echo -e "  UFW rules applied (SSH 22, HTTP 80, HTTPS 443, WG ${WG_PORT}/udp)"
ufw status numbered
