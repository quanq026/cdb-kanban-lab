#!/usr/bin/env bash
set -uo pipefail

BASE=https://kanban.akaine.io.vn
CURL=(curl -sS -k --resolve kanban.akaine.io.vn:443:127.0.0.1)
DIRECT=http://127.0.0.1:8000
BODY=/tmp/cdb-test-body.json
JAR1=/tmp/cdb-jar1.txt
JAR2=/tmp/cdb-jar2.txt
PASS=0
FAIL=0

set -a
. /etc/cdb/app.env
set +a
DSN="host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=verify-full sslrootcert=$DB_SSLROOTCERT"

cleanup_accounts() {
  export PGPASSWORD="$DB_PASSWORD"
  psql "$DSN" -q -v ON_ERROR_STOP=1 -c \
    "DELETE FROM tasks WHERE user_id IN (SELECT id FROM users WHERE email LIKE 'test-%@example.test');" >/dev/null 2>&1
  psql "$DSN" -q -v ON_ERROR_STOP=1 -c \
    "DELETE FROM users WHERE email LIKE 'test-%@example.test';" >/dev/null 2>&1
  psql "$DSN" -At -c \
    "SELECT 'leftover_test_users=' || count(*) FROM users WHERE email LIKE 'test-%@example.test';" 2>/dev/null
  unset PGPASSWORD
}
trap cleanup_accounts EXIT

echo "== don tai khoan test cu (neu co) =="
cleanup_accounts

STAMP=$(date +%s)
EMAIL1="test-$STAMP-a@example.test"
EMAIL2="test-$STAMP-b@example.test"
PW="TestPass-$STAMP"
u1=0
u2=0

call() {
  local method=$1 path=$2 jar=$3
  shift 3
  if [ -n "$jar" ]; then
    "${CURL[@]}" -b "$jar" -c "$jar" -o "$BODY" -w '%{http_code}' -X "$method" "$@" "$BASE$path"
  else
    "${CURL[@]}" -o "$BODY" -w '%{http_code}' -X "$method" "$@" "$BASE$path"
  fi
}

callj() {
  local method=$1 path=$2 jar=$3 data=$4
  call "$method" "$path" "$jar" -H 'Content-Type: application/json' -d "$data"
}

register() {
  local email=$1 password=$2 jar=$3
  if [ -n "$jar" ]; then rm -f "$jar"; fi
  "${CURL[@]}" -c "$jar" -o "$BODY" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$BASE/api/register"
}

login() {
  local email=$1 password=$2 jar=$3
  if [ -n "$jar" ]; then rm -f "$jar"; fi
  "${CURL[@]}" -c "$jar" -o "$BODY" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$BASE/api/login"
}

check() {
  local name=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    printf 'PASS | %-46s | %s\n' "$name" "$got"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL | %-46s | want=%s got=%s body=%s\n' "$name" "$want" "$got" "$(head -c 200 "$BODY")"
  fi
}

jget() {
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$BODY" "$1"
}

jkeys() {
  python3 -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])).keys())))' "$BODY"
}

jlen() {
  python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$BODY"
}

juser() {
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["user"][sys.argv[2]])' "$BODY" "$1"
}

jids() {
  python3 -c 'import json,sys;print(",".join(str(t["id"]) for t in json.load(open(sys.argv[1])) if t["status"]==sys.argv[2]))' "$BODY" "$1"
}

echo
echo "== chua dang nhap =="
code=$(call GET /api/tasks "")
check "GET /api/tasks (no session) -> 401" 401 "$code"
check "unauth code" "unauthenticated" "$(jget code)"
code=$("${CURL[@]}" -o "$BODY" -w '%{http_code}' "$BASE/")
check "GET / (no session) -> 302" 302 "$code"
code=$("${CURL[@]}" -o "$BODY" -w '%{http_code}' "$BASE/login")
check "GET /login -> 200" 200 "$code"
code=$("${CURL[@]}" -o "$BODY" -w '%{http_code}' "$BASE/register")
check "GET /register -> 200" 200 "$code"
code=$("${CURL[@]}" -o "$BODY" -w '%{http_code}' "$BASE/api/health")
check "GET /api/health (public) -> 200" 200 "$code"

echo
echo "== dang ky: validate =="
code=$(register "not-an-email" "$PW" "")
check "register email sai -> 400" 400 "$code"
check "register email sai code" "invalid_request" "$(jget code)"
code=$(register "test-x-$STAMP@example.test" "1234567" "")
check "register mat khau 7 ky tu -> 400" 400 "$code"
code=$(callj POST /api/register "" "{\"email\":\"test-y-$STAMP@example.test\"}")
check "register thieu password -> 400" 400 "$code"
code=$(callj POST /api/register "" 'not json')
check "register body khong phai JSON -> 400" 400 "$code"

echo
echo "== dang ky: tao tai khoan 1 (tu dong dang nhap) =="
code=$(register "$EMAIL1" "$PW" "$JAR1")
check "register user1 -> 201" 201 "$code"
check "register tra email" "$EMAIL1" "$(juser email)"
u1=$(juser id)
check "register set session -> GET /api/me 200" 200 "$(call GET /api/me "$JAR1")"
check "me.id = user1" "$u1" "$(juser id)"
code=$(call GET "/api/tasks?user_id=$u1" "$JAR1")
check "board user moi rong" 0 "$(jlen)"
code=$("${CURL[@]}" -b "$JAR1" -o "$BODY" -w '%{http_code}' "$BASE/register")
check "GET /register (da dang nhap) -> 302" 302 "$code"

echo
echo "== dang ky: trung email =="
code=$(register "$EMAIL1" "$PW" "")
check "register trung email -> 409" 409 "$code"
check "register trung code" "unique_violation" "$(jget code)"

echo
echo "== dang ky: tao tai khoan 2 =="
code=$(register "$EMAIL2" "$PW" "$JAR2")
check "register user2 -> 201" 201 "$code"
u2=$(juser id)

echo
echo "== dang ky: khong con gioi han =="
reg_codes=$(for i in 1 2 3 4 5 6; do
  "${CURL[@]}" -o /dev/null -w '%{http_code}\n' -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"test-$STAMP-r$i@example.test\",\"password\":\"$PW\"}" "$BASE/api/register"
done | sort | uniq -c)
echo "$reg_codes" | sed 's/^/register-burst /'
check "6 dang ky lien tiep deu 201" 6 "$(echo "$reg_codes" | awk '$2=="201"{print $1+0}')"
check "6 dang ky khong co 429" 0 "$(echo "$reg_codes" | grep -c ' 429$')"

echo
echo "== dang nhap =="
code=$(call POST /api/logout "$JAR1")
check "logout truoc khi test login -> 200" 200 "$code"
code=$(login "$EMAIL1" "sai-mat-khau-$STAMP" "$JAR1")
check "login sai mat khau -> 401" 401 "$code"
check "login sai code" "invalid_credentials" "$(jget code)"
code=$(login "khong-ton-tai-$STAMP@example.test" "whatever-$STAMP" "$JAR1")
check "login email la -> 401" 401 "$code"
code=$(callj POST /api/login "" "{\"email\":\"$EMAIL1\"}")
check "login thieu password -> 400" 400 "$code"
code=$(login "$EMAIL1" "$PW" "$JAR1")
check "login dung -> 200" 200 "$code"
check "login tra email" "$EMAIL1" "$(juser email)"
code=$(call GET /api/me "$JAR1")
check "GET /api/me -> 200" 200 "$code"
check "me.id = u1" "$u1" "$(juser id)"
code=$(call GET /api/users "$JAR1")
check "GET /api/users -> 200" 200 "$code"
check "users chi tra chinh minh" 1 "$(jlen)"
code=$("${CURL[@]}" -b "$JAR1" -o /dev/null -w '%{http_code}' "$BASE/")
check "GET / (da dang nhap) -> 200" 200 "$code"
code=$("${CURL[@]}" -b "$JAR1" -o /dev/null -w '%{http_code}' "$BASE/login")
check "GET /login (da dang nhap) -> 302" 302 "$code"

echo
echo "== health 2 muc (public, khong can session) =="
code=$(call GET /api/health "")
check "health short keys" "db_user,ok,status" "$(jkeys)"
check "health short ok" "True" "$(jget ok)"
code=$(curl -sS -o "$BODY" -w '%{http_code}' "$DIRECT/api/health?detail=1")
check "health?detail=1 (local) -> 200" 200 "$code"
check "detail co db_host" "True" "$(python3 -c 'import json;print("db_host" in json.load(open("/tmp/cdb-test-body.json")))')"
code=$(curl -sS -o "$BODY" -w '%{http_code}' -H 'X-Forwarded-For: 203.0.113.9' "$DIRECT/api/health?detail=1")
check "detail spoofed remote -> 403" 403 "$code"
check "detail spoofed code" "forbidden" "$(jget code)"

echo
echo "== scope theo session =="
code=$(call GET "/api/tasks?user_id=$u1" "$JAR1")
check "GET tasks user1 -> 200" 200 "$code"
code=$(call GET "/api/tasks?user_id=$u2" "$JAR1")
check "GET tasks user2 bang session user1 -> 403" 403 "$code"
check "403 code" "forbidden_user" "$(jget code)"

echo
echo "== tao + validate =="
code=$(callj POST /api/tasks "$JAR1" "{\"user_id\":$u1,\"title\":\"api test $STAMP\"}")
check "POST task -> 201" 201 "$code"
ID1=$(jget id)
echo "id1=$ID1"
code=$(callj POST /api/tasks "$JAR1" "{\"user_id\":$u1,\"title\":\"   \"}")
check "POST title rong -> 400" 400 "$code"
check "empty title code" "invalid_request" "$(jget code)"
LONG=$(python3 -c 'print("x"*201)')
code=$(callj POST /api/tasks "$JAR1" "{\"user_id\":$u1,\"title\":\"$LONG\"}")
check "POST title 201 ky tu -> 400" 400 "$code"
code=$(callj POST /api/tasks "$JAR1" "{\"user_id\":$u1}")
check "POST thieu title -> 400" 400 "$code"
code=$(callj POST /api/tasks "$JAR1" 'not json')
check "POST body khong phai JSON -> 400" 400 "$code"
code=$(callj POST /api/tasks "$JAR1" "{\"user_id\":$u2,\"title\":\"trom\"}")
check "POST user_id khac session -> 403" 403 "$code"

echo
echo "== patch =="
code=$(callj PATCH "/api/tasks/$ID1" "$JAR1" "{\"user_id\":$u1,\"status\":\"doing\"}")
check "PATCH status -> 200" 200 "$code"
check "PATCH status value" "doing" "$(jget status)"
code=$(callj PATCH "/api/tasks/$ID1" "$JAR1" "{\"user_id\":$u1,\"title\":\"api test renamed $STAMP\"}")
check "PATCH title -> 200" 200 "$code"
check "PATCH title value" "api test renamed $STAMP" "$(jget title)"
code=$(callj PATCH "/api/tasks/$ID1" "$JAR1" "{\"user_id\":$u1,\"status\":\"done\",\"title\":\"both $STAMP\"}")
check "PATCH status+title -> 200" 200 "$code"
check "PATCH status+title value" "both $STAMP" "$(jget title)"
code=$(callj PATCH "/api/tasks/$ID1" "$JAR1" "{\"user_id\":$u1}")
check "PATCH khong co field -> 400" 400 "$code"
code=$(callj PATCH "/api/tasks/$ID1" "$JAR1" "{\"user_id\":$u1,\"status\":\"nope\"}")
check "PATCH status sai -> 400" 400 "$code"
code=$(callj PATCH "/api/tasks/$ID1" "$JAR1" "{\"user_id\":$u1,\"title\":\"\"}")
check "PATCH title rong -> 400" 400 "$code"
code=$(callj PATCH "/api/tasks/999999999" "$JAR1" "{\"user_id\":$u1,\"status\":\"todo\"}")
check "PATCH task khong ton tai -> 404" 404 "$code"
check "PATCH 404 code" "not_found" "$(jget code)"

echo
echo "== quyen so huu (2 session) =="
code=$(login "$EMAIL2" "$PW" "$JAR2")
check "login user2 -> 200" 200 "$code"
code=$(callj PATCH "/api/tasks/$ID1" "$JAR2" "{\"user_id\":$u2,\"status\":\"todo\"}")
check "user2 PATCH task user1 -> 404" 404 "$code"
code=$(call DELETE "/api/tasks/$ID1?user_id=$u2" "$JAR2")
check "user2 DELETE task user1 -> 404" 404 "$code"
code=$(callj PATCH "/api/tasks/$ID1" "$JAR1" "{\"user_id\":$u1,\"status\":\"done\"}")
check "user1 van PATCH duoc task cua minh -> 200" 200 "$code"

echo
echo "== position + timestamps =="
code=$(callj POST /api/tasks "$JAR1" "{\"user_id\":$u1,\"title\":\"order a $STAMP\"}")
check "POST order a -> 201" 201 "$code"
T2=$(jget id)
check "order a position = 0" 0 "$(jget position)"
check "POST tra du field" "created_at,id,position,status,title,updated_at,user_id" "$(jkeys)"
check "created_at ISO co tz" "True" "$(python3 -c 'import datetime,json;print(datetime.datetime.fromisoformat(json.load(open("/tmp/cdb-test-body.json"))["created_at"]).tzinfo is not None)')"
code=$(callj POST /api/tasks "$JAR1" "{\"user_id\":$u1,\"title\":\"order b $STAMP\"}")
check "POST order b -> 201" 201 "$code"
T3=$(jget id)
check "order b position = 1" 1 "$(jget position)"
code=$(callj POST /api/tasks "$JAR1" "{\"user_id\":$u1,\"title\":\"order c $STAMP\"}")
check "POST order c -> 201" 201 "$code"
T4=$(jget id)
check "order c position = 2" 2 "$(jget position)"
code=$(call GET "/api/tasks?user_id=$u1" "$JAR1")
check "GET tasks sau khi tao -> 200" 200 "$code"
check "todo order = a,b,c" "$T2,$T3,$T4" "$(jids todo)"
code=$(callj PATCH "/api/tasks/$T4" "$JAR1" "{\"user_id\":$u1,\"position\":0}")
check "PATCH position 0 -> 200" 200 "$code"
check "PATCH position value = 0" 0 "$(jget position)"
code=$(call GET "/api/tasks?user_id=$u1" "$JAR1")
check "todo order sau reorder = c,a,b" "$T4,$T2,$T3" "$(jids todo)"
code=$(callj PATCH "/api/tasks/$T2" "$JAR1" "{\"user_id\":$u1,\"status\":\"doing\"}")
check "PATCH status sang doing -> 200" 200 "$code"
check "chuyen cot append position = 0" 0 "$(jget position)"
code=$(callj PATCH "/api/tasks/$T3" "$JAR1" "{\"user_id\":$u1,\"title\":\"order b renamed $STAMP\"}")
check "PATCH title cap nhat updated_at -> 200" 200 "$code"
check "updated_at > created_at" "True" "$(python3 -c 'import datetime,json;d=json.load(open("/tmp/cdb-test-body.json"));print(datetime.datetime.fromisoformat(d["updated_at"])>datetime.datetime.fromisoformat(d["created_at"]))')"
code=$(callj PATCH "/api/tasks/$T3" "$JAR1" "{\"user_id\":$u1,\"position\":-1}")
check "PATCH position am -> 400" 400 "$code"
code=$(callj PATCH "/api/tasks/$T3" "$JAR1" "{\"user_id\":$u1,\"position\":\"abc\"}")
check "PATCH position khong phai so -> 400" 400 "$code"
code=$(callj PATCH "/api/tasks/$T3" "$JAR2" "{\"user_id\":$u2,\"position\":0}")
check "user2 PATCH position task user1 -> 404" 404 "$code"
code=$(callj PATCH "/api/tasks/$T3" "$JAR1" "{\"user_id\":$u1,\"position\":999}")
check "PATCH position lon -> 200" 200 "$code"
check "position lon bi clamp = 1" 1 "$(jget position)"

echo
echo "== delete (query string) =="
code=$(call DELETE "/api/tasks/$ID1" "$JAR1")
check "DELETE thieu user_id -> 400" 400 "$code"
code=$(call DELETE "/api/tasks/$ID1?user_id=abc" "$JAR1")
check "DELETE user_id khong phai so -> 400" 400 "$code"
code=$(call DELETE "/api/tasks/$ID1?user_id=$u1" "$JAR1")
check "DELETE task cua minh -> 200" 200 "$code"
code=$(call DELETE "/api/tasks/$ID1?user_id=$u1" "$JAR1")
check "DELETE lai -> 404" 404 "$code"
code=$(call GET "/api/tasks?user_id=$u1" "$JAR1")
check "GET tasks sau delete -> 200" 200 "$code"
check "task da bi xoa" "False" "$(python3 -c 'import json,sys;print(any(t["id"]==int(sys.argv[1]) for t in json.load(open("/tmp/cdb-test-body.json"))))' "$ID1")"

echo
echo "== headers =="
H=$("${CURL[@]}" -b "$JAR1" -o /dev/null -D - "$BASE/api/health")
for h in x-content-type-options x-frame-options referrer-policy content-security-policy cache-control; do
  if echo "$H" | grep -qi "^$h:"; then
    PASS=$((PASS + 1)); printf 'PASS | header %-38s | present\n' "$h"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL | header %-38s | missing\n' "$h"
  fi
done
H=$("${CURL[@]}" -o /dev/null -D - -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL1\",\"password\":\"$PW\"}" "$BASE/api/login")
if echo "$H" | grep -qi '^set-cookie:.*cdb_session='; then
  PASS=$((PASS + 1)); printf 'PASS | %-46s | present\n' "session cookie duoc set"
else
  FAIL=$((FAIL + 1)); printf 'FAIL | %-46s | missing\n' "session cookie duoc set"
fi
for attr in httponly samesite=lax secure; do
  if echo "$H" | grep -qi "^set-cookie:.*$attr"; then
    PASS=$((PASS + 1)); printf 'PASS | cookie %-38s | present\n' "$attr"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL | cookie %-38s | missing\n' "$attr"
  fi
done

echo
echo "== logout =="
code=$(call POST /api/logout "$JAR1")
check "POST /api/logout -> 200" 200 "$code"
code=$(call GET /api/me "$JAR1")
check "GET /api/me sau logout -> 401" 401 "$code"

echo
echo "== khong con rate limit ghi: 70 POST lien tiep =="
code=$(login "$EMAIL1" "$PW" "$JAR2")
check "login lai user1 -> 200" 200 "$code"
write_burst=$(for i in $(seq 1 70); do
  "${CURL[@]}" -b "$JAR2" -o /dev/null -w '%{http_code}\n' -X POST \
    -H 'Content-Type: application/json' -d '{}' "$BASE/api/tasks"
done | sort | uniq -c)
echo "$write_burst" | sed 's/^/burst /'
check "70 POST lien tiep khong co 429" 0 "$(echo "$write_burst" | grep -c ' 429$')"
check "70 POST lien tiep khong co 5xx" 0 "$(echo "$write_burst" | grep -cE ' 5[0-9][0-9]$')"

echo
echo "== don tai khoan test =="
cleanup_accounts

echo
echo "== summary =="
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
