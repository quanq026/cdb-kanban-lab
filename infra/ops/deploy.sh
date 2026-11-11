#!/usr/bin/env bash
# Deploy a prebuilt image tag on this VM with docker compose.
#
# Usage (on the VM):
#   sudo IMAGE_TAG=<sha> IMAGE_REPO=ghcr.io/<owner>/cdb-kanban \
#     bash infra/ops/deploy.sh <checkout-dir>
#
# Called by .github/workflows/deploy.yml with the tested commit SHA. The legacy
# systemd unit must already be stopped/disabled (runbook-manual.md section 3);
# this script refuses to run while it is still active.
#
# Steps: pull -> write compose env + current/previous tag -> compose up ->
# nginx conf install + nginx -t + reload -> health checks (10x2 s). Any failure
# after the pull rolls back to the previous tag.
set -euo pipefail

SRC="${1:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
IMAGE_REPO="${IMAGE_REPO:-}"

if [ -z "$SRC" ] || [ ! -f "$SRC/app/app.py" ]; then
  echo "usage: sudo IMAGE_TAG=<sha> IMAGE_REPO=<repo> bash $0 <checkout-dir>" >&2
  exit 2
fi
if [ -z "$IMAGE_TAG" ] || [ -z "$IMAGE_REPO" ]; then
  echo "IMAGE_TAG and IMAGE_REPO are required" >&2
  exit 2
fi
SRC="$(cd "$SRC" && pwd)"

ETC=/opt/cdb
COMPOSE_FILE="$ETC/docker-compose.yml"
COMPOSE_ENV="$ETC/compose.env"
CURRENT="$ETC/current_tag"
PREVIOUS="$ETC/previous_tag"
NGINX_SITE=/etc/nginx/sites-available/cdb-kanban
CF_REALIP=/etc/nginx/conf.d/cloudflare-realip.conf
DOMAIN="${DOMAIN:-kanban.akaine.io.vn}"
KEEP_TAGS=3

for f in docker-compose.yml nginx-cdb.conf nginx-cloudflare-realip.conf; do
  if [ ! -f "$SRC/infra/ops/$f" ]; then
    echo "missing $SRC/infra/ops/$f" >&2
    exit 2
  fi
done

if systemctl is-active --quiet cdb-kanban; then
  echo "cdb-kanban.service is still active; finish the cutover in docs/runbook-manual.md first" >&2
  exit 2
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is missing; run infra/setup/vm.sh" >&2
  exit 2
fi

install -d -m 755 "$ETC"
install -m 644 "$SRC/infra/ops/docker-compose.yml" "$COMPOSE_FILE"

compose_env() {
  umask 077
  printf 'CDB_IMAGE=%s\nIMAGE_TAG=%s\n' "$IMAGE_REPO" "$1" >"$COMPOSE_ENV"
  chmod 600 "$COMPOSE_ENV"
}

compose() { docker compose --env-file "$COMPOSE_ENV" -f "$COMPOSE_FILE" "$@"; }

echo "pull=$IMAGE_REPO:$IMAGE_TAG"
docker pull "$IMAGE_REPO:$IMAGE_TAG"

OLD_TAG=""
OLD_PREVIOUS=""
if [ -f "$CURRENT" ]; then
  OLD_TAG="$(cat "$CURRENT")"
fi
if [ -f "$PREVIOUS" ]; then
  OLD_PREVIOUS="$(cat "$PREVIOUS")"
fi
if [ -n "$OLD_TAG" ]; then
  printf '%s\n' "$OLD_TAG" >"$PREVIOUS"
fi
printf '%s\n' "$IMAGE_TAG" >"$CURRENT"
compose_env "$IMAGE_TAG"

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

rollback() {
  local code=$?
  trap - ERR
  echo "!! deploy failed (exit $code) -> rollback" >&2
  if [ -z "$OLD_TAG" ]; then
    echo "!! no previous tag to roll back to" >&2
    exit 1
  fi
  compose_env "$OLD_TAG"
  printf '%s\n' "$OLD_TAG" >"$CURRENT"
  if [ -n "$OLD_PREVIOUS" ]; then
    printf '%s\n' "$OLD_PREVIOUS" >"$PREVIOUS"
  else
    rm -f "$PREVIOUS"
  fi
  docker pull "$IMAGE_REPO:$OLD_TAG" >/dev/null 2>&1 || true
  compose up -d --remove-orphans || true
  wait_http app "http://127.0.0.1:8000/api/health" || true
  echo "!! rolled back to $IMAGE_REPO:$OLD_TAG" >&2
  exit 1
}
trap rollback ERR

compose up -d --remove-orphans

wait_http app "http://127.0.0.1:8000/api/health"
wait_http tls -k --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/health"
wait_http login "http://127.0.0.1:8000/login"
wait_http register "http://127.0.0.1:8000/register"

install -m 644 "$SRC/infra/ops/nginx-cdb.conf" "$NGINX_SITE"
install -m 644 "$SRC/infra/ops/nginx-cloudflare-realip.conf" "$CF_REALIP"
nginx -t
systemctl reload nginx

trap - ERR

mapfile -t TAGS < <(
  docker image ls "$IMAGE_REPO" --format '{{.Tag}} {{.CreatedAt}}' |
    grep -v '^<none>' |
    sort -k2 -r |
    awk '{print $1}'
)
for TAG in "${TAGS[@]:KEEP_TAGS}"; do
  if [ "$TAG" = "$IMAGE_TAG" ] || [ "$TAG" = "$OLD_TAG" ]; then
    continue
  fi
  docker image rm "$IMAGE_REPO:$TAG" >/dev/null 2>&1 || true
  echo "pruned_image=$TAG"
done

echo "deploy=ok"
echo "current_tag=$IMAGE_TAG"
echo "previous_tag=$OLD_TAG"
echo "health_public=$(curl -sS --max-time 20 http://127.0.0.1:8000/api/health)"
echo "health_nginx=$(curl -sS --max-time 20 -k --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/api/health")"
echo "health_detail=$(docker exec cdb-app python -c 'import urllib.request as u;print(u.urlopen("http://127.0.0.1:8000/api/health?detail=1", timeout=5).read().decode())' || echo unavailable)"
