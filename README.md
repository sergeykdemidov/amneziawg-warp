# AmneziaWG + WARP

Обходной туннель: трафик выбранных сайтов идёт через AmneziaWG на сервер, а с сервера — через Cloudflare WARP. Остальной трафик (корпоративный VPN, обычный интернет) не затрагивается.

---

## Структура проекта

| Файл | Назначение |
|---|---|
| `server.sh` | Установка и настройка сервера (один раз) |
| `config.sh` | Список сайтов и подсетей для туннелирования |
| `client-setup.sh` | Установка клиента: резолвит IP, сохраняет кэш |
| `client-up.sh` | Поднять туннель |
| `client-down.sh` | Опустить туннель |
| `awg-state.json` | Локальный кэш: ключи + все маршруты _(не в git)_ |

---

## Первый запуск (с нуля)

### 1. Настроить сервер

На сервере:
```bash
sudo bash server.sh
```

В конце скрипт выведет команду — скопируй её целиком.

### 2. Настроить клиент

На клиентской машине, в папке проекта — вставь скопированную команду:
```bash
sudo CLIENT_PRIV="<ключ>" SERVER_PUB="<ключ>" SERVER_IP="<IP>" bash client-setup.sh
```

Скрипт:
- установит недостающие пакеты (`amneziawg`, `jq`, `dnsutils`)
- резолвит все домены из `config.sh` в IP-адреса
- загрузит диапазоны Google (YouTube)
- сохранит всё в `awg-state.json`

### 3. Поднять туннель

```bash
sudo ./client-up.sh
```

---

## Повседневное использование

```bash
sudo ./client-up.sh     # включить туннель
sudo ./client-down.sh   # выключить туннель
```

---

## Добавить сайт или подсеть

Открой `config.sh` и добавь в нужный массив:

```bash
SITES=(
    "rutracker.org"
    "new-site.com"      # ← добавил
    ...
)

SUBNETS=(
    "52.85.49.0/24"
    "1.2.3.0/24"        # ← добавил
    ...
)
```

Затем пересоздай кэш и перезапусти туннель:

```bash
sudo ./client-setup.sh          # ключи берёт из кэша автоматически
sudo ./client-down.sh
sudo ./client-up.sh
```

---

## Если сменился сервер

Запусти `server.sh` на новом сервере, скопируй команду и выполни её — ключи и IP обновятся:

```bash
sudo CLIENT_PRIV="<новый>" SERVER_PUB="<новый>" SERVER_IP="<новый>" bash client-setup.sh
sudo ./client-down.sh && sudo ./client-up.sh
```

---

## Как это работает

```
Браузер → [ip rule pref 50] → таблица 200 → awg0 → сервер → WARP → интернет
Netbird/корпоративный VPN → (ip rule не совпал) → работает как обычно
Остальной трафик → default gateway → как обычно
```

- `Table = off` в конфиге WireGuard — awg-quick не трогает маршруты
- `client-up.sh` создаёт таблицу `200` с `default dev awg0`
- Для каждого IP из кэша добавляется `ip rule to <IP> lookup 200 pref 50`
- Только совпадающий трафик идёт через туннель

---

## Диагностика

```bash
# Статус туннеля
awg show awg0

# Сколько правил активно
wc -l /run/awg0-routes.list

# Маршрутизация конкретного IP
ip rule show | grep pref 50 | head -5
ip route get 104.21.32.39   # пример: rutracker.org

# Логи awg-quick
journalctl -u awg-quick@awg0 -n 30
```
