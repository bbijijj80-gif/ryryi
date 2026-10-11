#!/usr/bin/env bash
# V4: VLESS + WebSocket + настоящий TLS-сертификат вашего домена (Caddy). Выглядит как обычный сайт.
# Требуется домен, A-запись которого указывает на этот сервер, и свободный TCP 80 (выпуск сертификата).
# Можно включить «оранжевое облако» Cloudflare — тогда блокировка IP сервера не страшна (порты 2053/2083/2087/2096/8443).
# sudo ./v4-ws-tls-caddy.sh <домен> [порт=2083]
source "$(dirname "$0")/lib.sh"; need_root
DOMAIN="${1:-}"; PORT="${2:-2083}"
[ -n "$DOMAIN" ] || { echo "Использование: $0 <домен> [порт=2083]"; exit 1; }
port_busy "$PORT" tcp && { echo "TCP-порт $PORT занят, укажите другой."; exit 1; }
port_busy 80 tcp && { echo "TCP 80 занят (нужен Caddy для сертификата). Освободите его."; exit 1; }
install_xray; pkg curl
CADDY=/usr/local/bin/caddy
[ -x "$CADDY" ] || { curl -fsSL -o "$CADDY" "https://caddyserver.com/api/download?os=linux&arch=$(arch)" && chmod +x "$CADDY"; }
UUID=$("$XRAY_BIN" uuid); WSPATH="/$(rand_hex 5)"; LOCAL=$((20000 + RANDOM % 20000))
mkdir -p /var/www/myvpn-decoy
cat > /var/www/myvpn-decoy/index.html <<'HTML'
<!doctype html><meta charset=utf-8><title>Welcome</title><h1>It works</h1><p>Personal site.</p>
HTML
cat > "$BASE/v4.json" <<JSON
{ "log": {"loglevel":"warning"},
  "inbounds": [{ "listen":"127.0.0.1", "port": $LOCAL, "protocol":"vless",
    "settings": { "clients": [{"id":"$UUID"}], "decryption":"none" },
    "streamSettings": { "network":"ws", "wsSettings": {"path":"$WSPATH"} } }],
  "outbounds": [{"protocol":"freedom"}] }
JSON
"$XRAY_BIN" run -test -c "$BASE/v4.json" >/dev/null
cat > "$BASE/Caddyfile" <<CADDY
{
  storage file_system /var/lib/myvpn-caddy
}
$DOMAIN:$PORT {
  @ws path $WSPATH
  reverse_proxy @ws 127.0.0.1:$LOCAL
  root * /var/www/myvpn-decoy
  file_server
}
CADDY
"$CADDY" validate --config "$BASE/Caddyfile" --adapter caddyfile >/dev/null 2>&1
make_service v4-xray "$XRAY_BIN" run -c "$BASE/v4.json"
make_service v4-caddy "$CADDY" run --config "$BASE/Caddyfile" --adapter caddyfile
open_port 80 tcp; open_port "$PORT" tcp
echo "Caddy выпускает сертификат (до минуты). Если клиент не подключается — смотрите: journalctl -u myvpn-v4-caddy"
emit_link "vless://$UUID@$DOMAIN:$PORT?encryption=none&security=tls&sni=$DOMAIN&fp=chrome&alpn=http%2F1.1&type=ws&host=$DOMAIN&path=%2F${WSPATH#/}#v4-ws-tls"
