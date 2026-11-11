#!/usr/bin/env bash
# One-time VM bootstrap.
#
# Installs system packages (swap, nginx, PostgreSQL client 17), creates
# the app venv, writes /etc/cdb/app.env from /etc/cdb/secrets.env, and installs
# the systemd unit. App files and the nginx site are pushed afterwards by
# infra/ops/deploy.sh from a repo checkout.
#
# Usage (on the VM): sudo bash infra/setup/vm.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

APP_USER="${APP_USER:-${SUDO_USER:-$(id -un)}}"
APP_DIR=/opt/cdb/app
VENV=/opt/cdb/venv
ENV_FILE=/etc/cdb/app.env
SECRETS=/etc/cdb/secrets.env
UNIT=/etc/systemd/system/cdb-kanban.service

# 1. Swap 2 GiB (skip if already active).
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 2. Base packages.
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release nginx \
  python3-venv python3-pip >/dev/null

# 3. PostgreSQL 17 client from the PGDG repository.
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt-get update -qq
apt-get install -y -qq postgresql-client-17 >/dev/null

# 4. Enable nginx.
systemctl enable --now nginx >/dev/null 2>&1

# 5. App dirs and Python venv.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ="$HERE/../../app/requirements.txt"
install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR"
install -d -m 700 /etc/cdb
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
fi
if [ ! -f "$REQ" ]; then
  echo "requirements not found: $REQ (run from a repo checkout)" >&2
  exit 2
fi
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$REQ"

# 6. App environment (DB credentials) from the owner-only secrets file.
if [ -f "$SECRETS" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$SECRETS"
  set +a
  umask 077
  cat > "$ENV_FILE" <<ENV
DB_HOST=${NEON_HOST}
DB_PORT=5432
DB_NAME=studydb
DB_USER=app_user
DB_PASSWORD=${NEON_APP_PASSWORD}
DB_SSLMODE=verify-full
DB_SSLROOTCERT=/etc/ssl/certs/ca-certificates.crt
ENV
  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "wrote $ENV_FILE"
else
  echo "warning: $SECRETS missing; create it and re-run to write $ENV_FILE" >&2
fi

# 7. systemd unit.
cat > "$UNIT" <<UNIT
[Unit]
Description=CDB Kanban (Flask + gunicorn)
After=network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=/opt/cdb/app
EnvironmentFile=/etc/cdb/app.env
ExecStart=/opt/cdb/venv/bin/gunicorn --workers 2 --bind 127.0.0.1:8000 --timeout 30 --access-logfile - --error-logfile - app:app
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable cdb-kanban >/dev/null

# 8. Summary.
echo "swap:   $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
echo "nginx:  $(nginx -v 2>&1)"
echo "psql:   $(psql --version)"
echo "arch:   $(uname -m)"
echo "next:   clone the repo, then: sudo bash infra/ops/deploy.sh \"\$PWD\""
