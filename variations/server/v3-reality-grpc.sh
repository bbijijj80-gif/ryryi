#!/usr/bin/env bash
# V3: VLESS + REALITY + gRPC (мультиплексированный HTTP/2).
# sudo ./v3-reality-grpc.sh [порт=2053] [sni=www.apple.com]
source "$(dirname "$0")/lib.sh"; need_root
PORT="${1:-2053}"; SNI="${2:-www.apple.com}"
port_busy "$PORT" tcp && { echo "TCP-порт $PORT занят, укажите другой."; exit 1; }
install_xray; reality_keys
UUID=$("$XRAY_BIN" uuid); SID=$(rand_hex 8); SVC=$(rand_hex 6)
cat > "$BASE/v3.json" <<JSON
{ "log": {"loglevel":"warning"},
  "inbounds": [{ "port": $PORT, "protocol": "vless",
    "settings": { "clients": [{"id":"$UUID"}], "decryption":"none" },
    "streamSettings": { "network":"grpc", "grpcSettings": {"serviceName":"$SVC"},
      "security":"reality",
      "realitySettings": { "dest":"$SNI:443", "xver":0, "serverNames":["$SNI"],
        "privateKey":"$PRIV", "shortIds":["$SID"] } } }],
  "outbounds": [{"protocol":"freedom"}] }
JSON
"$XRAY_BIN" run -test -c "$BASE/v3.json" >/dev/null
make_service v3 "$XRAY_BIN" run -c "$BASE/v3.json"
open_port "$PORT" tcp
emit_link "vless://$UUID@$(public_ip):$PORT?encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=grpc&serviceName=$SVC#v3-reality-grpc"
