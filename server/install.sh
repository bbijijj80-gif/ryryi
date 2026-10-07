#!/usr/bin/env bash
# Установка VLESS + REALITY (Xray-core) на Linux-сервер. Запускать от root.
# Использование: sudo ./install.sh [порт=443] [маскировочный_сайт=www.microsoft.com]
set -euo pipefail

PORT="${1:-443}"
SNI="${2:-www.microsoft.com}"   # сайт с TLS 1.3 + h2, вне РФ, не заблокированный
XRAY_DIR=/usr/local/etc/xray
[ "$(id -u)" -eq 0 ] || { echo "Нужен root"; exit 1; }

apt-get update -qq 2>/dev/null && apt-get install -y -qq curl unzip openssl >/dev/null 2>&1 || true

# Официальный установщик Xray-core
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

UUID=$(xray uuid)
KEYS=$(xray x25519)
PRIV=$(echo "$KEYS" | grep -i 'private' | awk '{print $NF}')
PUB=$(echo "$KEYS" | grep -iE 'public|password' | awk '{print $NF}')
SID=$(openssl rand -hex 8)
[ -n "$PRIV" ] && [ -n "$PUB" ] || { echo "Не удалось разобрать ключи:"; echo "$KEYS"; exit 1; }

mkdir -p "$XRAY_DIR"
cat > "$XRAY_DIR/config.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": ["$SID"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
JSON

systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active --quiet xray || { journalctl -u xray -n 30 --no-pager; exit 1; }

IP=$(curl -fsS4 https://api.ipify.org || echo "SERVER_IP")
LINK="vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#myvpn"
echo "$LINK" > "$XRAY_DIR/client-link.txt"
echo
echo "Готово. Ссылка для Windows-клиента (также в $XRAY_DIR/client-link.txt):"
echo "$LINK"
echo "Не забудьте открыть порт $PORT/tcp в фаервole."
