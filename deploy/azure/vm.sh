#!/usr/bin/env bash
# One-time VM bootstrap for the container-based deploy.
#
# Installs swap, nginx, PostgreSQL client 17 and Docker + compose plugin, writes
# /etc/cdb/app.env from /etc/cdb/secrets.env, and puts the deploy user in the
# docker group. Images, the compose file and the nginx site are pushed by
# deploy/azure/deploy.sh from a repo checkout. The legacy venv/systemd unit is no
# longer created; a running one is removed only by the cutover checklist.
#
# Usage (on the VM): sudo bash deploy/azure/vm.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

APP_USER="${APP_USER:-${SUDO_USER:-$(id -un)}}"
ENV_FILE=/etc/cdb/app.env
SECRETS=/etc/cdb/secrets.env

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
apt-get install -y -qq ca-certificates curl gnupg lsb-release nginx openssl \
  docker.io docker-compose-v2 >/dev/null

# 3. PostgreSQL 17 client from the PGDG repository.
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt-get update -qq
apt-get install -y -qq postgresql-client-17 >/dev/null

# 4. Enable nginx and Docker.
systemctl enable --now nginx >/dev/null 2>&1
systemctl enable --now docker >/dev/null

# 5. Deploy dir and docker group membership (re-login or restart the runner after).
install -d -m 755 /opt/cdb
install -d -m 700 /etc/cdb
if [ "$APP_USER" != "root" ]; then
  usermod -aG docker "$APP_USER"
fi

# 6. App environment (DB credentials) from the owner-only secrets file.
# Keep the existing APP_SECRET_KEY so re-running this on a live VM (cutover)
# does not invalidate every session; generate one only when there is none.
if [ -f "$SECRETS" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$SECRETS"
  set +a
  OLD_SECRET=""
  if [ -f "$ENV_FILE" ]; then
    OLD_SECRET="$(sed -n 's/^APP_SECRET_KEY=//p' "$ENV_FILE" | head -n1)"
  fi
  SESSION_KEY="${APP_SECRET_KEY:-${OLD_SECRET:-}}"
  if [ -z "$SESSION_KEY" ]; then
    SESSION_KEY="$(openssl rand -hex 32)"
    echo "generated a new APP_SECRET_KEY; existing sessions are reset" >&2
  fi
  umask 077
  cat > "$ENV_FILE" <<ENV
DB_HOST=${NEON_HOST}
DB_PORT=5432
DB_NAME=studydb
DB_USER=app_user
DB_PASSWORD=${NEON_APP_PASSWORD}
DB_SSLMODE=verify-full
DB_SSLROOTCERT=/etc/ssl/certs/ca-certificates.crt
APP_SECRET_KEY=${SESSION_KEY}
ENV
  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "wrote $ENV_FILE"
else
  echo "warning: $SECRETS missing; create it and re-run to write $ENV_FILE" >&2
fi

# 7. Summary.
echo "swap:    $(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ')"
echo "nginx:   $(nginx -v 2>&1)"
echo "psql:    $(psql --version)"
echo "docker:  $(docker --version)"
echo "compose: $(docker compose version)"
echo "arch:    $(uname -m)"
echo "next:    finish the cutover in docs/runbook-manual.md section 3"
