#!/usr/bin/env -S deno run --allow-net
/**
 * cdp-screenshot.ts — capture a Chrome DevTools Protocol screenshot
 * via the WebSocket debugger URL. Used by visual-verify.sh because
 * chromium's `--screenshot=` shortcut fires too early for SPAs that
 * do their work asynchronously.
 *
 * Usage:
 *   deno run --allow-net cdp-screenshot.ts <wsUrl> <outPath>
 */

const [wsUrl, outPath] = Deno.args;
if (!wsUrl || !outPath) {
  console.error("usage: cdp-screenshot.ts <wsUrl> <outPath>");
  Deno.exit(1);
}

const ws = new WebSocket(wsUrl);

await new Promise<void>((resolve, reject) => {
  ws.onopen = () => resolve();
  ws.onerror = (e) => reject(new Error(`ws error: ${JSON.stringify(e)}`));
  setTimeout(() => reject(new Error("ws connect timeout")), 5000);
});

let nextId = 1;
const pending = new Map<
  number,
  (msg: { result?: { data?: string }; error?: { message?: string } }) => void
>();

ws.onmessage = (e) => {
  if (typeof e.data !== "string") return;
  const msg = JSON.parse(e.data);
  if (typeof msg.id === "number") {
    const cb = pending.get(msg.id);
    if (cb) {
      pending.delete(msg.id);
      cb(msg);
    }
  }
};

function send(
  method: string,
  params: Record<string, unknown> = {},
): Promise<{ result?: { data?: string }; error?: { message?: string } }> {
  const id = nextId++;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

const reply = await send("Page.captureScreenshot", { format: "png" });
ws.close();

if (reply.error) {
  console.error(`CDP error: ${reply.error.message ?? "unknown"}`);
  Deno.exit(1);
}
if (!reply.result?.data) {
  console.error("CDP returned no screenshot data");
  Deno.exit(1);
}

const bytes = Uint8Array.from(atob(reply.result.data), (c) => c.charCodeAt(0));
await Deno.writeFile(outPath, bytes);
console.log(`wrote ${bytes.length} bytes to ${outPath}`);
