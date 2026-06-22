#!/usr/bin/env bash
# add-device.sh — Register a new POS device
# Creates: WireGuard peer + Guacamole VNC + SSH connections + remote-access.conf
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC}  $*"; }
info() { echo -e "  ${CYAN}→${NC}  $*"; }
die()  { echo -e "\n${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
pg_exec() {
    docker exec pos-postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAq -c "$1"
}

next_available_ip() {
    local subnet_base="${WG_SUBNET%.*}"   # e.g. 10.8.0
    local used_ips=()
    for meta in "$SCRIPT_DIR/devices"/*/meta.conf; do
        [[ -f "$meta" ]] || continue
        source "$meta"
        used_ips+=("${WG_IP%%/*}")
    done
    for i in $(seq 2 254); do
        local candidate="${subnet_base}.${i}"
        if ! printf '%s\n' "${used_ips[@]:-}" | grep -q "^${candidate}$"; then
            echo "${candidate}"
            return
        fi
    done
    die "No available IPs in subnet ${WG_SUBNET}"
}

# ── Input ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}  Add POS Device${NC}"
echo ""

read -rp "  Device name (e.g. pos-berlin-01): " DEVICE_NAME
DEVICE_NAME=$(echo "$DEVICE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g')
[[ -z "$DEVICE_NAME" ]] && die "Device name cannot be empty"

DEVICE_DIR="$SCRIPT_DIR/devices/${DEVICE_NAME}"
if [[ -d "$DEVICE_DIR" ]]; then
    die "Device '${DEVICE_NAME}' already exists. See: devices/${DEVICE_NAME}/"
fi

read -rp "  Location / description (optional): " DEVICE_LOCATION
read -rsp "  VNC password for this device:      " VNC_PASSWORD
echo ""
read -rp "  SSH username on POS device:        " SSH_USERNAME
read -rsp "  SSH password on POS device:        " SSH_PASSWORD
echo ""

# ── Assign IP ─────────────────────────────────────────────────────────────────
WG_CLIENT_IP_ADDR=$(next_available_ip)
WG_CLIENT_IP="${WG_CLIENT_IP_ADDR}/32"
info "Assigned WireGuard IP: ${WG_CLIENT_IP}"

# ── Generate device WireGuard keypair ─────────────────────────────────────────
mkdir -p "$DEVICE_DIR"
DEVICE_PRIVKEY=$(wg genkey)
DEVICE_PUBKEY=$(echo "$DEVICE_PRIVKEY" | wg pubkey)
echo "$DEVICE_PUBKEY" > "${DEVICE_DIR}/wg-pubkey.txt"
ok "Device keypair generated"

# ── Write device metadata ─────────────────────────────────────────────────────
cat > "${DEVICE_DIR}/meta.conf" << EOF
DEVICE_NAME=${DEVICE_NAME}
DEVICE_LOCATION=${DEVICE_LOCATION}
WG_IP=${WG_CLIENT_IP}
WG_PUBKEY=${DEVICE_PUBKEY}
CREATED=$(date +%Y-%m-%d)
EOF

# ── Add WireGuard peer to server config ───────────────────────────────────────
WG_CONF="/etc/wireguard/wg0.conf"
[[ ! -f "$WG_CONF" ]] && die "WireGuard server config not found: ${WG_CONF}. Run: make setup"

cat >> "$WG_CONF" << EOF

[Peer]
# Name: ${DEVICE_NAME}${DEVICE_LOCATION:+  Location: ${DEVICE_LOCATION}}
PublicKey  = ${DEVICE_PUBKEY}
AllowedIPs = ${WG_CLIENT_IP}
EOF

# Hot-add peer to running WireGuard (no restart, no downtime for other peers)
wg set wg0 peer "${DEVICE_PUBKEY}" allowed-ips "${WG_CLIENT_IP}"
ok "WireGuard peer added (hot, no restart needed)"

# ── Add Guacamole connections ─────────────────────────────────────────────────
info "Registering Guacamole connections..."

# Ensure connection group exists (safe insert without ON CONFLICT on nullable column)
pg_exec "
INSERT INTO guacamole_connection_group (connection_group_name, type)
SELECT 'POS Devices', 'ORGANIZATIONAL'
WHERE NOT EXISTS (
    SELECT 1 FROM guacamole_connection_group WHERE connection_group_name = 'POS Devices'
);
" 2>/dev/null || true

GROUP_ID=$(pg_exec "SELECT connection_group_id FROM guacamole_connection_group WHERE connection_group_name = 'POS Devices' LIMIT 1;")

# VNC connection
VNC_CONN_ID=$(pg_exec "
INSERT INTO guacamole_connection (connection_name, protocol, parent_id)
VALUES ('${DEVICE_NAME} — VNC', 'vnc', ${GROUP_ID})
RETURNING connection_id;
")
pg_exec "
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value) VALUES
  (${VNC_CONN_ID}, 'hostname', '${WG_CLIENT_IP_ADDR}'),
  (${VNC_CONN_ID}, 'port',     '5901'),
  (${VNC_CONN_ID}, 'password', '${VNC_PASSWORD}');
"
ok "Guacamole VNC connection created"

# SSH connection
SSH_CONN_ID=$(pg_exec "
INSERT INTO guacamole_connection (connection_name, protocol, parent_id)
VALUES ('${DEVICE_NAME} — SSH', 'ssh', ${GROUP_ID})
RETURNING connection_id;
")
pg_exec "
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value) VALUES
  (${SSH_CONN_ID}, 'hostname', '${WG_CLIENT_IP_ADDR}'),
  (${SSH_CONN_ID}, 'port',     '22'),
  (${SSH_CONN_ID}, 'username', '${SSH_USERNAME}'),
  (${SSH_CONN_ID}, 'password', '${SSH_PASSWORD}');
"
ok "Guacamole SSH connection created"

# Grant admin user READ permission on both connections
ADMIN_ENTITY_ID=$(pg_exec "SELECT e.entity_id FROM guacamole_entity e WHERE e.name = '${GUAC_ADMIN_USER}' AND e.type = 'USER' LIMIT 1;")
pg_exec "
INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission) VALUES
  (${ADMIN_ENTITY_ID}, ${VNC_CONN_ID}, 'READ'),
  (${ADMIN_ENTITY_ID}, ${SSH_CONN_ID}, 'READ')
ON CONFLICT DO NOTHING;
"
ok "Permissions granted to admin"

# ── Generate remote-access.conf for POS device ───────────────────────────────
WG_SERVER_PUBKEY=$(cat "$SCRIPT_DIR/wireguard/server-public.key" 2>/dev/null || \
    sudo wg show wg0 public-key 2>/dev/null || echo "UNKNOWN")

WG_SUBNET_ONLY="${WG_SUBNET}"  # e.g. 10.8.0.0/24

cat > "${DEVICE_DIR}/remote-access.conf" << EOF
# remote-access.conf — WireGuard + VNC config for ${DEVICE_NAME}
# Generated: $(date)
# Copy this file to the POS device and run:
#   sudo ./setup-remote-access.sh --config ./remote-access.conf

WG_SERVER_ENDPOINT=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "VPS_IP"):${WG_PORT}
WG_SERVER_PUBKEY=${WG_SERVER_PUBKEY}
WG_CLIENT_IP=${WG_CLIENT_IP}
WG_ALLOWED_IPS=${WG_SUBNET_ONLY}
VNC_PASSWORD=${VNC_PASSWORD}
EOF
chmod 600 "${DEVICE_DIR}/remote-access.conf"
ok "remote-access.conf generated"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}  ✓ Device '${DEVICE_NAME}' registered successfully${NC}"
echo ""
echo -e "  ${BOLD}WireGuard IP:${NC}      ${WG_CLIENT_IP}"
echo -e "  ${BOLD}VNC in Guacamole:${NC}  ${DEVICE_NAME} — VNC"
echo -e "  ${BOLD}SSH in Guacamole:${NC}  ${DEVICE_NAME} — SSH"
echo -e "  ${BOLD}Config file:${NC}       devices/${DEVICE_NAME}/remote-access.conf"
echo ""
echo -e "  ${CYAN}Copy to POS device and run:${NC}"
echo "    scp devices/${DEVICE_NAME}/remote-access.conf user@<pos-ip>:~/"
echo "    ssh user@<pos-ip>"
echo "    sudo ./setup-remote-access.sh --config ~/remote-access.conf"
echo ""
