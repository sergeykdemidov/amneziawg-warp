#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: нужен root. Запускай: sudo $0" >&2
    exit 1
fi

echo "========================================================="
echo " ПЕРЕЗАПУСК СЕРВЕРА — AmneziaWG + WARP"
echo "========================================================="

# ── 1. Стоп ──────────────────────────────────────────────────
echo "[1/4] Остановка сервисов..."
systemctl stop awg-quick@awg0 2>/dev/null || true
systemctl stop tun2socks      2>/dev/null || true
ip route flush table 100      2>/dev/null || true
ip rule del from 10.8.0.0/24 table 100 pref 100 2>/dev/null || true
ip rule del to   10.8.0.0/24 table main pref  99 2>/dev/null || true
ip rule del fwmark 53 table main pref 95        2>/dev/null || true
echo "  ✓ остановлено"

# ── 2. WARP ──────────────────────────────────────────────────
echo "[2/4] Проверка WARP..."
WARP_OK=0
for i in $(seq 1 5); do
    if warp-cli status 2>/dev/null | grep -qi "connected"; then
        WARP_OK=1
        break
    fi
    sleep 1
done

if [ "$WARP_OK" -eq 0 ]; then
    echo "  WARP не подключён — переподключаем..."
    warp-cli --accept-tos connect
    for i in $(seq 1 30); do
        if warp-cli status 2>/dev/null | grep -qi "connected"; then
            echo "  ✓ WARP подключён (${i} сек)"
            WARP_OK=1
            break
        fi
        if [ "$i" -eq 30 ]; then
            echo "  ✗ WARP не подключился, пробуем рестарт сервиса..."
            systemctl restart warp-svc
            sleep 5
            warp-cli --accept-tos connect
            sleep 10
            if warp-cli status 2>/dev/null | grep -qi "connected"; then
                echo "  ✓ WARP подключён после рестарта сервиса"
                WARP_OK=1
            else
                echo "  ✗ WARP недоступен!"
                warp-cli status
                exit 1
            fi
        fi
        sleep 1
    done
else
    echo "  ✓ WARP уже подключён"
fi

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

# ── 3. tun2socks ─────────────────────────────────────────────
echo "[3/4] Запуск tun2socks..."
systemctl start tun2socks

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

ip route add default dev warp0 table 100 2>/dev/null || true

# ── 4. AWG ───────────────────────────────────────────────────
echo "[4/4] Запуск AmneziaWG..."
systemctl start awg-quick@awg0

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
ip rule add fwmark 53 table main pref 95        2>/dev/null || true
ip rule add from 10.8.0.0/24 table 100 pref 100 2>/dev/null || true
ip rule add to   10.8.0.0/24 table main pref  99 2>/dev/null || true

# ── Итог ─────────────────────────────────────────────────────
echo ""
echo "========================================================="
echo " СТАТУС"
echo "========================================================="
AWG_ST=$(systemctl is-active awg-quick@awg0 || true)
T2S_ST=$(systemctl is-active tun2socks      || true)
WARP_ST=$(warp-cli status 2>/dev/null | head -1 || true)
WARP0_ST=$(ip link show warp0 2>/dev/null | grep -o "state [A-Z]*" || echo "не найден")
printf "%-26s %s\n" "awg-quick@awg0:"  "$AWG_ST"
printf "%-26s %s\n" "tun2socks:"        "$T2S_ST"
printf "%-26s %s\n" "WARP статус:"      "$WARP_ST"
printf "%-26s %s\n" "warp0:"            "$WARP0_ST"
echo "---------------------------------------------------------"
echo " table 100:"
ip route show table 100 2>/dev/null || echo "  пусто"
echo " ip rules (наши):"
ip rule show | grep -E "pref (95|99|100)" || echo "  нет"
echo "========================================================="

ERRORS=0
[ "$AWG_ST" != "active" ] && echo "✗ awg-quick не работает"  && ERRORS=$((ERRORS+1))
[ "$T2S_ST" != "active" ] && echo "✗ tun2socks не работает"  && ERRORS=$((ERRORS+1))

if [ "$ERRORS" -gt 0 ]; then
    exit 1
fi

echo ""
echo "✓ Сервер работает"
