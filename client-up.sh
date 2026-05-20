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
CLIENT_IP=$(jq -r '.client_ip // "10.8.0.2"' "$STATE_FILE")
GATEWAY=$(jq -r '.gateway'     "$STATE_FILE")
IFACE=$(jq -r '.iface'       "$STATE_FILE")
AWG_TABLE=$(jq -r '.awg_table'  "$STATE_FILE")
AWG_PRIO=$(jq -r '.awg_prio'   "$STATE_FILE")
RULES_FILE=$(jq -r '.rules_file'  "$STATE_FILE")
AWG_PORT=$(jq -r '.awg_port'   "$STATE_FILE")
AWG_JC=$(jq -r '.awg_jc'     "$STATE_FILE")
AWG_JMIN=$(jq -r '.awg_jmin'   "$STATE_FILE")
AWG_JMAX=$(jq -r '.awg_jmax'   "$STATE_FILE")
AWG_S1=$(jq -r '.awg_s1'     "$STATE_FILE")
AWG_S2=$(jq -r '.awg_s2'     "$STATE_FILE")
AWG_H1=$(jq -r '.awg_h1'     "$STATE_FILE")
AWG_H2=$(jq -r '.awg_h2'     "$STATE_FILE")
AWG_H3=$(jq -r '.awg_h3'     "$STATE_FILE")
AWG_H4=$(jq -r '.awg_h4'     "$STATE_FILE")

mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"

cat > "$CONF_DIR/awg0.conf" << EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $CLIENT_IP/24
DNS = 1.1.1.1, 8.8.8.8
SaveConfig = false
Table = off
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$CONF_DIR/awg0.conf"

if awg show awg0 &>/dev/null; then
    echo "ОШИБКА: awg0 уже запущен. Сначала запусти client-down.sh" >&2
    exit 1
fi

sysctl -w net.ipv6.conf.all.disable_ipv6=1     > /dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null

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
