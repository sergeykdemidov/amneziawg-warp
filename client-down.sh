#!/bin/bash
set -e

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

NETBIRD_FWMARK="${NETBIRD_FWMARK:-0x1bd00}"
AWG_FT_MARK_PRIO=9998
AWG_FT_MAIN_PRIO=9999
AWG_FT_DEF_PRIO=10000

if [ -f "$RULES_FILE" ]; then
    while read -r route; do
        ip rule del to "$route" lookup "$AWG_TABLE" pref "$AWG_PRIO" 2>/dev/null || true
    done < "$RULES_FILE"
    rm -f "$RULES_FILE"
fi

# Правила полного туннеля (если включался FULL_TUNNEL). Удаляем по точным
# селекторам+приоритетам, поэтому правила NetBird (pref 105/110) не затрагиваются.
ip rule del from all lookup "$AWG_TABLE" pref "$AWG_FT_DEF_PRIO" 2>/dev/null || true
ip rule del from all lookup main suppress_prefixlength 0 pref "$AWG_FT_MAIN_PRIO" 2>/dev/null || true
ip rule del fwmark "$NETBIRD_FWMARK" lookup main pref "$AWG_FT_MARK_PRIO" 2>/dev/null || true

ip route flush table "$AWG_TABLE" 2>/dev/null || true
ip route del "$SERVER_IP/32" 2>/dev/null || true

awg-quick down awg0 2>/dev/null || true

sysctl -w net.ipv6.conf.all.disable_ipv6=0     > /dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null

echo "awg0: down"
