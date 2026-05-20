#!/bin/bash
set -e

echo "========================================================="
echo " УСТАНОВКА СЕРВЕРА — AmneziaWG + WARP"
echo "========================================================="

# ── 1. Зачистка ──────────────────────────────────────────────
echo "[1/8] Зачистка..."
systemctl stop awg-quick@awg0    2>/dev/null || true
systemctl disable awg-quick@awg0 2>/dev/null || true
awg-quick down awg0              2>/dev/null || true
ip link delete awg0              2>/dev/null || true
systemctl stop tun2socks         2>/dev/null || true
systemctl disable tun2socks      2>/dev/null || true
ip link delete warp0             2>/dev/null || true
rm -f /etc/systemd/system/tun2socks.service
rm -f /etc/systemd/system/awg-warp-routes.service
rm -rf /etc/amnezia /etc/amneziawg
ip rule del from 10.8.0.0/24 table 100 pref 100 2>/dev/null || true
ip rule del to   10.8.0.0/24 table main pref  99 2>/dev/null || true
ip route flush table 100 2>/dev/null || true
iptables -t mangle -F PREROUTING 2>/dev/null || true
iptables -t nat -F PREROUTING  2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD            2>/dev/null || true
ip rule del fwmark 53 table main 2>/dev/null || true
systemctl daemon-reload
echo "  ✓ готово"

# ── 2. Пакеты ────────────────────────────────────────────────
echo "[2/8] Установка пакетов..."
apt update -qq
apt install -y amneziawg iptables curl wget iproute2 unzip

if ! command -v warp-cli &>/dev/null; then
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
        | gpg --yes --dearmor --output /usr/share/keyrings/cf-warp-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cf-warp-keyring.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        | tee /etc/apt/sources.list.d/cloudflare-client.list
    apt update -qq
    apt install -y cloudflare-warp
fi

if ! command -v tun2socks &>/dev/null; then
    TUN2SOCKS_VER="2.5.2"
    case "$(dpkg --print-architecture)" in
        amd64) T2S_ARCH="linux-amd64" ;;
        arm64) T2S_ARCH="linux-arm64" ;;
        armhf) T2S_ARCH="linux-armv7" ;;
        *)     T2S_ARCH="linux-amd64" ;;
    esac
    echo "  Загружаем tun2socks ${TUN2SOCKS_VER}..."
    wget -qO /tmp/tun2socks.zip \
        "https://github.com/xjasonlyu/tun2socks/releases/download/v${TUN2SOCKS_VER}/tun2socks-${T2S_ARCH}.zip"
    unzip -o /tmp/tun2socks.zip -d /tmp/t2s
    install -m 755 /tmp/t2s/tun2socks-${T2S_ARCH} /usr/local/bin/tun2socks
    rm -rf /tmp/tun2socks.zip /tmp/t2s
fi
echo "  tun2socks: $(tun2socks --version 2>&1 | head -1)"

# ── 3. WARP ──────────────────────────────────────────────────
echo "[3/8] Настройка WARP..."
warp-cli registration delete 2>/dev/null || true
sleep 1
echo | warp-cli --accept-tos registration new
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40001
warp-cli --accept-tos connect

echo "  Ожидаем WARP (до 30 сек)..."
WARP_OK=0
for i in $(seq 1 30); do
    STATUS=$(warp-cli status 2>/dev/null | head -1)
    if echo "$STATUS" | grep -qi "connected"; then
        echo "  ✓ WARP подключён (${i} сек)"
        WARP_OK=1
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ WARP не подключился!"
        warp-cli status
        exit 1
    fi
    sleep 1
done

for i in $(seq 1 10); do
    if nc -z 127.0.0.1 40001 2>/dev/null; then
        echo "  ✓ WARP proxy :40001 OK"
        break
    fi
    if [ "$i" -eq 10 ]; then
        echo "  ✗ WARP proxy :40001 не отвечает!"
        exit 1
    fi
    sleep 1
done

# ── 4. tun2socks ─────────────────────────────────────────────
echo "[4/8] Настройка tun2socks..."

# Создаём TUN-интерфейс ДО запуска сервиса
ip tuntap add dev warp0 mode tun 2>/dev/null || true
ip addr add 198.18.0.1/15 dev warp0 2>/dev/null || true
ip link set warp0 up

cat > /etc/systemd/system/tun2socks.service << 'EOF'
[Unit]
Description=tun2socks WARP bridge
After=network.target warp-svc.service
Wants=warp-svc.service

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'ip tuntap add dev warp0 mode tun 2>/dev/null || true'
ExecStartPre=/bin/sh -c 'ip addr add 198.18.0.1/15 dev warp0 2>/dev/null || true'
ExecStartPre=/bin/sh -c 'ip link set warp0 up'
ExecStart=/usr/local/bin/tun2socks \
    -device warp0 \
    -proxy socks5://127.0.0.1:40001 \
    -loglevel warning
ExecStopPost=/bin/sh -c 'ip link delete warp0 2>/dev/null || true'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tun2socks
systemctl restart tun2socks

echo "  Ожидаем warp0 UP (до 15 сек)..."
for i in $(seq 1 15); do
    if ip link show warp0 2>/dev/null | grep -q "UP"; then
        echo "  ✓ warp0 UP (${i} сек)"
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "  ✗ warp0 не поднялся!"
        journalctl -u tun2socks -n 20 --no-pager
        exit 1
    fi
    sleep 1
done

# ── 5. Форвардинг ────────────────────────────────────────────
echo "[5/8] IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf \
    || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# ── 6. Ключи и конфиг AWG ────────────────────────────────────
echo "[6/8] Генерация ключей..."
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

SERVER_PRIV=$(awg genkey)
SERVER_PUB=$(echo "$SERVER_PRIV" | awg pubkey)
CLIENT_PRIV=$(awg genkey)
CLIENT_PUB=$(echo "$CLIENT_PRIV" | awg pubkey)
CLIENT_IP="10.8.0.2"

AWG_PORT=$(shuf -i 10000-65000 -n 1)
AWG_JC=$(shuf -i 3-7 -n 1)
AWG_JMIN=$(shuf -i 30-60 -n 1)
AWG_JMAX=$(shuf -i 61-120 -n 1)
AWG_S1=$(shuf -i 20-80 -n 1)
AWG_S2=$(shuf -i 20-80 -n 1)
AWG_H1=$(shuf -i 100000000-999999999 -n 1)
AWG_H2=$(shuf -i 100000000-999999999 -n 1)
AWG_H3=$(shuf -i 100000000-999999999 -n 1)
AWG_H4=$(shuf -i 100000000-999999999 -n 1)

EXT_IF=$(ip route | grep "^default" | awk '{print $5}' | head -1)
SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | rev | cut -d: -f1 | rev | head -1)
SSH_PORT=${SSH_PORT:-22}
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org)

echo "  Внешний интерфейс : $EXT_IF"
echo "  SSH порт          : $SSH_PORT"
echo "  Сервер IP         : $SERVER_IP"
echo "  AWG порт          : $AWG_PORT"

cat > /etc/amnezia/amneziawg/awg0.conf << EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = 10.8.0.1/24
ListenPort = $AWG_PORT
SaveConfig = false
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

PostUp = iptables -A FORWARD -i awg0 -j ACCEPT; iptables -A FORWARD -o awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $EXT_IF -j MASQUERADE; iptables -t mangle -A PREROUTING -i awg0 -p udp --dport 53 -j MARK --set-mark 53; iptables -t mangle -A PREROUTING -i awg0 -p tcp --dport 53 -j MARK --set-mark 53; ip rule add fwmark 53 table main pref 95 2>/dev/null || true; ip route add default dev warp0 table 100 2>/dev/null || true; ip rule add from 10.8.0.0/24 table 100 pref 100 2>/dev/null || true; ip rule add to 10.8.0.0/24 table main pref 99 2>/dev/null || true

PostDown = iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $EXT_IF -j MASQUERADE; iptables -t mangle -D PREROUTING -i awg0 -p udp --dport 53 -j MARK --set-mark 53 2>/dev/null || true; iptables -t mangle -D PREROUTING -i awg0 -p tcp --dport 53 -j MARK --set-mark 53 2>/dev/null || true; ip rule del fwmark 53 table main pref 95 2>/dev/null || true; ip route del default dev warp0 table 100 2>/dev/null || true; ip rule del from 10.8.0.0/24 table 100 pref 100 2>/dev/null || true; ip rule del to 10.8.0.0/24 table main pref 99 2>/dev/null || true

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = $CLIENT_IP/32
EOF
chmod 600 /etc/amnezia/amneziawg/awg0.conf

# ── 7. Запуск AWG ─────────────────────────────────────────────
echo "[7/8] Запуск AmneziaWG..."
systemctl enable awg-quick@awg0
systemctl restart awg-quick@awg0 || {
    echo "  ✗ awg-quick@awg0 не запустился!"
    echo "--- journalctl:"
    journalctl -u awg-quick@awg0 -n 30 --no-pager
    echo "--- awg0.conf:"
    cat /etc/amnezia/amneziawg/awg0.conf
    echo "--- ip link:"
    ip link show
    exit 1
}

echo "  Ожидаем awg0 (до 15 сек)..."
for i in $(seq 1 15); do
    if systemctl is-active --quiet awg-quick@awg0; then
        echo "  ✓ awg0 active (${i} сек)"
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "  ✗ awg0 не запустился!"
        journalctl -u awg-quick@awg0 -n 20 --no-pager
        exit 1
    fi
    sleep 1
done

ip route add default dev warp0 table 100 2>/dev/null || true
ip rule add fwmark 53 table main pref 95 2>/dev/null || true
ip rule add from 10.8.0.0/24 table 100 pref 100 2>/dev/null || true
ip rule add to   10.8.0.0/24 table main pref  99 2>/dev/null || true

# ── 8. Диагностика ───────────────────────────────────────────
echo "[8/8] Диагностика..."

echo "  Ожидаем WARP connected + proxy (до 30 сек)..."
for i in $(seq 1 30); do
    STATUS=$(warp-cli status 2>/dev/null | head -1 || true)
    if echo "$STATUS" | grep -qi "connected"; then
        if nc -z 127.0.0.1 40001 2>/dev/null; then
            echo "  ✓ WARP ready (${i} сек)"
            break
        fi
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ✗ WARP не готов!"
        warp-cli status
    fi
    sleep 1
done

AWG_ST=$(systemctl is-active awg-quick@awg0 || true)
T2S_ST=$(systemctl is-active tun2socks || true)
WARP_ST=$(warp-cli status 2>/dev/null | head -1 || true)
WARP0_ST=$(ip link show warp0 2>/dev/null | grep -o "state [A-Z]*" || echo "не найден")

echo ""
echo "========================================================="
echo " ДИАГНОСТИКА СЕРВЕРА"
echo "========================================================="
printf "%-26s %s\n" "awg-quick@awg0:"    "$AWG_ST"
printf "%-26s %s\n" "tun2socks:"         "$T2S_ST"
printf "%-26s %s\n" "WARP статус:"       "$WARP_ST"
printf "%-26s %s\n" "warp0:"             "$WARP0_ST"
echo "---------------------------------------------------------"
echo " ip rules (наши):"
ip rule show | grep -E "(99|100)" || echo "  нет"
echo ""
echo " table 100:"
ip route show table 100 2>/dev/null || echo "  пусто"
echo "---------------------------------------------------------"

DIRECT_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "н/д")
WARP_IP=$(curl -s --socks5 127.0.0.1:40001 --max-time 10 ifconfig.me 2>/dev/null || echo "НЕ ДОСТУПЕН")
printf "%-26s %s\n" "Прямой IP сервера:" "$DIRECT_IP"
printf "%-26s %s\n" "IP через WARP:"     "$WARP_IP"
echo "========================================================="

ERRORS=0
if [ "$AWG_ST" != "active" ]; then echo "✗ awg-quick не работает";  ERRORS=$((ERRORS+1)); fi
if [ "$T2S_ST" != "active" ]; then echo "✗ tun2socks не работает";  ERRORS=$((ERRORS+1)); fi
if [ "$WARP_IP" = "НЕ ДОСТУПЕН" ]; then echo "✗ WARP proxy недоступен"; ERRORS=$((ERRORS+1)); fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo "--- Лог awg-quick:"
    journalctl -u awg-quick@awg0 -n 15 --no-pager
    echo "--- Лог tun2socks:"
    journalctl -u tun2socks -n 15 --no-pager
    exit 1
fi

echo ""
echo "✓ Сервер готов. Запусти на клиенте:"
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
