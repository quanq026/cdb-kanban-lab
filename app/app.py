import logging
import os
import re
import time
from datetime import timedelta

from flask import Flask, g, jsonify, redirect, request, send_from_directory, session
from psycopg import OperationalError
from psycopg import errors as pg_errors
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from werkzeug.exceptions import HTTPException
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash, generate_password_hash

APP_DIR = os.path.dirname(os.path.abspath(__file__))
STATUSES = ("todo", "doing", "done")
MAX_TITLE = 200
MAX_PASSWORD = 200
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
LOCAL_IPS = ("127.0.0.1", "::1")
PUBLIC_PATHS = frozenset((
    "/login", "/register", "/app.css", "/app.js", "/favicon.ico",
    "/api/login", "/api/register", "/api/health",
))
CSP = (
    "default-src 'self'; img-src 'self' data:; style-src 'self'; "
    "script-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; "
    "form-action 'self'; frame-ancestors 'self'"
)


def _env(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        raise RuntimeError("missing required env var: " + name)
    return value


CONN_INFO = {
    "host": _env("DB_HOST"),
    "port": int(os.environ.get("DB_PORT", "5432")),
    "dbname": _env("DB_NAME"),
    "user": _env("DB_USER"),
    "password": _env("DB_PASSWORD"),
    "sslmode": os.environ.get("DB_SSLMODE", "verify-full"),
    "sslrootcert": os.environ.get("DB_SSLROOTCERT", "system"),
    "connect_timeout": 15,
    "application_name": "cdb-kanban",
}

pool = ConnectionPool(
    kwargs=CONN_INFO,
    min_size=1,
    max_size=5,
    timeout=20,
    max_idle=120,
    max_lifetime=1800,
    reconnect_timeout=30,
    check=ConnectionPool.check_connection,
    open=False,
)
pool.open()

app = Flask(__name__, static_folder=APP_DIR, static_url_path="")
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)
app.secret_key = _env("APP_SECRET_KEY")
app.config.update(
    SESSION_COOKIE_NAME="cdb_session",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=True,
    PERMANENT_SESSION_LIFETIME=timedelta(hours=12),
)
app.logger.setLevel(logging.INFO)

DUMMY_HASH = generate_password_hash("cdb-kanban-dummy")


def q_all(sql, params=()):
    for attempt in (1, 2):
        try:
            with pool.connection() as conn:
                with conn.cursor(row_factory=dict_row) as cur:
                    cur.execute(sql, params)
                    return cur.fetchall()
        except OperationalError:
            if attempt == 2:
                raise


def q_one(sql, params=()):
    for attempt in (1, 2):
        try:
            with pool.connection() as conn:
                with conn.cursor(row_factory=dict_row) as cur:
                    cur.execute(sql, params)
                    row = cur.fetchone()
                conn.commit()
                return row
        except OperationalError:
            if attempt == 2:
                raise


def as_int(value, field):
    try:
        return int(value)
    except (TypeError, ValueError):
        raise ValueError("%s must be an integer" % field)


def payload():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        raise ValueError("body must be a JSON object")
    return data


def clean_title(value):
    if not isinstance(value, str):
        raise ValueError("title must be a string")
    title = value.strip()
    if not title:
        raise ValueError("title must not be empty")
    if len(title) > MAX_TITLE:
        raise ValueError("title must be at most %d characters" % MAX_TITLE)
    return title


def clean_status(value):
    if value not in STATUSES:
        raise ValueError("status must be one of: " + ", ".join(STATUSES))
    return value


def clean_email(value):
    if not isinstance(value, str):
        raise ValueError("email must be a string")
    email = value.strip().lower()
    if len(email) > 254 or not EMAIL_RE.match(email):
        raise ValueError("email khong hop le")
    return email


def clean_password(value):
    if not isinstance(value, str):
        raise ValueError("password must be a string")
    if len(value) < 8:
        raise ValueError("mat khau phai co it nhat 8 ky tu")
    if len(value) > MAX_PASSWORD:
        raise ValueError("mat khau qua dai")
    return value


def fail(status, message, code):
    return jsonify(error=message, code=code), status


def session_user():
    uid = session.get("uid")
    if not uid:
        return None
    return {"id": uid, "email": session.get("email", "")}


def same_user(user_id):
    current = session_user()
    if current is None:
        return fail(401, "can dang nhap", "unauthenticated")
    if user_id != current["id"]:
        return fail(403, "user_id khong khop phien dang nhap", "forbidden_user")
    return None


@app.before_request
def before_request():
    g.t0 = time.perf_counter()
    path = request.path
    if path in PUBLIC_PATHS:
        if path in ("/login", "/register") and session.get("uid"):
            return redirect("/")
        return None
    if not session.get("uid"):
        if path.startswith("/api/"):
            return fail(401, "can dang nhap", "unauthenticated")
        return redirect("/login")
    if path == "/" and session.get("uid"):
        return None


@app.after_request
def after_request(resp):
    elapsed_ms = (time.perf_counter() - getattr(g, "t0", time.perf_counter())) * 1000
    app.logger.info(
        "%s %s %s %.1fms ip=%s uid=%s",
        request.method,
        request.path,
        resp.status_code,
        elapsed_ms,
        request.remote_addr,
        session.get("uid", "-"),
    )
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "SAMEORIGIN"
    resp.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    resp.headers["Permissions-Policy"] = "geolocation=(), microphone=(), camera=()"
    resp.headers["Content-Security-Policy"] = CSP
    if request.path.startswith("/api/") or request.path in ("/", "/login", "/register"):
        resp.headers["Cache-Control"] = "no-store"
    elif request.path in ("/app.css", "/app.js"):
        resp.headers["Cache-Control"] = "no-cache"
    return resp


@app.errorhandler(ValueError)
def on_value_error(err):
    return fail(400, str(err), "invalid_request")


@app.errorhandler(pg_errors.CheckViolation)
def on_check_violation(err):
    return fail(400, "du lieu khong hop le", "check_violation")


@app.errorhandler(pg_errors.UniqueViolation)
def on_unique_violation(err):
    return fail(409, "du lieu da ton tai", "unique_violation")


@app.errorhandler(pg_errors.ForeignKeyViolation)
def on_foreign_key(err):
    return fail(400, "user_id khong ton tai", "foreign_key_violation")


@app.errorhandler(OperationalError)
def on_operational(err):
    app.logger.warning("db unavailable: %s", type(err).__name__)
    return fail(503, "co so du lieu tam thoi khong san sang", "db_unavailable")


@app.errorhandler(pg_errors.Error)
def on_db_error(err):
    app.logger.error("db error: %s", type(err).__name__)
    return fail(500, "loi co so du lieu", "db_error")


@app.errorhandler(HTTPException)
def on_http_error(err):
    if request.path.startswith("/api/"):
        return fail(err.code or 500, err.description or "request failed", "http_%s" % (err.code or 500))
    return err


@app.errorhandler(Exception)
def on_unexpected(err):
    app.logger.exception("unhandled error")
    return fail(500, "loi may chu", "internal_error")


@app.get("/")
def index():
    return send_from_directory(APP_DIR, "index.html")


@app.get("/login")
def login_page():
    return send_from_directory(APP_DIR, "login.html")


@app.get("/register")
def register_page():
    return send_from_directory(APP_DIR, "register.html")


@app.get("/favicon.ico")
def favicon():
    return "", 204


@app.post("/api/register")
def register():
    data = payload()
    email = clean_email(data.get("email"))
    password = clean_password(data.get("password"))
    row = q_one(
        "INSERT INTO users (email, password_hash) VALUES (%s, %s) RETURNING id, email",
        (email, generate_password_hash(password)),
    )
    session.clear()
    session.permanent = True
    session["uid"] = row["id"]
    session["email"] = row["email"]
    return jsonify(user=row), 201


@app.post("/api/login")
def login():
    data = payload()
    email = data.get("email")
    password = data.get("password")
    if not isinstance(email, str) or not isinstance(password, str) or not email.strip() or not password:
        raise ValueError("email and password are required")
    rows = q_all(
        "SELECT id, email, password_hash FROM users WHERE lower(email) = lower(%s)",
        (email.strip(),),
    )
    stored = rows[0]["password_hash"] if rows else None
    candidate = stored or DUMMY_HASH
    valid = check_password_hash(candidate, password)
    if not rows or not stored or not valid:
        app.logger.warning("login failed ip=%s", request.remote_addr)
        return fail(401, "email hoac mat khau khong dung", "invalid_credentials")
    user = {"id": rows[0]["id"], "email": rows[0]["email"]}
    session.clear()
    session.permanent = True
    session["uid"] = user["id"]
    session["email"] = user["email"]
    return jsonify(user=user)


@app.post("/api/logout")
def logout():
    session.clear()
    return jsonify(ok=True)


@app.get("/api/me")
def me():
    current = session_user()
    row = q_one("SELECT id, email FROM users WHERE id = %s", (current["id"],))
    if row is None:
        session.clear()
        return fail(401, "phien khong con hop le", "unauthenticated")
    return jsonify(user=row)


@app.get("/api/users")
def list_users():
    current = session_user()
    return jsonify(q_all("SELECT id, email FROM users WHERE id = %s", (current["id"],)))


@app.get("/api/tasks")
def list_tasks():
    user_id = as_int(request.args.get("user_id"), "user_id")
    denied = same_user(user_id)
    if denied:
        return denied
    rows = q_all(
        "SELECT id, user_id, title, status FROM tasks WHERE user_id = %s ORDER BY id",
        (user_id,),
    )
    return jsonify(rows)


@app.post("/api/tasks")
def create_task():
    data = payload()
    user_id = as_int(data.get("user_id"), "user_id")
    denied = same_user(user_id)
    if denied:
        return denied
    title = clean_title(data.get("title"))
    row = q_one(
        "INSERT INTO tasks (user_id, title) VALUES (%s, %s)"
        " RETURNING id, user_id, title, status",
        (user_id, title),
    )
    return jsonify(row), 201


@app.patch("/api/tasks/<int:task_id>")
def update_task(task_id):
    data = payload()
    user_id = as_int(data.get("user_id"), "user_id")
    denied = same_user(user_id)
    if denied:
        return denied
    sets = []
    params = []
    if "status" in data:
        sets.append("status = %s")
        params.append(clean_status(data.get("status")))
    if "title" in data:
        sets.append("title = %s")
        params.append(clean_title(data.get("title")))
    if not sets:
        raise ValueError("nothing to update")
    params.extend((task_id, user_id))
    row = q_one(
        "UPDATE tasks SET " + ", ".join(sets) + " WHERE id = %s AND user_id = %s"
        " RETURNING id, user_id, title, status",
        tuple(params),
    )
    if row is None:
        return fail(404, "task not found for this user", "not_found")
    return jsonify(row)


@app.delete("/api/tasks/<int:task_id>")
def delete_task(task_id):
    user_id = as_int(request.args.get("user_id"), "user_id")
    denied = same_user(user_id)
    if denied:
        return denied
    row = q_one("DELETE FROM tasks WHERE id = %s AND user_id = %s RETURNING id", (task_id, user_id))
    if row is None:
        return fail(404, "task not found for this user", "not_found")
    return jsonify(row)


@app.get("/api/health")
def health():
    if request.args.get("detail") == "1":
        if request.remote_addr not in LOCAL_IPS:
            return fail(403, "detail is local only", "forbidden")
        detail = True
    else:
        detail = False
    try:
        row = q_all(
            "SELECT current_user AS db_user, current_database() AS database,"
            " inet_server_addr()::text AS backend_addr"
        )[0]
    except OperationalError:
        return (
            jsonify(
                status="error",
                db_user=None,
                ok=False,
                error="co so du lieu tam thoi khong san sang",
                code="db_unavailable",
            ),
            503,
        )
    if not detail:
        return jsonify(status="ok", db_user=row["db_user"], ok=True)
    row.update(status="ok", ok=True, db_host=CONN_INFO["host"], sslmode=CONN_INFO["sslmode"])
    return jsonify(row)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000)
