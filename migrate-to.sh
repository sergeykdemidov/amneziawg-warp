#!/bin/bash
# Переезд на новый VPS: поднять стек → настроить локальный клиент → сохранить бэкап.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="$SCRIPT_DIR/backups"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)
SSH_PUBKEY_FILE="${MIGRATE_SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE" 2>/dev/null || true)"
if [ -z "$SSH_PUBKEY" ]; then
    SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHLrkHYmRbbhWuZDwpGp7ntGMFHcLhg0Fjc9PLy1TyZm sdemidov@ubsystem.ru"
fi

usage() {
    cat <<EOF
Использование:
  $0 [--restore DIR] [user@]HOST

  Без --restore  — свежий server-setup (новые ключи).
  --restore DIR  — DIR должен содержать awg0.conf и awg-client.env
                   (тот же бэкап, что пишет этот скрипт в backups/).

Пример:
  $0 root@150.251.153.91
  $0 --restore backups/150.251.153.91 root@НОВАЯ_IP
EOF
}

print_ssh_reminder() {
    cat <<EOF

=========================================================
 Перед переездом — на новом VPS (консоль провайдера):
=========================================================

mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '${SSH_PUBKEY}' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

=========================================================

EOF
}

RESTORE_DIR=""
TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --restore)
            RESTORE_DIR="${2:-}"
            if [ -z "$RESTORE_DIR" ]; then
                echo "ОШИБКА: --restore нужен путь к каталогу бэкапа" >&2
                exit 1
            fi
            shift 2
            ;;
        -*)
            echo "ОШИБКА: неизвестный флаг $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

print_ssh_reminder

if [ -z "$TARGET" ]; then
    usage >&2
    exit 1
fi

if [[ "$TARGET" != *@* ]]; then
    TARGET="root@$TARGET"
fi
HOST="${TARGET#*@}"

if [ -n "$RESTORE_DIR" ]; then
    if [[ "$RESTORE_DIR" != /* ]]; then
        RESTORE_DIR="$SCRIPT_DIR/$RESTORE_DIR"
    fi
    if [ ! -f "$RESTORE_DIR/awg0.conf" ] || [ ! -f "$RESTORE_DIR/awg-client.env" ]; then
        echo "ОШИБКА: в $RESTORE_DIR нужны awg0.conf и awg-client.env" >&2
        exit 1
    fi
fi

echo "Цель: $TARGET"
echo "Режим: $([ -n "$RESTORE_DIR" ] && echo "restore ($RESTORE_DIR)" || echo "fresh")"
echo ""

echo "[1/5] Ожидаем SSH..."
SSH_OK=0
for i in $(seq 1 60); do
    if ssh "${SSH_OPTS[@]}" "$TARGET" 'echo ok' &>/dev/null; then
        echo "  ✓ SSH OK (${i} попытка)"
        SSH_OK=1
        break
    fi
    sleep 2
done
if [ "$SSH_OK" -ne 1 ]; then
    echo "ОШИБКА: нет SSH на $TARGET" >&2
    echo "Проверь, что ключ добавлен (команды выше)." >&2
    exit 1
fi

echo "[2/5] Копируем скрипты..."
scp "${SSH_OPTS[@]}" \
    "$SCRIPT_DIR/server-setup.sh" \
    "$SCRIPT_DIR/server-restart.sh" \
    "$SCRIPT_DIR/server-add-client.sh" \
    "$TARGET:/root/"
ssh "${SSH_OPTS[@]}" "$TARGET" 'chmod +x /root/server-*.sh'

if [ -n "$RESTORE_DIR" ]; then
    echo "[3/5] Заливаем бэкап и поднимаем стек (restore)..."
    scp "${SSH_OPTS[@]}" \
        "$RESTORE_DIR/awg0.conf" \
        "$RESTORE_DIR/awg-client.env" \
        "$TARGET:/root/"
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        'RESTORE_CONF=/root/awg0.conf RESTORE_CLIENT_ENV=/root/awg-client.env DEBIAN_FRONTEND=noninteractive bash /root/server-setup.sh'
else
    echo "[3/5] Ставим стек с нуля (fresh)..."
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        'DEBIAN_FRONTEND=noninteractive bash /root/server-setup.sh'
fi

echo "[4/5] Забираем параметры клиента..."
TMP_ENV="$(mktemp)"
TMP_CONF="$(mktemp)"
trap 'rm -f "$TMP_ENV" "$TMP_CONF"' EXIT
scp "${SSH_OPTS[@]}" "$TARGET:/root/awg-client.env" "$TMP_ENV"
scp "${SSH_OPTS[@]}" "$TARGET:/root/awg0.conf.backup" "$TMP_CONF"

# Гарантируем IPv4 цели в env
if grep -qE '^SERVER_IP=' "$TMP_ENV"; then
    sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$HOST\"|" "$TMP_ENV"
else
    echo "SERVER_IP=\"$HOST\"" >> "$TMP_ENV"
fi

# shellcheck disable=SC1090
set -a
# shellcheck source=/dev/null
source "$TMP_ENV"
set +a

if [ -z "${CLIENT_PRIV:-}" ] || [ -z "${SERVER_PUB:-}" ] || [ -z "${AWG_PORT:-}" ]; then
    echo "ОШИБКА: в awg-client.env не хватает полей" >&2
    cat "$TMP_ENV" >&2
    exit 1
fi

echo "[5/5] Настраиваем локальный клиент..."
run_client() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_client env \
    "CLIENT_PRIV=$CLIENT_PRIV" \
    "SERVER_PUB=$SERVER_PUB" \
    "SERVER_IP=$SERVER_IP" \
    "CLIENT_IP=${CLIENT_IP:-10.8.0.2}" \
    "AWG_PORT=$AWG_PORT" \
    "AWG_JC=$AWG_JC" "AWG_JMIN=$AWG_JMIN" "AWG_JMAX=$AWG_JMAX" \
    "AWG_S1=$AWG_S1" "AWG_S2=$AWG_S2" \
    "AWG_H1=$AWG_H1" "AWG_H2=$AWG_H2" "AWG_H3=$AWG_H3" "AWG_H4=$AWG_H4" \
    bash "$SCRIPT_DIR/client-setup.sh"
run_client bash "$SCRIPT_DIR/client-down.sh" 2>/dev/null || true
run_client bash "$SCRIPT_DIR/client-up.sh"

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/${HOST}"
mkdir -p "$DEST"
cp -a "$TMP_CONF" "$DEST/awg0.conf"
cp -a "$TMP_ENV" "$DEST/awg-client.env"
chmod 600 "$DEST/awg0.conf" "$DEST/awg-client.env"
cp -a "$DEST/awg0.conf" "$BACKUP_ROOT/${HOST}.${STAMP}.awg0.conf"
cp -a "$DEST/awg-client.env" "$BACKUP_ROOT/${HOST}.${STAMP}.awg-client.env"
chmod 600 "$BACKUP_ROOT/${HOST}.${STAMP}."*

echo ""
echo "✓ Переезд завершён → $SERVER_IP:$AWG_PORT"
echo "  Бэкап: $DEST/"
echo "  Следующий restore: $0 --restore backups/$HOST root@НОВАЯ_IP"
echo ""
