# Варианты обхода блокировок (variations)

Шесть разных способов туннеля. Идея: у ТСПУ разные методы блокировки для разных
семейств протоколов, поэтому ставим **все сразу**, а клиент сам перебирает и оставляет
первый рабочий.

> Честно: гарантировать, что «хотя бы один точно не заблокирован», нельзя. Если
> заблокирован **IP вашего VPS целиком**, не поможет ни один вариант — тогда нужен другой
> VPS/хостер (см. «Если не работает ничего»). Зато при блокировке по протоколу/SNI/порту
> почти всегда проходит хотя бы один из шести.

| # | Вариант | Транспорт | Порт по умолчанию | Нужен домен | Движок |
|---|---------|-----------|-------------------|-------------|--------|
| V1 | VLESS + REALITY + Vision | TCP | 443/tcp | нет | Xray |
| V2 | VLESS + REALITY + XHTTP | TCP (HTTP-стиль) | 8443/tcp | нет | Xray |
| V3 | VLESS + REALITY + gRPC | TCP (HTTP/2) | 2053/tcp | нет | Xray |
| V4 | VLESS + WebSocket + TLS (настоящий сертификат, можно за Cloudflare) | TCP | 2083/tcp (+80 для сертификата) | **да** | Xray + Caddy |
| V5 | Hysteria2 + obfs salamander | QUIC/UDP | 443/udp | нет | sing-box |
| V6 | SSH `-D` (запасной) | TCP | 22/tcp | нет | OpenSSH |

## Порядок действий

### 1. Сервер (Linux VPS **за пределами РФ**, root)

```bash
git clone -b claude/gifted-dirac-8h8ymf https://github.com/bbijijj80-gif/ryryi.git
cd ryryi/variations/server
sudo ./install-all.sh                 # V1, V2, V3, V5, V6
# если есть домен с A-записью на этот сервер (и свободен TCP 80), добавьте V4:
sudo ./install-all.sh vpn.example.com
```

Результат — файл `/root/myvpn-links.txt`: одна ссылка на строку (`#v1-reality-tcp`,
`#v2-...` и т. д.). Каждый вариант работает как отдельный сервис `myvpn-vN`, на своём порту,
они друг другу не мешают. Открывать порты в фаерволе скрипты пытаются сами
(`ufw`/`firewalld`); у облачных провайдеров правила в панели откройте вручную:
**443/tcp, 8443/tcp, 2053/tcp, 443/udp, 22/tcp** (и **80/tcp, 2083/tcp** для V4).

Ставить можно и по одному:

```bash
sudo ./v1-reality-tcp.sh [порт] [sni]          # sni — любой сайт с TLS 1.3 + h2
sudo ./v2-reality-xhttp.sh [порт] [sni]
sudo ./v3-reality-grpc.sh [порт] [sni]
sudo ./v4-ws-tls-caddy.sh <домен> [порт]
sudo ./v5-hysteria2.sh [udp-порт] [sni]
sudo ./v6-ssh.sh [ssh-порт]
```

Забрать ссылки на Windows (PowerShell):

```powershell
scp root@IP_СЕРВЕРА:/root/myvpn-links.txt $HOME\links.txt
scp root@IP_СЕРВЕРА:/etc/myvpn/v6/key $HOME\myvpn_key     # только для V6
```

Либо просто откройте `cat /root/myvpn-links.txt` на сервере и скопируйте в файл.

### 2. Клиент (Windows 10/11, PowerShell)

Скачайте папку `variations\client` (или весь репозиторий:
`git clone -b claude/gifted-dirac-8h8ymf https://github.com/bbijijj80-gif/ryryi.git`).
Если запуск скриптов запрещён: `Set-ExecutionPolicy -Scope Process Bypass`.

```powershell
cd ryryi\variations\client

# автоперебор: пробует V1 → V2 → ... по порядку в файле, проверяет, что внешний IP
# изменился, и оставляет первый рабочий
.\myvpn.ps1 -LinksFile $HOME\links.txt -SystemProxy

# проверить текущий туннель
.\myvpn.ps1 -Test

# выключить всё и снять системный прокси
.\myvpn.ps1 -Stop
```

Запустить один конкретный вариант вручную:

```powershell
.\myvpn.ps1 -Link "vless://...#v2-reality-xhttp" -SystemProxy
.\myvpn.ps1 -Link "hy2blob://...#v5-hysteria2"
.\myvpn.ps1 -Link "ssh://tun@IP:22#v6-ssh" -SshKey $HOME\myvpn_key
```

Локальные порты: SOCKS5 `127.0.0.1:10808`, HTTP `127.0.0.1:10809`. Без `-SystemProxy`
укажите их вручную в браузере/приложении.
Скрипт сам скачивает Xray и sing-box с GitHub. Если GitHub с вашего компьютера
недоступен, положите распакованные `xray.exe` в `%LOCALAPPDATA%\myvpn\xray\` и
`sing-box.exe` в `%LOCALAPPDATA%\myvpn\sing-box\` заранее.
Антивирус может ругаться на `xray.exe`/`sing-box.exe` — это ложное срабатывание
для всех подобных утилит, добавьте папку в исключения.

### 3. Рекомендуемый порядок проб, если пробовать вручную

1. **V1** (REALITY/TCP/443) — самый распространённый, пробуйте первым.
2. **V2** (REALITY/XHTTP) — если V1 режут по профилю TCP-трафика.
3. **V3** (REALITY/gRPC).
4. **V5** (Hysteria2, UDP) — если TCP душат, а QUIC пока нет (в РФ QUIC тоже
   иногда режут, поэтому не первым).
5. **V4** (WS+TLS на вашем домене, лучше с Cloudflare-«облаком») — самый стойкий к
   блокировке по IP, но требует домен.
6. **V6** (SSH) — последний запасной.

## Если не работает ничего

Диагностика с клиента (PowerShell):

```powershell
Test-NetConnection IP_СЕРВЕРА -Port 443     # TcpTestSucceeded=False на всех портах и ping не идёт → IP заблокирован
```

- **Заблокирован весь IP** (не проходит ни один порт): возьмите другой VPS — другой хостер,
  другая подсеть, лучше страна/ASN с хорошей связностью (Финляндия, Германия, Нидерланды,
  Казахстан и т. п.). Поставьте `install-all.sh` заново и получите новые ссылки.
- **Проходят порты, но нет трафика**: поменяйте `sni` у V1–V3 на другой сайт (чем ближе
  к вашему VPS по ASN/географии, тем лучше), проверьте `xray tls ping <сайт>`.
- **V4**: смотрите `journalctl -u myvpn-v4-caddy` (сертификат выпускается через TCP 80).
- Логи остальных: `journalctl -u myvpn-v1 -n 50` и т. д.
- Сделайте `sudo apt update && sudo apt upgrade`, перезапустите сервисы:
  `sudo systemctl restart myvpn-v1 myvpn-v2 myvpn-v3 myvpn-v5`.
- Держите несколько VPS у разных провайдеров: это единственная настоящая защита от
  блокировки по IP.

## Что проверено

Серверные конфиги V1, V2, V3, V4 (Xray-часть), V5 прошли `xray run -test` /
`sing-box check`; клиентские конфиги всех вариантов построены клиентом и прошли те же
проверки; V5 дополнительно проверен сквозным тестом (клиент ↔ сервер, obfs +
проверка вшитого сертификата). Работу против реальных блокировок в РФ из этой среды
проверить нельзя — это нужно сделать вам с вашей сети.
