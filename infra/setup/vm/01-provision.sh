#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release nginx python3-venv python3-pip docker.io >/dev/null

install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt-get update -qq
apt-get install -y -qq postgresql-client-17 >/dev/null

systemctl enable --now docker >/dev/null 2>&1
systemctl enable --now nginx >/dev/null 2>&1

usermod -aG docker azureuser

echo "swap: $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
echo "docker: $(docker --version)"
echo "nginx: $(nginx -v 2>&1)"
echo "psql: $(psql --version)"
echo "venv: $(python3 -c 'import venv,sys; print(sys.version.split()[0])')"
echo "arch: $(uname -m)"
