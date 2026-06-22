#!/usr/bin/env bash
# remove-device.sh — Remove a POS device (WG peer + Guacamole connections + device dir)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
warn() { echo -e "  ${YELLOW}!${NC}  $*"; }
die()  { echo -e "\n${RED}[ERROR]${NC} $*" >&2; exit 1; }

pg_exec() { docker exec pos-postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAq -c "$1"; }

# ── List devices ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Remove POS Device${NC}"
echo ""

DEVICES=()
for meta in "$SCRIPT_DIR/devices"/*/meta.conf; do
    [[ -f "$meta" ]] || continue
    source "$meta"
    DEVICES+=("$DEVICE_NAME")
    echo "  $((${#DEVICES[@]})).  ${DEVICE_NAME}  (${WG_IP})"
done

[[ ${#DEVICES[@]} -eq 0 ]] && { echo "  No devices registered."; exit 0; }

echo ""
read -rp "  Enter device name to remove: " INPUT_NAME
INPUT_NAME=$(echo "$INPUT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

DEVICE_DIR="$SCRIPT_DIR/devices/${INPUT_NAME}"
[[ -d "$DEVICE_DIR" ]] || die "Device '${INPUT_NAME}' not found"

source "${DEVICE_DIR}/meta.conf"

echo ""
warn "This will PERMANENTLY remove:"
echo "    • WireGuard peer  (${WG_IP})"
echo "    • Guacamole connections (VNC + SSH)"
echo "    • Device directory: devices/${DEVICE_NAME}/"
echo ""
read -rp "  Type device name to confirm: " CONFIRM
[[ "$CONFIRM" == "$DEVICE_NAME" ]] || die "Confirmation mismatch — aborted"

# ── Remove WireGuard peer ─────────────────────────────────────────────────────
WG_CONF="/etc/wireguard/wg0.conf"
if [[ -f "$WG_CONF" ]]; then
    # Remove peer block (# Name: DEVICE_NAME ... until next blank line or EOF)
    python3 - "$WG_CONF" "$WG_PUBKEY" << 'PYEOF'
import sys

conf_path, pubkey = sys.argv[1], sys.argv[2]
with open(conf_path) as f:
    lines = f.readlines()

result = []
i = 0
while i < len(lines):
    # Detect start of a [Peer] block
    if lines[i].strip() == '[Peer]':
        block = [lines[i]]
        j = i + 1
        # Collect lines until next section header or EOF
        while j < len(lines) and not lines[j].strip().startswith('['):
            block.append(lines[j])
            j += 1
        # Only keep this block if it does NOT contain our pubkey
        block_text = ''.join(block)
        if pubkey not in block_text:
            result.extend(block)
        # else: skip the block (this removes the peer)
        i = j
    else:
        result.append(lines[i])
        i += 1

with open(conf_path, 'w') as f:
    f.writelines(result)
print("  WG peer removed from config")
PYEOF
    wg set wg0 peer "$WG_PUBKEY" remove 2>/dev/null && ok "WireGuard peer removed (hot)" || \
        warn "WG hot-remove failed — will apply on next wg-quick restart"
fi

# ── Remove Guacamole connections ──────────────────────────────────────────────
pg_exec "
DELETE FROM guacamole_connection
WHERE connection_name IN ('${DEVICE_NAME} — VNC', '${DEVICE_NAME} — SSH')
  AND parent_id = (SELECT connection_group_id FROM guacamole_connection_group
                   WHERE connection_group_name = 'POS Devices');
"
ok "Guacamole connections removed"

# ── Remove device directory ───────────────────────────────────────────────────
rm -rf "$DEVICE_DIR"
ok "Device directory removed"

echo ""
ok "Device '${DEVICE_NAME}' removed."
echo ""
