#!/usr/bin/env bash
# V1: VLESS + REALITY + XTLS-Vision, TCP. Базовый вариант (имитация TLS 1.3 к чужому сайту).
# sudo ./v1-reality-tcp.sh [порт=443] [sni=www.microsoft.com]
source "$(dirname "$0")/lib.sh"; need_root
PORT="${1:-443}"; SNI="${2:-www.microsoft.com}"
port_busy "$PORT" tcp && { echo "TCP-порт $PORT занят, укажите другой."; exit 1; }
install_xray; reality_keys
UUID=$("$XRAY_BIN" uuid); SID=$(rand_hex 8)
cat > "$BASE/v1.json" <<JSON
{ "log": {"loglevel":"warning"},
  "inbounds": [{ "port": $PORT, "protocol": "vless",
    "settings": { "clients": [{"id":"$UUID","flow":"xtls-rprx-vision"}], "decryption":"none" },
    "streamSettings": { "network":"tcp", "security":"reality",
      "realitySettings": { "dest":"$SNI:443", "xver":0, "serverNames":["$SNI"],
        "privateKey":"$PRIV", "shortIds":["$SID"] } },
    "sniffing": {"enabled":true,"destOverride":["http","tls","quic"]} }],
  "outbounds": [{"protocol":"freedom"}] }
JSON
"$XRAY_BIN" run -test -c "$BASE/v1.json" >/dev/null
make_service v1 "$XRAY_BIN" run -c "$BASE/v1.json"
open_port "$PORT" tcp
emit_link "vless://$UUID@$(public_ip):$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#v1-reality-tcp"
