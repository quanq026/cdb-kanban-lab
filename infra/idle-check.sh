set -euo pipefail
# Do thoi gian request dau tien sau khi Neon scale-to-zero (~5 phut idle).
echo "idle_wait_start=$(date -u +%FT%TZ)"
sleep 330
echo "idle_wait_end=$(date -u +%FT%TZ)"
for i in 1 2 3; do
  curl -sS -o /dev/null -w "health_try${i} status=%{http_code} total=%{time_total}s\n" \
    --max-time 60 http://127.0.0.1:8000/api/health
done
