#!/usr/bin/env python3
"""CI smoke test for the Flask app using a real PostgreSQL database.

Runs the app through Flask's test client instead of a live HTTP server, so CI
does not need gunicorn or Caddy. The GitHub Actions workflow starts postgres:17,
applies infra/setup/schema.sql, creates app_user, then runs this file.

Required env: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, APP_SECRET_KEY.
DB_SSLMODE=disable is fine for the CI service container.
"""

import importlib.util
import os
import pathlib
import sys
import time
import traceback
from datetime import datetime

HERE = pathlib.Path(__file__).resolve()
ROOT = HERE.parents[2] if len(HERE.parents) > 2 else HERE.parent
APP_PATH = pathlib.Path(os.environ.get("CDB_APP_PATH") or (ROOT / "app" / "app.py"))

PASSED = 0
FAILED = []


def expect(condition, label):
    global PASSED
    if condition:
        PASSED += 1
        print("PASS", label)
    else:
        FAILED.append(label)
        print("FAIL", label)


def load_app():
    spec = importlib.util.spec_from_file_location("cdb_ci_app", APP_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["cdb_ci_app"] = module
    spec.loader.exec_module(module)
    module.app.config.update(TESTING=True, SESSION_COOKIE_SECURE=False)
    return module


def parse_ts(value):
    return datetime.fromisoformat(value)


def main():
    mod = load_app()
    app = mod.app
    client = app.test_client()
    stamp = str(int(time.time() * 1000))
    email = "ci-" + stamp + "@local.test"
    password = "Ci-Pass-" + stamp
    uid = None
    created_ids = []

    try:
        # --- anonymous access ---
        r = client.get("/api/tasks?user_id=1")
        expect(r.status_code == 401, "anonymous /api/tasks -> 401")
        r = client.get("/")
        expect(
            r.status_code == 302 and "/login" in r.headers.get("Location", ""),
            "anonymous / -> 302 /login",
        )
        r = client.get("/login")
        expect(r.status_code == 200, "login page -> 200")
        r = client.get("/register")
        expect(r.status_code == 200, "register page -> 200")
        r = client.get("/app.css")
        expect(r.status_code == 200, "app.css -> 200")
        r = client.get("/app.js")
        expect(r.status_code == 200, "app.js -> 200")

        # --- register ---
        r = client.post("/api/register", json={"email": email, "password": password})
        expect(r.status_code == 201, "register -> 201")
        body = r.get_json()
        expect(body["user"]["email"] == email, "register returns email")
        uid = body["user"]["id"]

        r = client.post("/api/register", json={"email": email.upper(), "password": password})
        expect(r.status_code == 409, "duplicate register (case-insensitive) -> 409")

        r = client.get("/api/me")
        expect(r.status_code == 200 and r.get_json()["user"]["id"] == uid, "/api/me -> current user")

        # --- create + ordering ---
        titles = ["ci alpha", "ci beta", "ci gamma"]
        for index, title in enumerate(titles):
            r = client.post("/api/tasks", json={"user_id": uid, "title": title})
            body = r.get_json()
            expect(r.status_code == 201, "create task %d -> 201" % index)
            expect(body["status"] == "todo", "new task %d status=todo" % index)
            expect(body["position"] == index, "new task %d position=%d" % (index, index))
            created_ids.append(body["id"])

        r = client.get("/api/tasks?user_id=%d" % uid)
        rows = r.get_json()
        expect([t["id"] for t in rows] == created_ids, "list keeps creation order")
        expect([t["position"] for t in rows] == [0, 1, 2], "list positions 0,1,2")

        # --- validation + auth boundaries ---
        r = client.get("/api/tasks?user_id=%d" % (uid + 1))
        expect(r.status_code == 403, "other user_id -> 403")
        r = client.post("/api/tasks", json={"user_id": uid, "title": "   "})
        expect(r.status_code == 400, "blank title -> 400")
        r = client.post("/api/tasks", json={"user_id": uid, "title": "x" * 201})
        expect(r.status_code == 400, "title > 200 chars -> 400")
        r = client.patch("/api/tasks/%d" % created_ids[0], json={"user_id": uid})
        expect(r.status_code == 400, "empty patch -> 400")
        r = client.patch(
            "/api/tasks/%d" % created_ids[0],
            json={"user_id": uid, "status": "nope"},
        )
        expect(r.status_code == 400, "invalid status -> 400")
        r = client.patch(
            "/api/tasks/%d" % created_ids[0],
            json={"user_id": uid, "position": -1},
        )
        expect(r.status_code == 400, "negative position -> 400")
        r = client.patch(
            "/api/tasks/%d" % created_ids[0],
            json={"user_id": uid + 1, "title": "hijack"},
        )
        expect(r.status_code == 403, "patch with wrong user_id -> 403")

        # --- timestamps ---
        created_at = parse_ts(rows[0]["created_at"])
        updated_at = parse_ts(rows[0]["updated_at"])
        expect(updated_at >= created_at, "created_at <= updated_at")
        time.sleep(0.02)
        r = client.patch(
            "/api/tasks/%d" % created_ids[0],
            json={"user_id": uid, "title": "ci alpha renamed"},
        )
        body = r.get_json()
        expect(r.status_code == 200, "rename -> 200")
        expect(body["title"] == "ci alpha renamed", "rename persisted")
        expect(
            parse_ts(body["updated_at"]) > updated_at,
            "update bumps updated_at",
        )
        expect(
            parse_ts(body["created_at"]) == created_at,
            "update keeps created_at",
        )

        # --- reorder inside a column ---
        r = client.patch(
            "/api/tasks/%d" % created_ids[2],
            json={"user_id": uid, "position": 0},
        )
        expect(r.status_code == 200, "move gamma to position 0 -> 200")
        r = client.get("/api/tasks?user_id=%d" % uid)
        rows = r.get_json()
        expect(
            [t["id"] for t in rows] == [created_ids[2], created_ids[0], created_ids[1]],
            "todo order is gamma, alpha, beta",
        )
        expect([t["position"] for t in rows] == [0, 1, 2], "todo positions renumbered")

        # --- move across columns ---
        r = client.patch(
            "/api/tasks/%d" % created_ids[0],
            json={"user_id": uid, "status": "doing"},
        )
        expect(r.status_code == 200 and r.get_json()["status"] == "doing", "alpha -> doing")
        r = client.get("/api/tasks?user_id=%d" % uid)
        rows = r.get_json()
        todo = [t for t in rows if t["status"] == "todo"]
        doing = [t for t in rows if t["status"] == "doing"]
        expect([t["id"] for t in todo] == [created_ids[2], created_ids[1]], "todo shrinks")
        expect([t["position"] for t in todo] == [0, 1], "todo renumbered after move")
        expect([t["id"] for t in doing] == [created_ids[0]], "doing receives alpha")
        expect([t["position"] for t in doing] == [0], "doing position starts at 0")

        r = client.patch(
            "/api/tasks/%d" % created_ids[1],
            json={"user_id": uid, "status": "done", "position": 0},
        )
        expect(r.status_code == 200, "beta -> done position 0 -> 200")
        r = client.get("/api/tasks?user_id=%d" % uid)
        rows = r.get_json()
        by_status = {}
        for t in rows:
            by_status.setdefault(t["status"], []).append(t["id"])
        expect(by_status.get("todo") == [created_ids[2]], "todo left with gamma")
        expect(by_status.get("doing") == [created_ids[0]], "doing keeps alpha")
        expect(by_status.get("done") == [created_ids[1]], "done has beta")

        # --- delete ---
        r = client.delete("/api/tasks/%d?user_id=%d" % (created_ids[2], uid))
        expect(r.status_code == 200, "delete gamma -> 200")
        created_ids.remove(created_ids[2])
        r = client.delete("/api/tasks/999999999?user_id=%d" % uid)
        expect(r.status_code == 404, "delete unknown -> 404")

        # --- session lifecycle ---
        r = client.post("/api/logout")
        expect(r.status_code == 200, "logout -> 200")
        r = client.get("/api/me")
        expect(r.status_code == 401, "after logout /api/me -> 401")
        r = client.post("/api/login", json={"email": email, "password": "wrong-password"})
        expect(r.status_code == 401, "wrong password -> 401")
        r = client.post("/api/login", json={"email": email, "password": password})
        expect(r.status_code == 200, "login -> 200")
        r = client.get("/api/me")
        expect(r.status_code == 200, "session restored after login")

        # --- cache-busted assets ---
        html_first = client.get("/").get_data(as_text=True)
        expect("?v=" in html_first, "index HTML versions app.css/app.js")
        expect(client.get("/").get_data(as_text=True) == html_first, "asset version is stable")

        # --- health ---
        r = client.get("/api/health")
        body = r.get_json()
        expect(r.status_code == 200 and body.get("ok") is True, "health -> ok")
        expect(body.get("db_user") == os.environ["DB_USER"], "health db_user matches DB_USER")
        r = client.get("/api/health?detail=1")
        expect(r.status_code == 200, "local health detail -> 200")
        expect(r.get_json().get("database") is not None, "health detail exposes database locally")

        # --- check-domain (on-demand tls ask endpoint) ---
        r = client.get("/api/check-domain")
        expect(r.status_code == 403, "check-domain without param -> 403")
        r = client.get("/api/check-domain?domain=evil.com")
        expect(r.status_code == 403, "check-domain unauthorized host -> 403")
        current_domain = os.environ.get("DOMAIN", "localhost")
        os.environ["DOMAIN"] = "kanban.example.com"
        r = client.get("/api/check-domain?domain=kanban.example.com")
        expect(r.status_code == 200, "check-domain allowed DOMAIN -> 200")
        r = client.get("/api/check-domain?domain=kanban.example.com:443")
        expect(r.status_code == 200, "check-domain allowed DOMAIN with port -> 200")
        r = client.get("/api/check-domain?domain=sub.kanban.example.com")
        expect(r.status_code == 403, "check-domain mismatched sub-host -> 403")
        os.environ["DOMAIN"] = current_domain

    finally:
        # Always remove this run's rows so reruns stay clean.
        try:
            with mod.pool.connection() as conn:
                with conn.cursor() as cur:
                    if uid is not None:
                        cur.execute("DELETE FROM tasks WHERE user_id = %s", (uid,))
                        cur.execute("DELETE FROM users WHERE id = %s", (uid,))
                conn.commit()
            with mod.pool.connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT count(*) FROM users WHERE email LIKE 'ci-%@local.test'"
                    )
                    leftover = cur.fetchone()[0]
            expect(leftover == 0, "no leftover ci-* users")
        except Exception:
            traceback.print_exc()
            FAILED.append("cleanup")

    print("\n== summary ==")
    print("pass=%d fail=%d" % (PASSED, len(FAILED)))
    if FAILED:
        for label in FAILED:
            print("FAILED:", label)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
