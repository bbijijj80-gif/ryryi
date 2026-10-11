#!/usr/bin/env bash
# V2: VLESS + REALITY + XHTTP (HTTP-подобный транспорт вместо сырого TCP; другой «профиль» трафика).
# sudo ./v2-reality-xhttp.sh [порт=8443] [sni=www.cloudflare.com]
source "$(dirname "$0")/lib.sh"; need_root
PORT="${1:-8443}"; SNI="${2:-www.cloudflare.com}"
port_busy "$PORT" tcp && { echo "TCP-порт $PORT занят, укажите другой."; exit 1; }
install_xray; reality_keys
UUID=$("$XRAY_BIN" uuid); SID=$(rand_hex 8); XPATH="/$(rand_hex 4)"
cat > "$BASE/v2.json" <<JSON
{ "log": {"loglevel":"warning"},
  "inbounds": [{ "port": $PORT, "protocol": "vless",
    "settings": { "clients": [{"id":"$UUID"}], "decryption":"none" },
    "streamSettings": { "network":"xhttp", "xhttpSettings": {"path":"$XPATH","mode":"auto"},
      "security":"reality",
      "realitySettings": { "dest":"$SNI:443", "xver":0, "serverNames":["$SNI"],
        "privateKey":"$PRIV", "shortIds":["$SID"] } } }],
  "outbounds": [{"protocol":"freedom"}] }
JSON
"$XRAY_BIN" run -test -c "$BASE/v2.json" >/dev/null
make_service v2 "$XRAY_BIN" run -c "$BASE/v2.json"
open_port "$PORT" tcp
emit_link "vless://$UUID@$(public_ip):$PORT?encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=xhttp&path=%2F${XPATH#/}&mode=auto#v2-reality-xhttp"
