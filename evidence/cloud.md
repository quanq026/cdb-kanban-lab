# Cloud - Neon PostgreSQL 17

- Thoi diem chay: `2026-11-09T09:49:20+00:00`
- Endpoint truc tiep: `ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech:5432` (project `icy-sound-48483515`, region aws-ap-southeast-1)
- Endpoint pooled: `ep-ancient-bread-a13k7y58-pooler.ap-southeast-1.aws.neon.tech:5432` (dung cho app neu can; app hien dung endpoint truc tiep)

## 1. psql toi Neon bang TLS verify-full

```bash
psql "host=<endpoint> port=5432 dbname=studydb user=app_user sslmode=verify-full sslrootcert=system"
```

Chung chi server (Let's Encrypt, khop hostname):

```text
subject=CN = *.ap-southeast-1.aws.neon.tech
issuer=C = US, O = Let's Encrypt, CN = YR1
notBefore=Oct 19 18:02:38 2026 GMT
notAfter=Jan 17 18:02:37 2027 GMT
```

Ket qua ket noi:

```text
You are connected to database "studydb" as user "app_user" on host "ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech" (address "13.228.184.177") at port "5432".
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off, ALPN: postgresql)
```

## 2. Them task tu web (qua nginx :80) roi kiem tra trong DB

```bash
curl -sS -X POST http://20.48.104.156/api/tasks -H "Content-Type: application/json" -d "{\"user_id\":1,\"title\":\"Task tu web truoc khi restart\"}"
```

```text
{"id":36,"status":"todo","title":"Task tu web truoc khi restart","user_id":1}

```

Kiem tra bang SQL doc lap (khong qua app):

```text
 id | user_id |             title             | status 
----+---------+-------------------------------+--------
 36 |       1 | Task tu web truoc khi restart | todo
(1 row)

```

## 3. Restart backend, task van con

```bash
sudo systemctl restart cdb-kanban
sleep 3
curl -sS http://20.48.104.156/api/tasks?user_id=1
```

```text
active
[{"id":1,"status":"todo","title":"So\u1ea1n \u0111\u1ec1 c\u01b0\u01a1ng b\u00e1o c\u00e1o","user_id":1},{"id":2,"status":"doing","title":"N\u1ed9p b\u00e0i t\u1eadp tu\u1ea7n 3","user_id":1},{"id":3,"status":"done","title":"C\u00e0i PostgreSQL 17","user_id":1},{"id":35,"status":"todo","title":"Tao tu trinh duyet","user_id":1},{"id":36,"status":"todo","title":"Task tu web truoc khi restart","user_id":1}]

```

Task `Task tu web truoc khi restart` van nam trong danh sach sau khi tien trinh bi kill va khoi dong lai -> du lieu that su nam o Neon, khong phai trong bo nho app.

## 4. Sai mat khau -> loi xac thuc (khong lo mat khau)

```bash
PGPASSWORD=<sai> psql "host=<endpoint> dbname=studydb user=app_user sslmode=verify-full sslrootcert=system" -c "SELECT 1"
```

```text
psql: error: connection to server at "ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech" (52.220.170.93), port 5432 failed: ERROR:  password authentication failed for user 'app_user'
```

Kiem tra log khong chua mat khau that (dem so lan xuat hien):

```bash
sudo journalctl -u cdb-kanban --since "-30 min" | grep -cF "$NEON_APP_PASSWORD"
sudo grep -rcF "$NEON_APP_PASSWORD" /var/log/nginx/
```

```text
journalctl_matches=0
nginx_matches=0
```

## 5. Xac nhan app dung app_user

```bash
curl -sS http://20.48.104.156/api/health
```

```text
{"backend_addr":"169.254.254.254/32","database":"studydb","db_host":"ep-ancient-bread-a13k7y58.ap-southeast-1.aws.neon.tech","db_user":"app_user","sslmode":"verify-full"}
```

Va phia database (nhin tu pg_stat_activity cua chinh app):

```text
 usename  | application_name | client_addr | state  | count 
----------+------------------+-------------+--------+-------
 app_user | cdb-kanban       | 10.9.12.116 | idle   |     1
 app_user | cdb-kanban       | 10.9.58.101 | idle   |     1
 app_user | psql             | 10.9.14.104 | active |     1
 app_user | psql             | ::1         | idle   |     1
(4 rows)

```

## Ghi chu ve TLS

- App dung `sslmode=verify-full` + `sslrootcert=/etc/ssl/certs/ca-certificates.crt` (khong tat xac minh).
- `pg_stat_ssl` tren compute node tra `ssl=f` vi Neon ket thuc TLS tai proxy; phia client van xac minh chung chi that (verify-full khong cho phep ket noi khong ma hoa).
- Endpoint pooled (`-pooler`) da test ket noi duoc; neu dung pooled thi khong dung duoc prepared statement phien dai / LISTEN-NOTIFY, app hien tai khong can.
