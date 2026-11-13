// CDP screenshot tool: drives a chrome instance via --remote-debugging-port
// and sets a proper mobile viewport via Emulation.setDeviceMetricsOverride.
// Without this, headless Chrome ignores --window-size for the page viewport
// (it reports window.innerWidth=500 regardless of --window-size).

import { promises as fs } from "node:fs";

const [, , urlArg, outArg, themeArg] = process.argv;
const url = urlArg;
const outPath = outArg;
const theme = themeArg ?? "light";

const W = 390;     // iPhone 14/15/16 CSS width
const H = 844;     // iPhone 14/15/16 CSS height
const DPR = 3;

async function findAnyPage() {
  const r = await fetch("http://127.0.0.1:9222/json");
  const list = await r.json();
  return list.find((t) => t.type === "page");
}

async function main() {
  // Discover any page target (typically about:blank from --user-data-dir startup)
  let page;
  for (let i = 0; i < 30; i++) {
    page = await findAnyPage().catch(() => null);
    if (page) break;
    await new Promise((r) => setTimeout(r, 200));
  }
  if (!page) throw new Error("No page target found on http://127.0.0.1:9222");

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r, j) => {
    ws.onopen = () => r();
    ws.onerror = (e) => j(e);
  });

  let id = 0;
  const pending = new Map();
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.id != null && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(msg.error.message));
      else resolve(msg.result);
    }
  };
  function send(method, params = {}) {
    id += 1;
    const i = id;
    ws.send(JSON.stringify({ id: i, method, params }));
    return new Promise((resolve, reject) => pending.set(i, { resolve, reject }));
  }

  await send("Page.enable");
  await send("Emulation.setEmulatedMedia", {
    media: "screen",
    features: [{ name: "prefers-color-scheme", value: theme }],
  });
  await send("Emulation.setDeviceMetricsOverride", {
    width: W,
    height: H,
    deviceScaleFactor: DPR,
    mobile: true,
  });
  await send("Page.navigate", { url });

  // Wait for load
  await new Promise((r, j) => {
    const t = setTimeout(() => j(new Error("load timeout")), 15000);
    const onMsg = (e) => {
      const m = JSON.parse(e.data);
      if (m.method === "Page.loadEventFired") {
        clearTimeout(t);
        ws.removeEventListener("message", onMsg);
        r();
      }
    };
    ws.addEventListener("message", onMsg);
  });

  // Extra settle time for Flutter CanvasKit
  await new Promise((r) => setTimeout(r, 4000));

  const res = await send("Page.captureScreenshot", { format: "png" });
  await fs.writeFile(outPath, Buffer.from(res.data, "base64"));
  console.log(`wrote ${outPath}`);
  ws.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
