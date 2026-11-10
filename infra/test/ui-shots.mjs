import { spawn } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const URL_PAGE = process.env.SHOT_URL || "https://kanban.akaine.io.vn/";
const OUT_DIR = process.argv[2] || "docs/evidence/images";
const CHROME = process.env.CHROME_PATH || "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const PORT = 9300 + Math.floor(Math.random() * 400);
const PROFILE = join(tmpdir(), "cdb-shots-" + Date.now());

const STAMP = Date.now();
const SHOT_EMAIL = "shot+" + STAMP + "@local.test";
const SHOT_PASS = "Shot" + STAMP + "Aa1";

const TASKS = [
  { title: "Chuẩn bị nội dung họp tuần", status: "todo" },
  { title: "Rà soát hợp đồng dịch vụ", status: "doing" },
  { title: "Gửi báo cáo tiến độ", status: "done" },
];

const shots = [
  { file: "ui-login-light.png", width: 1440, height: 900, mobile: false, scheme: "light", kind: "auth", page: "/login" },
  { file: "ui-register-light.png", width: 1440, height: 900, mobile: false, scheme: "light", kind: "auth", page: "/register" },
  { file: "ui-empty-light.png", width: 1440, height: 1000, mobile: false, scheme: "light", kind: "empty", page: "/" },
  { file: "ui-desktop-light.png", width: 1440, height: 1000, mobile: false, scheme: "light", kind: "board", page: "/" },
  { file: "ui-desktop-dark.png", width: 1440, height: 1000, mobile: false, scheme: "dark", kind: "board", page: "/" },
  { file: "ui-menu-light.png", width: 1440, height: 1000, mobile: false, scheme: "light", kind: "menu", page: "/" },
  { file: "ui-mobile-light.png", width: 375, height: 880, mobile: true, scheme: "light", kind: "board", page: "/" },
  { file: "ui-mobile-dark.png", width: 375, height: 880, mobile: true, scheme: "dark", kind: "board", page: "/" },
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitEndpoint() {
  for (let i = 0; i < 100; i += 1) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json/version`);
      if (res.ok) return await res.json();
    } catch {}
    await sleep(100);
  }
  throw new Error("chrome devtools endpoint did not start");
}

const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--hide-scrollbars",
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${PROFILE}`,
  ],
  { stdio: "ignore" }
);

try {
  const version = await waitEndpoint();
  const ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });

  let nextId = 0;
  const pending = new Map();
  ws.addEventListener("message", (event) => {
    const msg = JSON.parse(event.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    }
  });

  const send = (method, params = {}, sessionId) => {
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  };

  const evaluate = async (sessionId, expression) => {
    const res = await send(
      "Runtime.evaluate",
      { expression, returnByValue: true, awaitPromise: true },
      sessionId
    );
    return res.result.value;
  };

  mkdirSync(OUT_DIR, { recursive: true });
  const results = [];
  let registered = false;
  let tasksReady = false;

  for (const shot of shots) {
    const { targetId } = await send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
    await send("Page.enable", {}, sessionId);
    await send("Emulation.setDeviceMetricsOverride",
      { width: shot.width, height: shot.height, deviceScaleFactor: 1, mobile: shot.mobile },
      sessionId);
    await send("Emulation.setEmulatedMedia",
      { media: "", features: [{ name: "prefers-color-scheme", value: shot.scheme }] },
      sessionId);
    await send("Page.navigate", { url: URL_PAGE + shot.page.slice(1) }, sessionId);
    await sleep(350);

    if (shot.kind === "auth") {
      let ready = false;
      for (let i = 0; i < 100; i += 1) {
        await sleep(120);
        ready = await evaluate(sessionId, `!!document.querySelector("form") && !!document.querySelector(".auth-card")`).catch(() => false);
        if (ready) break;
      }
      if (!ready) throw new Error("auth page did not render for " + shot.file);
    } else {
      if (!registered) {
        const status = await evaluate(sessionId, `fetch("/api/register", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ email: ${JSON.stringify(SHOT_EMAIL)}, password: ${JSON.stringify(SHOT_PASS)} })
        }).then((r) => r.status)`).catch(() => 0);
        if (status !== 201) throw new Error("register failed with status " + status);
        registered = true;
        await send("Page.navigate", { url: URL_PAGE }, sessionId);
        await sleep(600);
      }
      if (shot.kind === "board" && !tasksReady) {
        const info = await evaluate(sessionId, `(async () => {
          const me = await fetch("/api/me").then((r) => r.json());
          const rows = [];
          for (const t of ${JSON.stringify(TASKS)}) {
            const created = await fetch("/api/tasks", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ user_id: me.user.id, title: t.title })
            }).then((r) => r.json());
            if (t.status !== "todo") {
              await fetch("/api/tasks/" + created.id, {
                method: "PATCH",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ user_id: me.user.id, status: t.status })
              });
            }
            rows.push(created.id);
          }
          return rows;
        })()`).catch(() => []);
        if (!info || info.length !== TASKS.length) throw new Error("could not create sample tasks");
        tasksReady = true;
        await send("Page.navigate", { url: URL_PAGE }, sessionId);
        await sleep(600);
      }

      const waitFor = shot.kind === "empty"
        ? `!document.querySelector(".skel") && document.querySelectorAll(".empty").length === 3`
        : `document.querySelectorAll(".task").length === ${TASKS.length}`;

      let ready = false;
      for (let i = 0; i < 140; i += 1) {
        await sleep(150);
        ready = await evaluate(sessionId, waitFor).catch(() => false);
        if (ready) break;
      }
      if (!ready) throw new Error("board did not become ready for " + shot.file);
    }

    await sleep(400);
    if (shot.kind === "menu") {
      await evaluate(sessionId, `document.getElementById("account-toggle").click()`);
      await sleep(250);
    }
    const meta = await evaluate(sessionId, shot.kind === "auth" ? `(() => ({
      path: location.pathname,
      scheme: matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light",
      bg: getComputedStyle(document.body).backgroundColor,
      width: innerWidth
    }))()` : `(() => ({
      path: location.pathname,
      counts: ["todo","doing","done"].map(s => document.getElementById("count-"+s).textContent).join("/"),
      avatar: document.getElementById("avatar").textContent,
      menuOpen: !document.getElementById("account-menu").hidden,
      hasFooter: !!document.getElementById("footer"),
      scheme: matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light",
      bg: getComputedStyle(document.body).backgroundColor,
      width: innerWidth
    }))()`);
    const { data } = await send("Page.captureScreenshot", { format: "png" }, sessionId);
    const path = join(OUT_DIR, shot.file);
    writeFileSync(path, Buffer.from(data, "base64"));
    results.push({ file: path, bytes: Buffer.from(data, "base64").length, ready: true, meta });
    await send("Target.closeTarget", { targetId });
  }

  ws.close();
  console.log(JSON.stringify({ account: SHOT_EMAIL, shots: results }, null, 2));
} finally {
  chrome.kill();
}
