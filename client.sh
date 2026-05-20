#!/bin/bash
set -e

echo "========================================================="
echo " УСТАНОВКА КЛИЕНТА — AmneziaWG"
echo "========================================================="

if [ -z "$CLIENT_PRIV" ] || [ -z "$SERVER_PUB" ] || [ -z "$SERVER_IP" ]; then
    echo "ОШИБКА: не заданы переменные. Запускай командой от сервера."
    exit 1
fi

# ── 1. Зачистка ──────────────────────────────────────────────
echo "[1/4] Зачистка..."
systemctl stop awg-quick@awg0  2>/dev/null || true
systemctl stop tun2socks       2>/dev/null || true
awg-quick down awg0            2>/dev/null || true
ip link delete awg0            2>/dev/null || true
ip link delete warp0           2>/dev/null || true
ip rule del from 10.8.0.0/24 table 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true
rm -rf /etc/amnezia/amneziawg /etc/amneziawg

# ── 2. Установка ─────────────────────────────────────────────
echo "[2/4] Установка amneziawg..."
apt update -qq
apt install -y amneziawg curl iproute2 iputils-ping

# ── 3. Конфиг ────────────────────────────────────────────────
echo "[3/4] Создание конфига..."

DEFAULT_GW=$(ip route | grep "^default" | awk '{print $3}' | head -1)
DEFAULT_IF=$(ip route | grep "^default" | awk '{print $5}' | head -1)
echo "  Шлюз     : $DEFAULT_GW (${DEFAULT_IF})"
echo "  Сервер   : $SERVER_IP"

mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

cat > /etc/amnezia/amneziawg/awg0.conf << EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.8.0.2/24
DNS = 1.1.1.1, 8.8.8.8
SaveConfig = false
Jc = 4
Jmin = 40
Jmax = 70
S1 = 15
S2 = 25
H1 = 12345678
H2 = 87654321
H3 = 11223344
H4 = 44332211

# Маршрут до сервера через реальный шлюз — иначе туннель зациклится
PostUp   = ip route add $SERVER_IP/32 via $DEFAULT_GW dev $DEFAULT_IF 2>/dev/null || true
PostDown = ip route del $SERVER_IP/32 2>/dev/null || true

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:51820
# Два префикса вместо 0.0.0.0/0 — не перекрывают хост-маршруты
AllowedIPs = 0.0.0.0/1, 128.0.0.0/1
PersistentKeepalive = 25
EOF
chmod 600 /etc/amnezia/amneziawg/awg0.conf

# ── 4. Запуск ────────────────────────────────────────────────
echo "[4/4] Запуск туннеля..."
systemctl enable awg-quick@awg0
systemctl restart awg-quick@awg0

echo "  Ожидаем поднятия туннеля (15 сек)..."
for i in $(seq 1 15); do
    if systemctl is-active --quiet awg-quick@awg0; then
        HS=$(awg show awg0 2>/dev/null | grep "latest handshake" || true)
        if [ -n "$HS" ]; then
            echo "  ✓ Туннель поднят, handshake есть (${i} сек)"
            break
        fi
    fi
    sleep 1
done

# ── Диагностика ───────────────────────────────────────────────
echo ""
echo "========================================================="
echo " ДИАГНОСТИКА КЛИЕНТА"
echo "========================================================="

AWG_ST=$(systemctl is-active awg-quick@awg0 || true)
AWG_SHOW=$(awg show awg0 2>/dev/null || true)
printf "%-22s %s\n" "awg-quick@awg0:" "$AWG_ST"
echo ""
echo " Туннель:"
echo "$AWG_SHOW" | grep -E "(endpoint|handshake|transfer|allowed)" | sed 's/^/  /'
echo ""
echo " Маршруты:"
ip route show | grep -E "(default|awg0|10\.8\.|$SERVER_IP)" | sed 's/^/  /'
echo "---------------------------------------------------------"

# Пинг
echo " Пинг 10.8.0.1 (шлюз туннеля):"
if ping -c 2 -W 3 10.8.0.1 > /tmp/p1.txt 2>&1; then
    grep -E "(bytes from|rtt)" /tmp/p1.txt | sed 's/^/  /'
    echo "  ✓ OK"
else
    echo "  ✗ НЕДОСТУПЕН"
fi

echo ""
echo " Пинг 1.1.1.1:"
if ping -c 2 -W 3 1.1.1.1 > /tmp/p2.txt 2>&1; then
    grep -E "(bytes from|rtt)" /tmp/p2.txt | sed 's/^/  /'
    echo "  ✓ OK"
else
    echo "  ✗ НЕДОСТУПЕН"
fi

echo ""
echo " Внешний IP через туннель:"
EXT_IP=$(curl -s --max-time 15 ifconfig.me \
      || curl -s --max-time 15 api.ipify.org \
      || curl -s --max-time 15 icanhazip.com \
      || echo "НЕ ПОЛУЧЕН")
echo "  $EXT_IP"
echo "========================================================="

# Итог
if echo "$EXT_IP" | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"; then
    if [ "$EXT_IP" = "$SERVER_IP" ]; then
        echo ""
        echo "⚠  IP совпадает с сервером ($SERVER_IP)"
        echo "   Трафик идёт без WARP. Проверь на сервере:"
        echo "     systemctl status tun2socks"
        echo "     systemctl status awg-warp-routes"
        echo "     ip rule show"
        echo "     ip route show table 100"
    else
        echo ""
        echo "✓ Всё работает!"
        echo "  Сервер  : $SERVER_IP"
        echo "  Через WARP: $EXT_IP"
    fi
else
    echo ""
    echo "✗ IP не получен. Проверь на сервере:"
    echo "  systemctl status tun2socks"
    echo "  systemctl status awg-warp-routes"
    echo "  ip rule show"
    echo "  ip route show table 100"
    echo "  journalctl -u tun2socks -n 30"
fi
echo ""
