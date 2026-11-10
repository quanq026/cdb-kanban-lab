# Persistence - xoa container, giu volume, tao lai

- Thoi diem chay: `2026-11-09T09:48:06+00:00`

## Du lieu TRUOC khi xoa container

```text
users=2 tasks=5
md5(users)=d2f198dbac7c784edb5dace18d85af21
md5(tasks)=aaaaa7a6658f216d9461a9bfe097eedf
```

## Xoa container (volume cdb-study-data duoc giu)

```bash
docker rm -f cdb-study
docker volume ls --filter name=cdb-study-data
```

```text
cdb-study
DRIVER    VOLUME NAME
local     cdb-study-data
```

## Tao lai container tren cung volume

```bash
docker run -d --name cdb-study --restart unless-stopped \
  -e POSTGRES_PASSWORD=$PG_SUPER_PASSWORD (lay tu /etc/cdb/secrets.env) \
  -e POSTGRES_DB=studydb -p 127.0.0.1:55432:5432 \
  -v cdb-study-data:/var/lib/postgresql/data postgres:17
```

```text
/var/run/postgresql:5432 - accepting connections
```

## Du lieu SAU khi tao lai

```text
users=2 tasks=5
md5(users)=d2f198dbac7c784edb5dace18d85af21
md5(tasks)=aaaaa7a6658f216d9461a9bfe097eedf
```

## Role app_user van con

```text
app_user|t|f
```

## app_user van dang nhap duoc

```bash
PGPASSWORD=<local app password> psql "host=127.0.0.1 port=55432 dbname=studydb user=app_user sslmode=disable" -c "SELECT current_user"
```

```text
app_user|5
```

## Ket luan

Du lieu, role va mat khau cua `app_user` nam trong volume `cdb-study-data`, nen xoa/tao lai container khong mat gi. Gioi han: neu volume hoac VM bi xoa thi mat (xem backup-restore.md).
