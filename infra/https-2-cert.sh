#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq certbot >/dev/null

certbot certonly --webroot -w /var/www/letsencrypt -d kanban.akaine.io.vn \
  --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring

echo "--- certificate ---"
openssl x509 -in /etc/letsencrypt/live/kanban.akaine.io.vn/fullchain.pem -noout -subject -issuer -dates
echo "--- renewal timer ---"
systemctl list-timers 'certbot*' --no-pager | head -3
