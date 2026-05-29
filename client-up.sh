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

ROUTE_COUNT=$(wc -l < "$RULES_FILE")
echo "awg0: up | маршрутов: $ROUTE_COUNT"

echo ""
echo "--- Диагностика ---"
ERRORS=0

for i in $(seq 1 10); do
    if awg show awg0 | grep -q "latest handshake"; then
        HANDSHAKE=$(awg show awg0 | awk '/latest handshake/{print $3, $4, $5, $6}')
        echo "  ✓ AWG handshake: $HANDSHAKE"
        break
    fi
    if [ "$i" -eq 10 ]; then
        echo "  ✗ AWG handshake не произошёл (туннель не установлен)"
        ERRORS=$((ERRORS+1))
    fi
    sleep 1
done

if ip rule show | grep -q "lookup $AWG_TABLE"; then
    echo "  ✓ Policy rules: $(ip rule show | grep -c "lookup $AWG_TABLE") правил в таблице $AWG_TABLE"
else
    echo "  ✗ Policy rules не найдены"
    ERRORS=$((ERRORS+1))
fi

DNS_SERVER=$(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}')
if host -W 3 rutracker.org "$DNS_SERVER" &>/dev/null 2>&1; then
    echo "  ✓ DNS ($DNS_SERVER): работает"
else
    echo "  ✗ DNS ($DNS_SERVER): не отвечает"
    ERRORS=$((ERRORS+1))
fi

CHECK_HOST="rutracker.org"
CHECK_IP=$(jq -r '.routes[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/32$"))' "$STATE_FILE" | head -1 | cut -d/ -f1)
if [ -n "$CHECK_IP" ]; then
    if curl -s --max-time 5 --interface awg0 "https://$CHECK_HOST" -o /dev/null -w "%{http_code}" 2>/dev/null | grep -qE "^[23]"; then
        echo "  ✓ TCP через туннель ($CHECK_HOST): OK"
    else
        echo "  ✗ TCP через туннель ($CHECK_HOST): нет ответа"
        ERRORS=$((ERRORS+1))
    fi
fi

if [ "$ERRORS" -eq 0 ]; then
    echo ""
    echo "✓ Туннель работает"
else
    echo ""
    echo "✗ Есть проблемы ($ERRORS). Проверь: awg show awg0 | journalctl -u awg-quick@awg0"
fi
