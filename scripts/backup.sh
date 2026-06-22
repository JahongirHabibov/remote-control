#!/usr/bin/env bash
# backup.sh — Backup Guacamole DB + WireGuard configs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"

BACKUP_DIR="$SCRIPT_DIR/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "  Creating backup in: ${BACKUP_DIR}"

# PostgreSQL dump
docker exec pos-postgres pg_dump \
    -U "${POSTGRES_USER}" \
    "${POSTGRES_DB}" > "${BACKUP_DIR}/guacamole-db.sql"
echo "  ✓  Guacamole database"

# WireGuard server config (private key included — keep secure!)
if [[ -f "/etc/wireguard/wg0.conf" ]]; then
    cp /etc/wireguard/wg0.conf "${BACKUP_DIR}/wg0.conf"
    chmod 600 "${BACKUP_DIR}/wg0.conf"
    echo "  ✓  WireGuard server config"
fi

# Device configs
if [[ -d "$SCRIPT_DIR/devices" ]]; then
    cp -r "$SCRIPT_DIR/devices" "${BACKUP_DIR}/devices"
    echo "  ✓  Device configs"
fi

# guacamole.properties
if [[ -f "$SCRIPT_DIR/guacamole/guacamole.properties" ]]; then
    cp "$SCRIPT_DIR/guacamole/guacamole.properties" "${BACKUP_DIR}/"
    echo "  ✓  guacamole.properties"
fi

# Create compressed archive
tar -czf "${BACKUP_DIR}.tar.gz" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"
rm -rf "$BACKUP_DIR"
chmod 600 "${BACKUP_DIR}.tar.gz"

echo ""
echo "  Backup saved: ${BACKUP_DIR}.tar.gz"
echo "  Size: $(du -sh "${BACKUP_DIR}.tar.gz" | cut -f1)"
