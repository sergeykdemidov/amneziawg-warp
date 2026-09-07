# AmneziaWG + WARP

Обходной туннель: трафик выбранных сайтов идёт через AmneziaWG на сервер, а с сервера — через Cloudflare WARP. Остальной трафик (корпоративный VPN, обычный интернет) не затрагивается.

---

## Структура проекта

| Файл | Назначение |
|---|---|
| `migrate-to.sh` | Переезд на новый VPS с этой машины (рекомендуемый путь) |
| `server-setup.sh` | Установка стека на сервере (PPA Amnezia, AWG, WARP, tun2socks) |
| `server-add-client.sh` | Добавить нового клиента на сервере |
| `server-restart.sh` | Перезапустить стек на сервере |
| `client-setup.sh` | Настройка клиента: резолвит IP, сохраняет кэш |
| `client-up.sh` | Поднять туннель |
| `client-down.sh` | Опустить туннель |
| `client-route-config.conf` | Список сайтов и подсетей для туннелирования |
| `awg-state.json` | Локальный кэш: ключи + параметры + маршруты _(не в git)_ |
| `backups/<IP>/` | Бэкап `awg0.conf` + `awg-client.env` после migrate _(не в git)_ |

На сервере после setup также лежат `/root/awg-client.env` и `/root/awg0.conf.backup`.

---

## Переезд на новый VPS (рекомендуется)

1. Купи/подними VPS, в консоли провайдера добавь SSH-ключ.  
   `migrate-to.sh` в начале печатает готовые команды `mkdir` / `authorized_keys`.
2. С машины клиента:

```bash
# С нуля — новые ключи
./migrate-to.sh root@НОВАЯ_IP

# Или восстановить ту же «личность» AWG из бэкапа
./migrate-to.sh --restore backups/СТАРАЯ_IP root@НОВАЯ_IP
```

Скрипт: дождётся SSH → поставит стек на VPS → обновит локальный `awg-state.json` → поднимет туннель → сохранит бэкап в `backups/<IP>/`.

---

## Первый запуск вручную (без migrate)

### 1. Сервер

```bash
sudo bash server-setup.sh
```

Подключит PPA Amnezia при необходимости, поднимет WARP (proxy) + tun2socks + AWG.  
В конце — команда для клиента и файлы `/root/awg-client.env`, `/root/awg0.conf.backup`.  
IP берётся через `curl -4` (IPv4).

### 2. Клиент

В папке проекта — команда с сервера (или `source` из `awg-client.env`):

```bash
sudo CLIENT_PRIV="..." SERVER_PUB="..." SERVER_IP="..." CLIENT_IP="..." \
     AWG_PORT="..." AWG_JC="..." AWG_JMIN="..." AWG_JMAX="..." \
     AWG_S1="..." AWG_S2="..." \
     AWG_H1="..." AWG_H2="..." AWG_H3="..." AWG_H4="..." \
     bash client-setup.sh
```

Скрипт:
- поставит пакеты при необходимости (`amneziawg` из PPA, `jq`, `dnsutils`, …)
- резолвит домены из `client-route-config.conf`
- подгрузит диапазоны Google (`goog.txt`) и AWS CloudFront
- добавит DNS `1.1.1.1` / `8.8.8.8` в маршруты
- сохранит всё в `awg-state.json`

### 3. Туннель

```bash
sudo ./client-up.sh
```

---

## Добавить второго и последующих клиентов

На сервере:

```bash
sudo bash server-add-client.sh
```

Назначит следующий IP (`10.8.0.3`, …), добавит пир без перезапуска AWG, обновит `/root/awg-client.env` и выведет команду для нового клиента. Далее — `client-setup` + `client-up` на той машине.

---

## Повседневное использование

```bash
sudo ./client-up.sh              # split-туннель (сайты из конфига)
sudo FULL_TUNNEL=1 ./client-up.sh  # весь трафик через awg0 (Deezer и т.п.)
sudo ./client-down.sh
```

`FULL_TUNNEL=1` оставляет LAN и underlay NetBird на реальном WAN (по fwmark).

---

## Добавить сайт или подсеть

В `client-route-config.conf`:

```
SITES=(
    rutracker.org
    new-site.com
)

SUBNETS=(
    1.2.3.0/24
)
```

Затем:

```bash
sudo ./client-setup.sh    # ключи берёт из awg-state.json
sudo ./client-down.sh
sudo ./client-up.sh
```

---

## Перезапуск сервера

```bash
sudo bash server-restart.sh
```

Останавливает AWG и tun2socks, проверяет/переподключает WARP, поднимает стек по порядку.

---

## Как это работает

```
Браузер → [ip rule pref 50] → таблица 200 → awg0 → сервер → WARP (SOCKS) → tun2socks/warp0 → интернет
Netbird/корпоративный VPN → (ip rule не совпал) → как обычно
Остальной трафик → default gateway → как обычно
```

- `Table = off` в AWG — awg-quick не трогает маршруты
- `client-up.sh` создаёт таблицу `200` с `default dev awg0`
- Для каждого IP/подсети из кэша: `ip rule to <CIDR> lookup 200 pref 50`
- DNS `1.1.1.1` / `8.8.8.8` тоже через туннель
- IPv6 отключается на время поднятого туннеля
- Параметры обфускации AWG (H1–H4, S1/S2, порт) случайны при fresh-установке сервера

---

## Диагностика

```bash
# Статус туннеля (нужен root)
sudo awg show awg0

# Сколько правил активно
wc -l /run/awg0-routes.list

# Маршрутизация конкретного IP
ip rule show | grep 'pref 50' | head -5
ip route get 104.21.32.39

# Логи на сервере
journalctl -u awg-quick@awg0 -n 30
journalctl -u tun2socks -n 30
warp-cli --accept-tos status
```
