#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: нужен root. Запускай: sudo $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/awg-state.json"
CONF_DIR=/etc/amnezia/amneziawg

if [ ! -f "$STATE_FILE" ]; then
    echo "ОШИБКА: $STATE_FILE не найден. Запусти client-setup.sh" >&2
    exit 1
fi

SERVER_IP=$(jq -r '.server_ip'   "$STATE_FILE")
SERVER_PUB=$(jq -r '.server_pub'  "$STATE_FILE")
CLIENT_PRIV=$(jq -r '.client_priv' "$STATE_FILE")
GATEWAY=$(jq -r '.gateway'     "$STATE_FILE")
IFACE=$(jq -r '.iface'       "$STATE_FILE")
AWG_TABLE=$(jq -r '.awg_table'  "$STATE_FILE")
AWG_PRIO=$(jq -r '.awg_prio'   "$STATE_FILE")
RULES_FILE=$(jq -r '.rules_file'  "$STATE_FILE")

mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

cat > "$CONF_DIR/awg0.conf" << EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.8.0.2/24
DNS = 1.1.1.1, 8.8.8.8
SaveConfig = false
Table = off
Jc = 4
Jmin = 40
Jmax = 70
S1 = 15
S2 = 25
H1 = 12345678
H2 = 87654321
H3 = 11223344
H4 = 44332211

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$CONF_DIR/awg0.conf"

if awg show awg0 &>/dev/null; then
    echo "ОШИБКА: awg0 уже запущен. Сначала запусти client-down.sh" >&2
    exit 1
fi

awg-quick up awg0

ip route add "$SERVER_IP/32" via "$GATEWAY" dev "$IFACE" 2>/dev/null || true

ip route flush table "$AWG_TABLE" 2>/dev/null || true
ip route add default dev awg0 table "$AWG_TABLE"

> "$RULES_FILE"
while read -r route; do
    if ip rule add to "$route" lookup "$AWG_TABLE" pref "$AWG_PRIO" 2>/dev/null; then
        echo "$route" >> "$RULES_FILE"
    fi
done < <(jq -r '.routes[]' "$STATE_FILE")

echo "awg0: up | маршрутов: $(wc -l < "$RULES_FILE")"
