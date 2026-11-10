#!/usr/bin/env bash
set -euo pipefail

APP=/opt/cdb/app
STAMP=$(date +%F)
if [ -e "$APP/backup-$STAMP" ]; then
  STAMP="$STAMP-$(date +%H%M%S)"
fi
BACKUP="$APP/backup-$STAMP"

test -f /tmp/app.py.new
test -f /tmp/index.html.new
test -f /tmp/login.html.new
test -f /tmp/register.html.new
test -f /tmp/nginx-cdb.conf.new
test -f /tmp/cf-realip.conf.new

mkdir -p "$BACKUP"
cp -a "$APP/app.py" "$APP/index.html" "$BACKUP/"
for f in app.css app.js login.html register.html; do
  if [ -f "$APP/$f" ]; then cp -a "$APP/$f" "$BACKUP/$f"; fi
done
cp -a /etc/nginx/sites-available/cdb-kanban "$BACKUP/cdb-kanban.conf"
if [ -f /etc/nginx/conf.d/cloudflare-realip.conf ]; then
  cp -a /etc/nginx/conf.d/cloudflare-realip.conf "$BACKUP/cloudflare-realip.conf"
fi
echo "backup=$BACKUP"

rollback() {
  echo "!! deploy failed -> rollback"
  cp -a "$BACKUP/app.py" "$APP/app.py"
  cp -a "$BACKUP/index.html" "$APP/index.html"
  if [ -f "$BACKUP/login.html" ]; then
    cp -a "$BACKUP/login.html" "$APP/login.html"
  else
    rm -f "$APP/login.html"
  fi
  if [ -f "$BACKUP/register.html" ]; then
    cp -a "$BACKUP/register.html" "$APP/register.html"
  else
    rm -f "$APP/register.html"
  fi
  for f in app.css app.js; do
    if [ -f "$BACKUP/$f" ]; then cp -a "$BACKUP/$f" "$APP/$f"; fi
  done
  cp -a "$BACKUP/cdb-kanban.conf" /etc/nginx/sites-available/cdb-kanban
  if [ -f "$BACKUP/cloudflare-realip.conf" ]; then
    cp -a "$BACKUP/cloudflare-realip.conf" /etc/nginx/conf.d/cloudflare-realip.conf
  else
    rm -f /etc/nginx/conf.d/cloudflare-realip.conf
  fi
  rm -rf "$APP/__pycache__"
  systemctl restart cdb-kanban || true
  nginx -t && systemctl reload nginx || true
  echo "!! rolled back to $BACKUP"
  exit 1
}
trap rollback ERR

install -m 644 /tmp/cf-realip.conf.new /etc/nginx/conf.d/cloudflare-realip.conf
install -m 644 /tmp/nginx-cdb.conf.new /etc/nginx/sites-available/cdb-kanban
install -m 644 -o azureuser -g azureuser /tmp/app.py.new "$APP/app.py"
install -m 644 -o azureuser -g azureuser /tmp/index.html.new "$APP/index.html"
install -m 644 -o azureuser -g azureuser /tmp/login.html.new "$APP/login.html"
install -m 644 -o azureuser -g azureuser /tmp/register.html.new "$APP/register.html"
if [ -f /tmp/app.css.new ]; then install -m 644 -o azureuser -g azureuser /tmp/app.css.new "$APP/app.css"; fi
if [ -f /tmp/app.js.new ]; then install -m 644 -o azureuser -g azureuser /tmp/app.js.new "$APP/app.js"; fi
rm -rf "$APP/__pycache__"

nginx -t
systemctl reload nginx
systemctl restart cdb-kanban
sleep 3

systemctl is-active --quiet cdb-kanban
curl -fsS --max-time 20 http://127.0.0.1:8000/api/health >/dev/null
curl -fsS --max-time 20 -k --resolve kanban.akaine.io.vn:443:127.0.0.1 https://kanban.akaine.io.vn/api/health >/dev/null
curl -fsS --max-time 20 http://127.0.0.1:8000/login >/dev/null
curl -fsS --max-time 20 http://127.0.0.1:8000/register >/dev/null
trap - ERR

echo "deploy=ok"
echo "login_page=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 http://127.0.0.1:8000/login)"
echo "register_page=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 http://127.0.0.1:8000/register)"
echo "health_public=$(curl -sS --max-time 20 http://127.0.0.1:8000/api/health)"
echo "health_nginx=$(curl -sS --max-time 20 -k --resolve kanban.akaine.io.vn:443:127.0.0.1 https://kanban.akaine.io.vn/api/health)"
echo "health_detail=$(curl -sS --max-time 20 http://127.0.0.1:8000/api/health?detail=1)"
