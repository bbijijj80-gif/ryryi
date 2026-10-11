#!/usr/bin/env bash
# V5: Hysteria2 (QUIC/UDP) + обфускация salamander. Совсем другое семейство — UDP, а не TCP.
# Конфиг клиента (с вшитым самоподписанным сертификатом для проверки) передаётся одной base64-строкой.
# sudo ./v5-hysteria2.sh [udp-порт=443] [sni=www.bing.com]
source "$(dirname "$0")/lib.sh"; need_root
PORT="${1:-443}"; SNI="${2:-www.bing.com}"
port_busy "$PORT" udp && { echo "UDP-порт $PORT занят, укажите другой."; exit 1; }
install_singbox; pkg openssl
PASS=$(rand_hex 12); OBFS=$(rand_hex 12)
mkdir -p "$BASE/v5"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
  -keyout "$BASE/v5/key.pem" -out "$BASE/v5/cert.pem" -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1
cat > "$BASE/v5.json" <<JSON
{ "log": {"level":"warn"},
  "inbounds": [{ "type":"hysteria2", "listen":"::", "listen_port": $PORT,
    "users": [{"password":"$PASS"}],
    "obfs": {"type":"salamander","password":"$OBFS"},
    "tls": {"enabled":true,"server_name":"$SNI","alpn":["h3"],
            "certificate_path":"$BASE/v5/cert.pem","key_path":"$BASE/v5/key.pem"},
    "masquerade": "https://$SNI" }],
  "outbounds": [{"type":"direct"}] }
JSON
"$SINGBOX_BIN" check -c "$BASE/v5.json"
make_service v5 "$SINGBOX_BIN" run -c "$BASE/v5.json"
open_port "$PORT" udp
IP=$(public_ip)
CERT_JSON=$(awk 'BEGIN{printf "["} NF{printf "%s\"%s\"", (n++?",":""), $0} END{printf "]"}' "$BASE/v5/cert.pem")
CLIENT=$(cat <<JSON
{"server":"$IP","port":$PORT,"password":"$PASS","obfs":"$OBFS","sni":"$SNI","cert":$CERT_JSON}
JSON
)
emit_link "hy2blob://$(echo -n "$CLIENT" | base64 -w0)#v5-hysteria2"
