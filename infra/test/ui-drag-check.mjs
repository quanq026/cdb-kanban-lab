import { spawn } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BASE = process.env.SHOT_URL || "https://kanban.akaine.io.vn";
const CHROME = process.env.CHROME_PATH || "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const OUT = process.argv[2] || "docs/evidence/images/ui-drag-light.png";
const PORT = 9500 + Math.floor(Math.random() * 200);
const PROFILE = join(tmpdir(), "cdb-drag-" + Date.now());
const STAMP = Date.now();
const EMAIL = "shot+drag" + STAMP + "@local.test";
const PASS = "Drag" + STAMP + "Aa1";
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

const chrome = spawn(CHROME, [
  "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
  "--hide-scrollbars", `--remote-debugging-port=${PORT}`, `--user-data-dir=${PROFILE}`,
], { stdio: "ignore" });

try {
  const version = await waitEndpoint();
  const ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.addEventListener("open", res, { once: true });
    ws.addEventListener("error", rej, { once: true });
  });

  let nextId = 0;
  const pending = new Map();
  const errors = [];
  ws.addEventListener("message", (event) => {
    const msg = JSON.parse(event.data);
    if (msg.method === "Runtime.exceptionThrown") {
      errors.push(msg.params.exceptionDetails.text || "exception");
    }
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
    const res = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, sessionId);
    if (res.exceptionDetails) throw new Error(res.exceptionDetails.text);
    return res.result.value;
  };

  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Page.enable", {}, sessionId);
  await send("Runtime.enable", {}, sessionId);
  await send("Emulation.setDeviceMetricsOverride", { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
  await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "light" }] }, sessionId);
  await send("Page.navigate", { url: BASE + "/login" }, sessionId);
  await sleep(700);

  const reg = await evaluate(sessionId, `fetch("/api/register", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: ${JSON.stringify(EMAIL)}, password: ${JSON.stringify(PASS)} })
  }).then((r) => r.status)`);
  if (reg !== 201) throw new Error("register status " + reg);

  const ids = await evaluate(sessionId, `(async () => {
    const me = await fetch("/api/me").then((r) => r.json());
    const out = [];
    for (const title of ["drag a", "drag b", "drag c", "drag d"]) {
      const row = await fetch("/api/tasks", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user_id: me.user.id, title })
      }).then((r) => r.json());
      out.push(row.id);
    }
    return out;
  })()`);
  if (!ids || ids.length !== 4) throw new Error("create tasks failed");

  await send("Page.navigate", { url: BASE + "/" }, sessionId);
  let ready = false;
  for (let i = 0; i < 100; i += 1) {
    await sleep(150);
    ready = await evaluate(sessionId, `document.querySelectorAll("#list-todo .task").length === 4`);
    if (ready) break;
  }
  if (!ready) throw new Error("board not ready");

  const order = `(s) => [...document.querySelectorAll("#list-" + s + " .task")].map((n) => Number(n.dataset.id))`;
  const before = await evaluate(sessionId, `(${order})("todo")`);

  // drag "d" (last card) and hover above the first card
  const hover = await evaluate(sessionId, `(() => {
    const card = document.querySelector('#list-todo .task[data-id="${ids[3]}"]');
    const dt = new DataTransfer();
    card.dispatchEvent(new DragEvent("dragstart", { bubbles: true, cancelable: true, dataTransfer: dt }));
    const col = document.querySelector('.col[data-status="todo"]');
    const first = document.querySelector("#list-todo .task");
    const rect = first.getBoundingClientRect();
    const y = rect.top + 2;
    col.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer: dt, clientY: y }));
    return { y, dragging: card.classList.contains("dragging") };
  })()`);

  let slot = null;
  for (let i = 0; i < 40; i += 1) {
    await sleep(25);
    slot = await evaluate(sessionId, `(() => {
      const s = document.querySelector("#list-todo .drop-slot");
      if (!s) return null;
      const r = s.getBoundingClientRect();
      const cs = getComputedStyle(s);
      return {
        exists: true,
        index: s.dataset.index,
        height: Math.round(r.height),
        opacity: Number(cs.opacity),
        firstChild: s.parentElement.firstElementChild === s,
        nextId: s.nextElementSibling ? Number(s.nextElementSibling.dataset.id) || null : null,
      };
    })()`);
    if (slot && slot.height > 10 && slot.opacity > 0.95) break;
  }
  if (!slot || !slot.exists) throw new Error("drop slot not shown");
  if (slot.index !== "0") throw new Error("slot index wrong: " + slot.index);
  if (!slot.firstChild) throw new Error("slot not at top of list");
  if (slot.height < 10) throw new Error("slot did not expand: " + slot.height);
  if (slot.opacity < 0.9) throw new Error("slot not visible: " + slot.opacity);

  // screenshot while the indicator is open
  const shot = await send("Page.captureScreenshot", { format: "png" }, sessionId);
  mkdirSync(join(OUT, ".."), { recursive: true });
  writeFileSync(OUT, Buffer.from(shot.data, "base64"));

  // drop at the same coordinates
  await evaluate(sessionId, `(() => {
    const card = document.querySelector('#list-todo .task[data-id="${ids[3]}"]');
    const dt = new DataTransfer();
    dt.setData("text/plain", "${ids[3]}");
    const col = document.querySelector('.col[data-status="todo"]');
    col.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: dt, clientY: ${hover.y} }));
    card.dispatchEvent(new DragEvent("dragend", { bubbles: true, cancelable: true, dataTransfer: dt }));
  })()`);
  await sleep(900);
  const afterDrop = await evaluate(sessionId, `(${order})("todo")`);
  const slotGone = await evaluate(sessionId, `document.querySelectorAll(".drop-slot").length === 0`);

  // cross-column: move "c" to Doing at index 0
  const cross = await evaluate(sessionId, `(() => {
    const card = document.querySelector('#list-todo .task[data-id="${ids[2]}"]');
    const dt = new DataTransfer();
    card.dispatchEvent(new DragEvent("dragstart", { bubbles: true, cancelable: true, dataTransfer: dt }));
    const col = document.querySelector('.col[data-status="doing"]');
    const list = col.querySelector(".list");
    const rect = list.getBoundingClientRect();
    col.dispatchEvent(new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer: dt, clientY: rect.top + 2 }));
    const s = document.querySelector("#list-doing .drop-slot");
    return { slotThere: Boolean(s), index: s ? s.dataset.index : null };
  })()`);
  if (!cross.slotThere || cross.index !== "0") throw new Error("cross-column slot wrong: " + JSON.stringify(cross));
  await evaluate(sessionId, `(() => {
    const card = document.querySelector('#list-todo .task[data-id="${ids[2]}"]');
    const dt = new DataTransfer();
    dt.setData("text/plain", "${ids[2]}");
    const col = document.querySelector('.col[data-status="doing"]');
    const rect = col.querySelector(".list").getBoundingClientRect();
    col.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: dt, clientY: rect.top + 2 }));
    card.dispatchEvent(new DragEvent("dragend", { bubbles: true, cancelable: true, dataTransfer: dt }));
  })()`);
  await sleep(900);
  const doing = await evaluate(sessionId, `(${order})("doing")`);

  // reload -> server order must persist
  await send("Page.navigate", { url: BASE + "/" }, sessionId);
  await sleep(1300);
  const persisted = {
    todo: await evaluate(sessionId, `(${order})("todo")`),
    doing: await evaluate(sessionId, `(${order})("doing")`),
  };

  const expectedTodo = [ids[3], ids[0], ids[1], ids[2]];
  const expectedPersistedTodo = [ids[3], ids[0], ids[1]];
  if (JSON.stringify(before) !== JSON.stringify(ids)) throw new Error("initial order wrong: " + before);
  if (JSON.stringify(afterDrop) !== JSON.stringify(expectedTodo)) throw new Error("drop order wrong: " + afterDrop);
  if (!slotGone) throw new Error("drop slot left behind");
  if (JSON.stringify(doing) !== JSON.stringify([ids[2]])) throw new Error("cross-column move wrong: " + doing);
  if (JSON.stringify(persisted.todo) !== JSON.stringify(expectedPersistedTodo)) throw new Error("persisted todo wrong: " + persisted.todo);
  if (JSON.stringify(persisted.doing) !== JSON.stringify([ids[2]])) throw new Error("persisted doing wrong: " + persisted.doing);
  if (errors.length) throw new Error("console exceptions: " + errors.join(" | "));

  console.log(JSON.stringify({
    drag_indicator_ok: true,
    screenshot: OUT,
    account: EMAIL,
    before,
    slot,
    after_drop: afterDrop,
    cross_column: doing,
    persisted,
    console_errors: errors.length,
  }, null, 2));

  await send("Target.closeTarget", { targetId });
  ws.close();
} finally {
  chrome.kill();
  await sleep(300);
  rmSync(PROFILE, { recursive: true, force: true });
}
