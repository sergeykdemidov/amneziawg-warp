# TODO

## Заменить WARP-proxy (warp-cli + tun2socks) на нативный WireGuard-туннель (wgcf)

Цель: выход с сервера в Cloudflare сделать настоящим WireGuard-туннелем `warp0`,
а не связкой `warp-cli` (SOCKS proxy :40001) + `tun2socks`. Клиентская часть
(`client-up.sh`, AWG) не меняется.

### Что уходит из стека
- `tun2socks` (бинарник, `tun2socks.service`, userspace-обработка).
- `warp-cli` proxy-режим + порт `:40001`.
- SOCKS5-прослойка.

### Что появляется
Интерфейс `warp0` под `wg-quick` (kernel-space), `table 100` роутится в него.

### Шаги

1. **Сервер: установка wgcf вместо tun2socks/warp-cli proxy**
   ```bash
   apt install -y wireguard-tools
   wget -O /usr/local/bin/wgcf \
     https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_linux_amd64
   chmod +x /usr/local/bin/wgcf
   wgcf register --accept-tos    # → wgcf-account.toml (chmod 600)
   wgcf generate                 # → wgcf-profile.conf
   ```

2. **/etc/wireguard/warp0.conf** (из wgcf-profile, DNS и ::/0 убрать):
   ```ini
   [Interface]
   PrivateKey = <из профиля>
   Address = 172.16.0.2/32        # v4 из профиля
   MTU = 1280
   Table = off                    # не трогаем main, как сейчас

   [Peer]
   PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=   # Cloudflare
   AllowedIPs = 0.0.0.0/0
   Endpoint = engage.cloudflareclient.com:2408
   PersistentKeepalive = 25
   ```
   Запуск: `systemctl enable --now wg-quick@warp0`

3. **Поправить NAT в awg0.conf (важно!)**
   Сейчас маскарад идёт `-o $EXT_IF`. С нативным warp0 пакеты из 10.8.0.0/24
   уходят в warp0 с приватным source → Cloudflare не вернёт ответ.
   Маскарадить нужно на warp0:
   ```
   iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o warp0 -j MASQUERADE
   ```

4. **MSS-clamping вместо подбора MTU** (двойная инкапсуляция AWG→WARP режет MTU):
   ```
   iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o warp0 -j TCPMSS --clamp-mss-to-pmtu
   ```

5. **Healthcheck упрощается:**
   `wg show warp0 latest-handshakes` вместо `warp-cli status` + `nc -z :40001`.

### Файлы под правку
- `server-setup.sh` — заменить установку/WARP/tun2socks на wgcf + wg-quick@warp0,
  поправить NAT и добавить MSS-clamp.
- `server-restart.sh` — новый стек (wg-quick@warp0 вместо warp-cli/tun2socks).
- `server-add-client.sh` — без существенных изменений (проверить).
- Клиентские скрипты — не трогаем.

### Плюсы
- Чистый kernel-WireGuard: быстрее/стабильнее userspace tun2socks.
- На два демона меньше (`warp-svc`, `tun2socks`), без SOCKS.
- Стандартный жизненный цикл `wg-quick@warp0`.
- Не зависит от проприетарного `warp-cli`.

### Минусы / на что смотреть
- `wgcf` — сторонняя утилита (публичный WARP API).
- Бесплатный WARP может троттлиться/банить по нагрузке (свойство WARP).
- `wgcf-account.toml` хранит ключи аккаунта — нужен `chmod 600`.

---

## Прочие идеи (из разбора надёжности, на потом)

- **MTU/MSS на клиенте** — самый дешёвый прирост стабильности.
- **Динамическое наполнение IP-сетов через DNS** (dnsmasq + nftset): убирает
  проблему протухания списка IP и рассинхрона DNS, O(1) вместо линейных `ip rule`.
- **Валидация AWG-параметров** в server-setup: уникальность H1-H4, ограничение S1+56≠S2.
- **systemd timer** авто-обновления маршрутов на клиенте.
- **Healthcheck-watchdog WARP** на сервере.
- **DDNS-имя в Endpoint** клиента — на случай смены IP сервера.
