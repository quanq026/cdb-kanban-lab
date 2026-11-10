#!/usr/bin/env bash
set -euo pipefail

if grep -q '^APP_SECRET_KEY=' /etc/cdb/app.env; then
  echo "APP_SECRET_KEY=already-set (khong in gia tri)"
else
  key=$(/opt/cdb/venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(48))')
  printf 'APP_SECRET_KEY=%s\n' "$key" >> /etc/cdb/app.env
  echo "APP_SECRET_KEY=added (khong in gia tri)"
fi

stat -c '%a %U:%G %n' /etc/cdb/app.env
grep -c '^APP_SECRET_KEY=' /etc/cdb/app.env
