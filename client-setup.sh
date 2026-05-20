#!/bin/bash
set -e

echo "========================================================="
echo " УСТАНОВКА КЛИЕНТА — AmneziaWG"
echo "========================================================="

if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: нужен root. Запускай так:" >&2
    echo "  sudo CLIENT_PRIV=\"$CLIENT_PRIV\" SERVER_PUB=\"$SERVER_PUB\" SERVER_IP=\"$SERVER_IP\" $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/awg-state.json"
AWG_TABLE=200
AWG_PRIO=50
RULES_FILE=/run/awg0-routes.list

if [ -n "$CLIENT_PRIV" ] && [ -n "$SERVER_PUB" ] && [ -n "$SERVER_IP" ]; then
    echo "  Ключи получены из переменных окружения"
elif [ -f "$STATE_FILE" ]; then
    echo "  Ключи берём из кэша ($STATE_FILE)"
    CLIENT_PRIV=$(jq -r '.client_priv' "$STATE_FILE")
    SERVER_PUB=$(jq -r '.server_pub'  "$STATE_FILE")
    SERVER_IP=$(jq -r '.server_ip'   "$STATE_FILE")
else
    echo "ОШИБКА: ключи не заданы и кэш не найден. Запускай командой от сервера." >&2
    exit 1
fi

source "$SCRIPT_DIR/config.sh"

# ── 1. Установка ─────────────────────────────────────────────
echo "[1/3] Проверка и установка пакетов..."

need_apt_update=false

check_pkg() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null; then
        echo "  ✓ $pkg уже установлен"
    else
        echo "  ✗ $pkg — нужна установка"
        need_apt_update=true
    fi
}

check_cmd() {
    local cmd="$1" pkg="$2"
    if command -v "$cmd" &>/dev/null; then
        echo "  ✓ $cmd уже установлен"
    else
        echo "  ✗ $pkg — нужна установка"
        need_apt_update=true
    fi
}

check_cmd awg-quick amneziawg
check_pkg curl
check_pkg iproute2
check_pkg iputils-ping
check_pkg dnsutils
check_pkg jq

if $need_apt_update; then
    apt update
    apt install -y software-properties-common
    if ! command -v awg-quick &>/dev/null; then
        add-apt-repository ppa:amnezia/ppa -y
    fi
    apt install -y amneziawg curl iproute2 iputils-ping dnsutils jq
else
    echo "  Все пакеты уже установлены, пропускаем apt"
fi

# ── 2. Резолвинг маршрутов ────────────────────────────────────
echo "[2/3] Резолвинг маршрутов..."

DEFAULT_GW=$(ip route | awk '/^default/{print $3; exit}')
DEFAULT_IF=$(ip route | awk '/^default/{print $5; exit}')
echo "  Шлюз   : $DEFAULT_GW ($DEFAULT_IF)"
echo "  Сервер : $SERVER_IP"

ROUTES=()

for site in "${SITES[@]}"; do
    mapfile -t ips < <(dig +short "$site" 2>/dev/null | grep -E '^[0-9.]+$')
    for ip in "${ips[@]}"; do
        ROUTES+=("$ip/32")
    done
    [ ${#ips[@]} -gt 0 ] && echo "  $site → ${ips[*]}" || echo "  $site → (не резолвится)"
done

for subnet in "${SUBNETS[@]}"; do
    ROUTES+=("$subnet")
done

echo "  Загружаем диапазоны Google (YouTube)..."
mapfile -t google < <(curl -s --max-time 15 "https://www.gstatic.com/ipranges/goog.txt" | grep -E '^[0-9.]+\/')
ROUTES+=("${google[@]}")

echo "  Итого маршрутов: ${#ROUTES[@]}"

# ── 3. Запись state ───────────────────────────────────────────
echo "[3/3] Сохранение конфигурации..."

if [ ${#ROUTES[@]} -gt 0 ]; then
    ROUTES_JSON=$(printf '%s\n' "${ROUTES[@]}" | jq -R . | jq -s .)
else
    ROUTES_JSON='[]'
fi

jq -n \
    --arg      server_ip   "$SERVER_IP"   \
    --arg      server_pub  "$SERVER_PUB"  \
    --arg      client_priv "$CLIENT_PRIV" \
    --arg      gateway     "$DEFAULT_GW"  \
    --arg      iface       "$DEFAULT_IF"  \
    --argjson  awg_table   "$AWG_TABLE"   \
    --argjson  awg_prio    "$AWG_PRIO"    \
    --arg      rules_file  "$RULES_FILE"  \
    --argjson  routes      "$ROUTES_JSON" \
    '{
        server_ip:   $server_ip,
        server_pub:  $server_pub,
        client_priv: $client_priv,
        gateway:     $gateway,
        iface:       $iface,
        awg_table:   $awg_table,
        awg_prio:    $awg_prio,
        rules_file:  $rules_file,
        routes:      $routes
    }' > "$STATE_FILE"

chmod 600 "$STATE_FILE"
[ -n "$SUDO_USER" ] && chown "$SUDO_USER:$SUDO_USER" "$STATE_FILE"
echo "  Сохранено: $STATE_FILE"

# ── Диагностика ───────────────────────────────────────────────
echo ""
echo "========================================================="
echo " ГОТОВО"
echo "========================================================="
echo "  Маршрутов в state : ${#ROUTES[@]}"
echo "  Шлюз              : $DEFAULT_GW ($DEFAULT_IF)"
echo "  Сервер            : $SERVER_IP"
echo ""
echo "  Запусти туннель:"
echo "    sudo $SCRIPT_DIR/client-up.sh"
echo "========================================================="
echo ""
