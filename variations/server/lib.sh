#!/usr/bin/env bash
# Общие функции для серверных скриптов вариантов. Подключается через `source`.
set -euo pipefail

BASE="${BASE:-/etc/myvpn}"       # конфиги вариантов
DRY="${MYVPN_DRY:-0}"            # 1 = только сгенерировать и проверить конфиги (без systemd/фаервола/root)
LINKS="${LINKS_FILE:-/root/myvpn-links.txt}"   # сюда дописываются ссылки для клиента
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
SINGBOX_FALLBACK_VER=1.14.3

need_root() { [ "$DRY" = 1 ] || [ "$(id -u)" -eq 0 ] || { echo "Нужен root (sudo)."; exit 1; }; mkdir -p "$BASE"; }

pkg() {  # pkg curl unzip ...
  command -v apt-get >/dev/null && { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq "$@" >/dev/null 2>&1; return; }
  command -v dnf >/dev/null && { dnf install -y -q "$@" >/dev/null 2>&1; return; }
  command -v yum >/dev/null && { yum install -y -q "$@" >/dev/null 2>&1; return; }
  true
}

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "Неподдерживаемая архитектура $(uname -m)" >&2; exit 1 ;;
  esac
}

install_xray() {
  [ -x "$XRAY_BIN" ] && return
  pkg curl unzip openssl
  local a; [ "$(arch)" = amd64 ] && a=64 || a=arm64-v8a
  local tmp; tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/x.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$a.zip"
  unzip -oq "$tmp/x.zip" xray -d "$tmp"
  install -m 755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"
}

install_singbox() {
  [ -x "$SINGBOX_BIN" ] && return
  pkg curl openssl tar
  local tag ver
  tag=$(curl -fsSI -o /dev/null -w '%{redirect_url}' --max-redirs 0 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | sed 's#.*/tag/##' || true)
  ver="${tag#v}"; [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ver="$SINGBOX_FALLBACK_VER"
  local tmp; tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/s.tgz" "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-linux-$(arch).tar.gz"
  tar xzf "$tmp/s.tgz" -C "$tmp" --strip-components=1 --wildcards '*/sing-box'
  install -m 755 "$tmp/sing-box" "$SINGBOX_BIN"
  rm -rf "$tmp"
}

# make_service <имя> <команда запуска...>  — отдельный systemd-юнит на каждый вариант
make_service() {
  local name="$1"; shift
  [ "$DRY" = 1 ] && { echo "[dry] service myvpn-$name: $*"; return; }
  cat > "/etc/systemd/system/myvpn-$name.service" <<UNIT
[Unit]
Description=myvpn $name
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$*
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "myvpn-$name" >/dev/null 2>&1
  systemctl restart "myvpn-$name"
  sleep 1
  if ! systemctl is-active --quiet "myvpn-$name"; then
    echo "Сервис myvpn-$name не запустился:"; journalctl -u "myvpn-$name" -n 30 --no-pager; exit 1
  fi
}

open_port() {  # open_port <порт> <tcp|udp>
  [ "$DRY" = 1 ] && return
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active && ufw allow "$1/$2" >/dev/null 2>&1 || true
  command -v firewall-cmd >/dev/null && { firewall-cmd --permanent --add-port="$1/$2" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; } || true
}

port_busy() {  # port_busy <порт> <tcp|udp>
  local f=-ltn; [ "$2" = udp ] && f=-lun
  ss $f 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

public_ip() { [ "$DRY" = 1 ] && { echo 203.0.113.10; return; }; curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || curl -fsS4 --max-time 8 https://ifconfig.me 2>/dev/null || echo SERVER_IP; }

# reality_keys → выставляет PRIV и PUB (формат вывода xray x25519 менялся между версиями)
reality_keys() {
  local k; k=$("$XRAY_BIN" x25519)
  PRIV=$(echo "$k" | grep -i 'private' | awk '{print $NF}')
  PUB=$(echo "$k" | grep -iE 'public|password' | awk '{print $NF}')
  [ -n "$PRIV" ] && [ -n "$PUB" ] || { echo "Не удалось разобрать ключи xray:"; echo "$k"; exit 1; }
}

emit_link() {  # emit_link <ссылка>
  echo "$1" >> "$LINKS"
  echo; echo "Ссылка для клиента (добавлена в $LINKS):"; echo "$1"; echo
}

rand_hex() { openssl rand -hex "${1:-8}"; }
