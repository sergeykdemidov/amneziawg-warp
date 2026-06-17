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
    CLIENT_IP="${CLIENT_IP:-10.8.0.2}"
elif [ -f "$STATE_FILE" ]; then
    echo "  Ключи берём из кэша ($STATE_FILE)"
    CLIENT_PRIV=$(jq -r '.client_priv' "$STATE_FILE")
    SERVER_PUB=$(jq -r '.server_pub'  "$STATE_FILE")
    SERVER_IP=$(jq -r '.server_ip'   "$STATE_FILE")
    CLIENT_IP=$(jq -r '.client_ip // "10.8.0.2"' "$STATE_FILE")
else
    echo "ОШИБКА: ключи не заданы и кэш не найден. Запускай командой от сервера." >&2
    exit 1
fi

if [ -n "$AWG_PORT" ]; then
    echo "  AWG-параметры получены из переменных окружения"
elif [ -f "$STATE_FILE" ] && [ "$(jq -r '.awg_port // empty' "$STATE_FILE")" != "" ]; then
    echo "  AWG-параметры берём из кэша ($STATE_FILE)"
    AWG_PORT=$(jq -r '.awg_port'  "$STATE_FILE")
    AWG_JC=$(jq -r '.awg_jc'    "$STATE_FILE")
    AWG_JMIN=$(jq -r '.awg_jmin'  "$STATE_FILE")
    AWG_JMAX=$(jq -r '.awg_jmax'  "$STATE_FILE")
    AWG_S1=$(jq -r '.awg_s1'    "$STATE_FILE")
    AWG_S2=$(jq -r '.awg_s2'    "$STATE_FILE")
    AWG_H1=$(jq -r '.awg_h1'    "$STATE_FILE")
    AWG_H2=$(jq -r '.awg_h2'    "$STATE_FILE")
    AWG_H3=$(jq -r '.awg_h3'    "$STATE_FILE")
    AWG_H4=$(jq -r '.awg_h4'    "$STATE_FILE")
else
    echo "ОШИБКА: AWG-параметры не заданы. Используй команду от сервера." >&2
    exit 1
fi

source "$SCRIPT_DIR/client-route-config.conf"

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

ROUTES+=("1.1.1.1/32")
ROUTES+=("8.8.8.8/32")

echo "  Загружаем диапазоны Google (YouTube)..."
mapfile -t google < <(curl -s --max-time 15 "https://www.gstatic.com/ipranges/goog.txt" | grep -E '^[0-9.]+\/')
ROUTES+=("${google[@]}")

echo "  Загружаем диапазоны AWS CloudFront (JetBrains Marketplace, Zencoder)..."
mapfile -t cloudfront < <(curl -s --max-time 20 "https://ip-ranges.amazonaws.com/ip-ranges.json" | jq -r '.prefixes[] | select(.service=="CLOUDFRONT") | .ip_prefix')
ROUTES+=("${cloudfront[@]}")

echo "  Итого маршрутов: ${#ROUTES[@]}"

# ── 3. Запись state ───────────────────────────────────────────
echo "[3/3] Сохранение конфигурации..."

ROUTES_FILE=$(mktemp)
trap 'rm -f "$ROUTES_FILE"' EXIT
if [ ${#ROUTES[@]} -gt 0 ]; then
    printf '%s\n' "${ROUTES[@]}" | jq -R . | jq -s . > "$ROUTES_FILE"
else
    echo '[]' > "$ROUTES_FILE"
fi

jq -n \
    --arg      server_ip   "$SERVER_IP"   \
    --arg      server_pub  "$SERVER_PUB"  \
    --arg      client_priv "$CLIENT_PRIV" \
    --arg      client_ip   "$CLIENT_IP"   \
    --arg      gateway     "$DEFAULT_GW"  \
    --arg      iface       "$DEFAULT_IF"  \
    --argjson  awg_table   "$AWG_TABLE"   \
    --argjson  awg_prio    "$AWG_PRIO"    \
    --arg      rules_file  "$RULES_FILE"  \
    --argjson  awg_port    "$AWG_PORT"    \
    --argjson  awg_jc      "$AWG_JC"      \
    --argjson  awg_jmin    "$AWG_JMIN"    \
    --argjson  awg_jmax    "$AWG_JMAX"    \
    --argjson  awg_s1      "$AWG_S1"      \
    --argjson  awg_s2      "$AWG_S2"      \
    --argjson  awg_h1      "$AWG_H1"      \
    --argjson  awg_h2      "$AWG_H2"      \
    --argjson  awg_h3      "$AWG_H3"      \
    --argjson  awg_h4      "$AWG_H4"      \
    --slurpfile routes_wrap "$ROUTES_FILE" \
    '{
        server_ip:   $server_ip,
        server_pub:  $server_pub,
        client_priv: $client_priv,
        client_ip:   $client_ip,
        gateway:     $gateway,
        iface:       $iface,
        awg_table:   $awg_table,
        awg_prio:    $awg_prio,
        rules_file:  $rules_file,
        awg_port:    $awg_port,
        awg_jc:      $awg_jc,
        awg_jmin:    $awg_jmin,
        awg_jmax:    $awg_jmax,
        awg_s1:      $awg_s1,
        awg_s2:      $awg_s2,
        awg_h1:      $awg_h1,
        awg_h2:      $awg_h2,
        awg_h3:      $awg_h3,
        awg_h4:      $awg_h4,
        routes:      $routes_wrap[0]
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
