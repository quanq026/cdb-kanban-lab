#!/usr/bin/env bash
# Deploy the app from a git checkout onto this VM.
#
# Usage (on the VM): sudo bash infra/ops/deploy.sh <checkout-dir>
#
# The GitHub Actions deploy job calls it with $GITHUB_WORKSPACE. A human can use
# the repo root, e.g. `sudo bash infra/ops/deploy.sh "$PWD"`.
#
# Steps: back up -> install app + nginx conf -> nginx -t -> restart -> health
# checks with retry. Any failure triggers an automatic rollback (trap ERR).
set -euo pipefail

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC/app/app.py" ]; then
  echo "usage: sudo bash $0 <checkout-dir>" >&2
  exit 2
fi
SRC="$(cd "$SRC" && pwd)"

APP=/opt/cdb/app
OWNER="${APP_OWNER:-$(stat -c %U "$APP" 2>/dev/null || id -un)}"
GROUP="${APP_GROUP:-$(stat -c %G "$APP" 2>/dev/null || id -gn)}"
MANAGED="app.py index.html login.html register.html app.css app.js"
REQUIRED="app.py index.html app.css app.js"
NGINX_SITE=/etc/nginx/sites-available/cdb-kanban
CF_REALIP=/etc/nginx/conf.d/cloudflare-realip.conf
DOMAIN="${DOMAIN:-kanban.akaine.io.vn}"

for f in $REQUIRED; do
  if [ ! -f "$SRC/app/$f" ]; then
    echo "missing $SRC/app/$f" >&2
    exit 2
  fi
done
for f in nginx-cdb.conf nginx-cloudflare-realip.conf; do
  if [ ! -f "$SRC/infra/ops/$f" ]; then
    echo "missing $SRC/infra/ops/$f" >&2
    exit 2
  fi
done

STAMP=$(date +%F)
if [ -e "$APP/backup-$STAMP" ]; then
  STAMP="$STAMP-$(date +%H%M%S)"
fi
BACKUP="$APP/backup-$STAMP"

mkdir -p "$BACKUP"
for f in $MANAGED; do
  if [ -f "$APP/$f" ]; then cp -a "$APP/$f" "$BACKUP/$f"; fi
done
if [ -f "$NGINX_SITE" ]; then cp -a "$NGINX_SITE" "$BACKUP/cdb-kanban.conf"; fi
if [ -f "$CF_REALIP" ]; then cp -a "$CF_REALIP" "$BACKUP/cloudflare-realip.conf"; fi
echo "backup=$BACKUP"

rollback() {
  echo "!! deploy failed -> rollback"
  for f in $MANAGED; do
    if [ -f "$BACKUP/$f" ]; then
      install -m 644 -o "$OWNER" -g "$GROUP" "$BACKUP/$f" "$APP/$f"
    else
      rm -f "$APP/$f"
    fi
  done
  if [ -f "$BACKUP/cdb-kanban.conf" ]; then
    install -m 644 "$BACKUP/cdb-kanban.conf" "$NGINX_SITE"
  else
    rm -f "$NGINX_SITE"
  fi
  if [ -f "$BACKUP/cloudflare-realip.conf" ]; then
    install -m 644 "$BACKUP/cloudflare-realip.conf" "$CF_REALIP"
  else
    rm -f "$CF_REALIP"
  fi
  rm -rf "$APP/__pycache__"
  systemctl restart cdb-kanban || true
  nginx -t && systemctl reload nginx || true
  echo "!! rolled back to $BACKUP"
  exit 1
}
trap rollback ERR

install -m 644 "$SRC/infra/ops/nginx-cdb.conf" "$NGINX_SITE"
install -m 644 "$SRC/infra/ops/nginx-cloudflare-realip.conf" "$CF_REALIP"
for f in $MANAGED; do
  if [ -f "$SRC/app/$f" ]; then
    install -m 644 -o "$OWNER" -g "$GROUP" "$SRC/app/$f" "$APP/$f"
  else
    rm -f "$APP/$f"
  fi
done
rm -rf "$APP/__pycache__"

nginx -t
systemctl reload nginx
systemctl restart cdb-kanban

wait_http() {
  local label=$1
  shift
  for _ in {1..10}; do
    if curl -fsS --max-time 10 "$@" >/dev/null 2>&1; then
      echo "check_$label=ok"
      return 0
    fi
    sleep 2
  done
  echo "check_$label=failed" >&2
  return 1
}

systemctl is-active --quiet cdb-kanban
wait_http app "http://127.0.0.1:8000/api/health"
wait_http tls -k --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/health"
wait_http login "http://127.0.0.1:8000/login"
wait_http register "http://127.0.0.1:8000/register"
trap - ERR

echo "deploy=ok"
echo "backup_path=$BACKUP"
echo "health_public=$(curl -sS --max-time 20 http://127.0.0.1:8000/api/health)"
echo "health_nginx=$(curl -sS --max-time 20 -k --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/health")"
echo "health_detail=$(curl -sS --max-time 20 http://127.0.0.1:8000/api/health?detail=1)"
