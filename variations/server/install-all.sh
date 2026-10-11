#!/usr/bin/env bash
# Ставит сразу все варианты (каждый на своём порту, отдельным сервисом) и собирает ссылки в один файл.
# sudo ./install-all.sh [домен-для-V4]
# Домен необязателен: без него V4 пропускается.
set -uo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
LINKS_FILE="${LINKS_FILE:-/root/myvpn-links.txt}"; export LINKS_FILE
: > "$LINKS_FILE"
run() { echo "=== $1 ==="; shift; "$@" || echo "!!! не удалось: $1 (продолжаем)"; }
run V1 "$D/v1-reality-tcp.sh"
run V2 "$D/v2-reality-xhttp.sh"
run V3 "$D/v3-reality-grpc.sh"
run V5 "$D/v5-hysteria2.sh"
run V6 "$D/v6-ssh.sh"
[ -n "${1:-}" ] && run V4 "$D/v4-ws-tls-caddy.sh" "$1"
echo; echo "ГОТОВО. Все ссылки: $LINKS_FILE"; cat "$LINKS_FILE"
