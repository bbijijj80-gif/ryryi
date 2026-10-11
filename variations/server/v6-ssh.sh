#!/usr/bin/env bash
# V6 (запасной): SSH-туннель (ssh -D). Работает на стандартном OpenSSH, который есть везде,
# в Windows 10/11 клиент ssh.exe уже встроен. Легко опознаётся по протоколу, но иногда проходит там, где остальное нет.
# sudo ./v6-ssh.sh [ssh-порт=22]
source "$(dirname "$0")/lib.sh"; need_root
PORT="${1:-22}"
pkg openssh-server openssh-client
id tun >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin tun
mkdir -p "$BASE/v6" /home/tun/.ssh
rm -f "$BASE/v6/key" "$BASE/v6/key.pub"
ssh-keygen -q -t ed25519 -N '' -f "$BASE/v6/key"
# только проброс портов, без shell
echo "restrict,port-forwarding $(cat "$BASE/v6/key.pub")" > /home/tun/.ssh/authorized_keys
chown -R tun:tun /home/tun/.ssh; chmod 700 /home/tun/.ssh; chmod 600 /home/tun/.ssh/authorized_keys
if [ "$PORT" != 22 ] && ! grep -qE "^Port $PORT\b" /etc/ssh/sshd_config; then
  grep -q '^Port ' /etc/ssh/sshd_config || echo "Port 22" >> /etc/ssh/sshd_config
  echo "Port $PORT" >> /etc/ssh/sshd_config
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd
open_port "$PORT" tcp
echo
echo "Приватный ключ для клиента лежит тут: $BASE/v6/key"
echo "С Windows (PowerShell): scp root@$(public_ip):$BASE/v6/key \$env:USERPROFILE\\myvpn_key"
emit_link "ssh://tun@$(public_ip):$PORT#v6-ssh"
