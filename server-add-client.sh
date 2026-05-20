#!/bin/bash
set -e

echo "========================================================="
echo " ДОБАВЛЕНИЕ КЛИЕНТА — AmneziaWG"
echo "========================================================="

if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: нужен root. Запускай: sudo $0" >&2
    exit 1
fi

CONF=/etc/amnezia/amneziawg/awg0.conf

if [ ! -f "$CONF" ]; then
    echo "ОШИБКА: $CONF не найден. Сначала запусти server.sh" >&2
    exit 1
fi

if ! systemctl is-active --quiet awg-quick@awg0; then
    echo "ОШИБКА: awg-quick@awg0 не запущен" >&2
    exit 1
fi

LAST_OCTET=$(grep -E '^AllowedIPs\s*=\s*10\.8\.0\.' "$CONF" \
    | grep -oE '10\.8\.0\.[0-9]+' \
    | awk -F. '{print $4}' \
    | sort -n \
    | tail -1)
LAST_OCTET=${LAST_OCTET:-1}
NEXT_OCTET=$((LAST_OCTET + 1))

if [ "$NEXT_OCTET" -gt 254 ]; then
    echo "ОШИБКА: нет свободных IP в 10.8.0.0/24" >&2
    exit 1
fi

CLIENT_IP="10.8.0.$NEXT_OCTET"

CLIENT_PRIV=$(awg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | awg pubkey)

SERVER_PRIV=$(awk '/^PrivateKey/{print $3}' "$CONF")
SERVER_PUB=$(echo "$SERVER_PRIV" | awg pubkey)
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org)
AWG_PORT=$(awk '/^ListenPort/{print $3}' "$CONF")
AWG_JC=$(awk '/^Jc/{print $3}'   "$CONF")
AWG_JMIN=$(awk '/^Jmin/{print $3}' "$CONF")
AWG_JMAX=$(awk '/^Jmax/{print $3}' "$CONF")
AWG_S1=$(awk '/^S1/{print $3}'   "$CONF")
AWG_S2=$(awk '/^S2/{print $3}'   "$CONF")
AWG_H1=$(awk '/^H1/{print $3}'   "$CONF")
AWG_H2=$(awk '/^H2/{print $3}'   "$CONF")
AWG_H3=$(awk '/^H3/{print $3}'   "$CONF")
AWG_H4=$(awk '/^H4/{print $3}'   "$CONF")

cat >> "$CONF" << EOF

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = $CLIENT_IP/32
EOF

awg set awg0 peer "$CLIENT_PUB" allowed-ips "$CLIENT_IP/32"

echo ""
echo "  ✓ Клиент добавлен: $CLIENT_IP"
echo "  ✓ Пир зарегистрирован в awg0 (без перезапуска)"
echo ""
echo "========================================================="
echo " Запусти на клиентской машине:"
echo "========================================================="
echo ""
echo "  sudo CLIENT_PRIV=\"$CLIENT_PRIV\" \\"
echo "       SERVER_PUB=\"$SERVER_PUB\" \\"
echo "       SERVER_IP=\"$SERVER_IP\" \\"
echo "       CLIENT_IP=\"$CLIENT_IP\" \\"
echo "       AWG_PORT=\"$AWG_PORT\" \\"
echo "       AWG_JC=\"$AWG_JC\" AWG_JMIN=\"$AWG_JMIN\" AWG_JMAX=\"$AWG_JMAX\" \\"
echo "       AWG_S1=\"$AWG_S1\" AWG_S2=\"$AWG_S2\" \\"
echo "       AWG_H1=\"$AWG_H1\" AWG_H2=\"$AWG_H2\" AWG_H3=\"$AWG_H3\" AWG_H4=\"$AWG_H4\" \\"
echo "       bash client-setup.sh"
echo ""
