#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: нужен root. Запускай: sudo $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/awg-state.json"

if [ ! -f "$STATE_FILE" ]; then
    echo "ОШИБКА: $STATE_FILE не найден" >&2
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip'  "$STATE_FILE")
AWG_TABLE=$(jq -r '.awg_table' "$STATE_FILE")
AWG_PRIO=$(jq -r '.awg_prio'  "$STATE_FILE")
RULES_FILE=$(jq -r '.rules_file' "$STATE_FILE")

if [ -f "$RULES_FILE" ]; then
    while read -r route; do
        ip rule del to "$route" lookup "$AWG_TABLE" pref "$AWG_PRIO" 2>/dev/null || true
    done < "$RULES_FILE"
    rm -f "$RULES_FILE"
fi

ip route flush table "$AWG_TABLE" 2>/dev/null || true
ip route del "$SERVER_IP/32" 2>/dev/null || true

awg-quick down awg0 2>/dev/null || true

echo "awg0: down"
