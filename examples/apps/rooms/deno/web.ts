// A browser UI for the rooms chat, served by Deno.
//
// A browser cannot speak raw TCP/OCapN, so this process stands in the middle: it
// serves a web page, and for each browser tab it opens its own pancake membership
// in the room and bridges the two.
//
//   browser ──WebSocket──▶ web.ts (a pancake member) ──TCP/OCapN──▶ rooms server
//
// It is built to survive interruption. It supervises the room server and respawns
// it if it dies; each bridge retries the join; and the page shows connection
// status and reconnects on its own, so restarting this process (to pick up a code
// change, say) just shows "reconnecting…" in the browser and recovers.
//
//   deno run --allow-ffi --allow-read --allow-net --allow-run web.ts
//
// Open the printed URL. It also prints the room's port, so you can join from a
// terminal (`chat.ts 127.0.0.1 <port> <nick>`) at the same time.

import { Room } from "./room_client.ts";

const HTTP_PORT = Number(Deno.args[0] ?? "8000");
// A fixed room port (override as the 2nd arg) so it is stable across server
// restarts and CLI clients always know where to connect.
const ROOM_PORT = Deno.args[1] ?? "9099";
const ROOT = new URL(".", import.meta.url).pathname;
const DENO_FLAGS = ["run", "--allow-ffi", "--allow-read", "--allow-net"];

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

// The room server runs as a child process. We keep `roomPort` pointing at the
// live one and respawn it if it ever exits, so the room outlives a crash.
let roomPort = 0;
let server: Deno.ChildProcess;

async function superviseServer(): Promise<void> {
  server = new Deno.Command("deno", {
    args: [...DENO_FLAGS, `${ROOT}server.ts`, ROOM_PORT],
    stdout: "piped",
    stderr: "inherit",
  }).spawn();
  roomPort = await readRoomPort(server);
  // If it dies, bring it back. Bridges retry their join, so members recover.
  server.status.then((status) => {
    console.error(`rooms: room server exited (code ${status.code}); restarting…`);
    superviseServer();
  });
}

await superviseServer();
console.log(`rooms web UI:   http://localhost:${HTTP_PORT}`);
console.log(`rooms server:   127.0.0.1:${roomPort}  (join from a terminal too:`);
console.log(`                deno ${DENO_FLAGS.join(" ")} ${ROOT}chat.ts 127.0.0.1 ${roomPort} <nick>)`);

Deno.serve({ port: HTTP_PORT }, (req) => {
  const url = new URL(req.url);
  if (url.pathname === "/ws") {
    const nick = (url.searchParams.get("nick") ?? "guest").slice(0, 32);
    const { socket, response } = Deno.upgradeWebSocket(req);
    // One tab's bridge failing must not take the server down with it.
    bridge(socket, nick).catch((err) => console.error(`bridge for "${nick}" ended:`, err?.message ?? err));
    return response;
  }
  return new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } });
});

// Bridge one browser tab to its own membership in the room: pipe the room's
// lines out to the browser, and the browser's typed lines into the room.
async function bridge(ws: WebSocket, nick: string): Promise<void> {
  // The browser may send (or close) before the join finishes, so wire its
  // handlers up first and hold any early lines until the room is ready.
  const pending: string[] = [];
  let room: Room | null = null;
  let closed = false;

  ws.onmessage = (event) => {
    const text = String(event.data).trim();
    if (text.length === 0) return;
    if (room) room.say(text).catch(() => {});
    else pending.push(text);
  };
  ws.onclose = () => {
    closed = true;
    room?.leave().catch(() => {});
  };

  room = await joinWithRetry(nick);
  if (room === null) {
    // The room server is unreachable even after retries; let the browser know
    // and close so its own reconnect loop tries again shortly.
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ from: "room", text: "the room is unavailable — retrying…" }));
    }
    try {
      ws.close();
    } catch { /* already closed */ }
    return;
  }
  if (closed) return void room.leave().catch(() => {}); // tab left mid-join
  for (const text of pending) room.say(text).catch(() => {});

  // Forward every line the room sends to the browser. The loop ends when the
  // member leaves or the room hangs up (then we close, and the browser reconnects).
  for await (const { from, text, system } of room.messages) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ from: system ? "room" : from, text }));
    }
  }
  try {
    ws.close();
  } catch { /* already closed */ }
}

// Join the room, retrying briefly so a momentary gap — the server mid-respawn —
// does not turn into a hard failure. Returns null if it stays unreachable.
async function joinWithRetry(nick: string): Promise<Room | null> {
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      return await Room.join("127.0.0.1", roomPort, nick);
    } catch {
      await delay(200 * (attempt + 1));
    }
  }
  return null;
}

// Read the server's "ROOMS-SERVER-LISTENING <port>" announcement.
async function readRoomPort(proc: Deno.ChildProcess): Promise<number> {
  const reader = proc.stdout.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value);
    const m = buf.match(/ROOMS-SERVER-LISTENING (\d+)/);
    if (m) {
      reader.releaseLock();
      return Number(m[1]);
    }
  }
  reader.releaseLock();
  throw new Error("rooms server never announced its port");
}

// Stop the server when this process is interrupted.
Deno.addSignalListener("SIGINT", () => {
  try {
    server.kill("SIGTERM");
  } catch { /* already gone */ }
  Deno.exit(0);
});

// The whole UI: one self-contained page, no build step and no framework. It
// tracks connection status and reconnects on its own, so a dropped server or a
// restarted `web.ts` shows "reconnecting…" and then recovers.
const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>pancake rooms</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 15px/1.5 system-ui, sans-serif; height: 100vh; display: flex; }
  .app { margin: auto; width: min(640px, 100%); height: min(80vh, 100%); display: flex;
         flex-direction: column; border: 1px solid #8884; border-radius: 12px; overflow: hidden; }
  header { padding: 12px 16px; font-weight: 600; border-bottom: 1px solid #8884; display: flex; align-items: center; gap: 8px; }
  header small { font-weight: 400; opacity: 0.6; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: #999; flex: none; }
  .dot.connected { background: #3fb950; }
  .dot.connecting, .dot.reconnecting { background: #d29922; }
  .dot.disconnected { background: #f85149; }
  #log { flex: 1; overflow-y: auto; padding: 12px 16px; display: flex; flex-direction: column; gap: 6px; }
  .msg { max-width: 80%; padding: 6px 10px; border-radius: 10px; background: #8881; }
  .msg .who { font-size: 12px; opacity: 0.6; margin-right: 6px; }
  .mine { align-self: flex-end; background: #4f8cff33; }
  .system { align-self: center; font-size: 13px; opacity: 0.6; background: none; }
  form { display: flex; gap: 8px; padding: 12px 16px; border-top: 1px solid #8884; }
  input, button { font: inherit; padding: 8px 12px; border-radius: 8px; border: 1px solid #8886; background: #8881; color: inherit; }
  input { flex: 1; }
  button { cursor: pointer; }
  .join { margin: auto; display: flex; flex-direction: column; gap: 12px; align-items: center; }
</style>
</head>
<body>
<div class="app">
  <header><span id="dot" class="dot"></span>pancake rooms <small id="status">— pick a name to join</small></header>
  <div id="log">
    <div class="join">
      <input id="nick" placeholder="your name" autofocus />
      <button id="joinBtn">Join the room</button>
    </div>
  </div>
  <form id="composer" hidden>
    <input id="line" placeholder="say something…" autocomplete="off" />
    <button>Send</button>
  </form>
</div>
<script>
  const log = document.getElementById("log");
  const statusEl = document.getElementById("status");
  const dot = document.getElementById("dot");
  const composer = document.getElementById("composer");
  const lineInput = document.getElementById("line");
  let nick = "";
  let ws = null;
  let backoff = 500;
  let everConnected = false;

  function add(from, text, kind) {
    const el = document.createElement("div");
    el.className = "msg " + (kind || "");
    if (kind === "system") {
      el.textContent = text;
    } else {
      const who = document.createElement("span");
      who.className = "who";
      who.textContent = from;
      el.append(who, document.createTextNode(text));
    }
    log.append(el);
    log.scrollTop = log.scrollHeight;
  }

  function setStatus(state, text) {
    dot.className = "dot " + state;
    statusEl.textContent = "— " + text;
  }

  function connect() {
    setStatus("connecting", everConnected ? "reconnecting…" : "connecting…");
    const proto = location.protocol === "https:" ? "wss://" : "ws://";
    ws = new WebSocket(proto + location.host + "/ws?nick=" + encodeURIComponent(nick));

    ws.onopen = () => {
      backoff = 500;
      setStatus("connected", "in the room as " + nick);
      if (everConnected) add("", "reconnected", "system");
      everConnected = true;
    };
    ws.onmessage = (event) => {
      const { from, text } = JSON.parse(event.data);
      if (from === "room") add("", text, "system");
      else add(from, text, from === nick ? "mine" : "");
    };
    ws.onclose = () => {
      setStatus("reconnecting", "disconnected — reconnecting…");
      add("", "disconnected — reconnecting…", "system");
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, 5000); // back off, capped at 5s
    };
    ws.onerror = () => { try { ws.close(); } catch (_) {} };
  }

  function join() {
    nick = (document.getElementById("nick").value || "guest").trim().slice(0, 32);
    if (!nick) return;
    log.innerHTML = "";
    composer.hidden = false;
    lineInput.focus();
    connect();
  }

  composer.onsubmit = (e) => {
    e.preventDefault();
    const text = lineInput.value.trim();
    if (!text) return;
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(text);
      lineInput.value = "";
    } else {
      add("", "not connected — your line was not sent", "system");
    }
  };

  document.getElementById("joinBtn").onclick = join;
  document.getElementById("nick").addEventListener("keydown", (e) => { if (e.key === "Enter") join(); });
</script>
</body>
</html>`;
