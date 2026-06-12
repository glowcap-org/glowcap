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
// Open the printed URL. It also prints the room's locator, so you can join from
// a terminal (`chat.ts <locator> <nick>`) at the same time.

import { Room } from "./room_client.ts";
import { ANNOUNCE_RE, announceToLocator } from "./locator.ts";
import { parsePresenceEvent } from "./presence.ts";

const HTTP_PORT = Number(Deno.args[0] ?? "8000");
// A fixed room port (override as the 2nd arg) so a TCP room is stable across
// server restarts and CLI clients always know where to connect.
const ROOM_PORT = Deno.args[1] ?? "9099";
// `ROOMS_TRANSPORT=iroh` runs the room over iroh; the server then announces an
// ocapn:// URI (it has no host:port to pin, so ROOM_PORT is ignored). Read the
// env var only when env access is granted, so the default permission set works.
const envAllowed = Deno.permissions.querySync({ name: "env", variable: "ROOMS_TRANSPORT" }).state === "granted";
const TRANSPORT = (envAllowed && Deno.env.get("ROOMS_TRANSPORT") === "iroh") ? "iroh" : "tcp";
const ROOT = new URL(".", import.meta.url).pathname;
const DENO_FLAGS = TRANSPORT === "iroh"
  ? ["run", "-A", "--unstable-ffi"]
  : ["run", "--allow-ffi", "--allow-read", "--allow-net"];

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

type JoinResult = { room: Room } | { unavailable: true } | {
  nameTaken: string;
};

// The room server runs as a child process. We keep `roomLocator` pointing at the
// live one and respawn it if it ever exits, so the room outlives a crash.
let roomLocator = "";
let server: Deno.ChildProcess;

async function superviseServer(): Promise<void> {
  const serverArgs = TRANSPORT === "iroh"
    ? [`${ROOT}server.ts`, "--transport=iroh"]
    : [`${ROOT}server.ts`, ROOM_PORT];
  server = new Deno.Command("deno", {
    args: [...DENO_FLAGS, ...serverArgs],
    stdout: "piped",
    stderr: "inherit",
  }).spawn();
  roomLocator = await readRoomLocator(server);
  // If it dies, bring it back. Bridges retry their join, so members recover.
  server.status.then((status) => {
    console.error(
      `rooms: room server exited (code ${status.code}); restarting…`,
    );
    superviseServer();
  });
}

await superviseServer();
console.log(`rooms web UI:   http://localhost:${HTTP_PORT}`);
console.log(
  `rooms server:   ${roomLocator}  (join from a terminal too:`,
);
console.log(
  `                deno ${
    DENO_FLAGS.join(" ")
  } ${ROOT}chat.ts ${roomLocator} <nick>)`,
);

Deno.serve({ port: HTTP_PORT }, (req) => {
  const url = new URL(req.url);
  if (url.pathname === "/ws") {
    const nick = (url.searchParams.get("nick") ?? "guest").slice(0, 32);
    const { socket, response } = Deno.upgradeWebSocket(req);
    // One tab's bridge failing must not take the server down with it.
    bridge(socket, nick).catch((err) =>
      console.error(`bridge for "${nick}" ended:`, err?.message ?? err)
    );
    return response;
  }
  return new Response(PAGE, {
    headers: { "content-type": "text/html; charset=utf-8" },
  });
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

  const joined = await joinWithRetry(nick);
  if ("unavailable" in joined) {
    // The room server is unreachable even after retries; let the browser know
    // and close so its own reconnect loop tries again shortly.
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(
        JSON.stringify({
          from: "room",
          text: "the room is unavailable — retrying…",
        }),
      );
    }
    try {
      ws.close();
    } catch { /* already closed */ }
    return;
  }
  if ("nameTaken" in joined) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(
        JSON.stringify({
          from: "room",
          text: joined.nameTaken,
          fatal: "name-taken",
        }),
      );
    }
    try {
      ws.close();
    } catch { /* already closed */ }
    return;
  }
  room = joined.room;
  if (closed) return void room.leave().catch(() => {}); // tab left mid-join
  for (const text of pending) room.say(text).catch(() => {});

  // Forward every line the room sends to the browser. The loop ends when the
  // member leaves or the room hangs up (then we close, and the browser reconnects).
  for await (const { from, text, system } of room.messages) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        from: system ? "room" : from,
        text,
        presence: system ? parsePresenceEvent(text) : null,
      }));
    }
  }
  try {
    ws.close();
  } catch { /* already closed */ }
}

// Join the room, retrying briefly so a momentary gap — the server mid-respawn —
// does not turn into a hard failure. Returns null if it stays unreachable.
async function joinWithRetry(nick: string): Promise<JoinResult> {
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      return { room: await Room.join(roomLocator, nick) };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      if (/name ".+" is already claimed/.test(message)) {
        return { nameTaken: message };
      }
      await delay(200 * (attempt + 1));
    }
  }
  return { unavailable: true };
}

// Read the server's "ROOMS-SERVER-LISTENING <token>" announcement and resolve it
// to a dial locator (a TCP host:port, or an iroh ocapn:// URI).
async function readRoomLocator(proc: Deno.ChildProcess): Promise<string> {
  const reader = proc.stdout.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value);
    const m = buf.match(ANNOUNCE_RE);
    if (m) {
      reader.releaseLock();
      return announceToLocator(m[1]);
    }
  }
  reader.releaseLock();
  throw new Error("rooms server never announced its locator");
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
  body { margin: 0; font: 15px/1.5 system-ui, sans-serif; min-height: 100vh; display: flex; background: linear-gradient(135deg, #4f8cff14, #8881); }
  .app { margin: auto; width: min(960px, calc(100vw - 24px)); height: min(82vh, 760px); display: grid;
         grid-template-rows: auto 1fr auto; border: 1px solid #8884; border-radius: 16px; overflow: hidden;
         background: color-mix(in srgb, Canvas 92%, transparent); box-shadow: 0 24px 80px #0002; }
  header { padding: 12px 16px; font-weight: 650; border-bottom: 1px solid #8884; display: flex; align-items: center; gap: 8px; }
  header small { font-weight: 400; opacity: 0.6; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: #999; flex: none; }
  .dot.connected { background: #3fb950; }
  .dot.connecting, .dot.reconnecting { background: #d29922; }
  .dot.disconnected { background: #f85149; }
  .main { min-height: 0; display: grid; grid-template-columns: minmax(0, 1fr) 240px; }
  #log { min-height: 0; overflow-y: auto; padding: 16px; display: flex; flex-direction: column; gap: 6px; }
  .msg { max-width: 80%; padding: 6px 10px; border-radius: 10px; background: #8881; }
  .msg .who { font-size: 12px; opacity: 0.6; margin-right: 6px; }
  .mine { align-self: flex-end; background: #4f8cff33; }
  .system { align-self: center; font-size: 13px; opacity: 0.6; background: none; }
  .presence { min-height: 0; border-left: 1px solid #8884; padding: 14px; background: #8881; display: flex; flex-direction: column; gap: 12px; }
  .presence h2 { margin: 0; font-size: 13px; letter-spacing: .08em; text-transform: uppercase; opacity: .62; }
  #presenceSummary { margin: 0; font-size: 13px; opacity: .72; }
  #members { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 6px; overflow-y: auto; }
  #members li { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 7px 9px; border: 1px solid #8883; border-radius: 10px; background: #8881; }
  #members .name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  #members .state { font-size: 11px; opacity: .64; }
  #members .offline { opacity: .45; }
  #members .offline .state { color: #f85149; opacity: .9; }
  #members .online .state { color: #3fb950; opacity: .9; }
  .empty { color: inherit; opacity: .55; font-size: 13px; }
  form { display: flex; gap: 8px; padding: 12px 16px; border-top: 1px solid #8884; }
  input, button { font: inherit; padding: 8px 12px; border-radius: 8px; border: 1px solid #8886; background: #8881; color: inherit; }
  input { flex: 1; }
  button { cursor: pointer; }
  .join { margin: auto; display: flex; flex-direction: column; gap: 12px; align-items: center; }
  .error { min-height: 1.4em; margin: -4px 0 0; color: #f85149; font-size: 13px; }
  @media (max-width: 720px) {
    .app { height: calc(100vh - 24px); }
    .main { grid-template-columns: 1fr; grid-template-rows: 1fr auto; }
    .presence { max-height: 34vh; border-left: 0; border-top: 1px solid #8884; }
  }
</style>
</head>
<body>
<div class="app">
  <header><span id="dot" class="dot"></span>pancake rooms <small id="status">— pick a name to join</small></header>
  <div class="main">
    <section id="log" aria-live="polite">
      <form id="joinForm" class="join">
        <input id="nick" placeholder="your name" aria-describedby="nickError" autofocus />
        <p id="nickError" class="error" role="alert" aria-live="polite"></p>
        <button id="joinBtn">Join the room</button>
      </form>
    </section>
    <aside class="presence" aria-label="Room presence">
      <h2>In the Room</h2>
      <p id="presenceSummary">Join to see who is here.</p>
      <ul id="members"></ul>
    </aside>
  </div>
  <form id="composer" hidden>
    <input id="line" placeholder="say something…" autocomplete="off" />
    <button>Send</button>
  </form>
</div>
<script>
  const log = document.getElementById("log");
  const joinForm = document.getElementById("joinForm");
  const nickInput = document.getElementById("nick");
  const nickError = document.getElementById("nickError");
  const joinBtn = document.getElementById("joinBtn");
  const statusEl = document.getElementById("status");
  const dot = document.getElementById("dot");
  const composer = document.getElementById("composer");
  const lineInput = document.getElementById("line");
  const presenceSummary = document.getElementById("presenceSummary");
  const membersEl = document.getElementById("members");
  const members = new Map();
  let nick = "";
  let ws = null;
  let backoff = 500;
  let everConnected = false;
  let reconnect = true;
  let joining = false;

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

  function applyPresence(event) {
    if (!event) return;
    if (event.kind === "roster") {
      for (const name of members.keys()) members.set(name, false);
      for (const name of event.names) members.set(name, true);
    } else {
      members.set(event.name, event.kind === "join");
    }
    renderPresence();
  }

  function renderPresence() {
    const rows = [...members.entries()].sort((a, b) => Number(b[1]) - Number(a[1]) || a[0].localeCompare(b[0]));
    const online = rows.filter(([, isOnline]) => isOnline).length;
    membersEl.innerHTML = "";
    presenceSummary.textContent = rows.length === 0
      ? "Waiting for the room roster."
      : online + " online · " + rows.length + " seen";
    if (rows.length === 0) {
      const empty = document.createElement("li");
      empty.className = "empty";
      empty.textContent = "No members yet.";
      membersEl.append(empty);
      return;
    }
    for (const [name, isOnline] of rows) {
      const li = document.createElement("li");
      li.className = isOnline ? "online" : "offline";
      const who = document.createElement("span");
      who.className = "name";
      who.textContent = name === nick ? name + " (you)" : name;
      const state = document.createElement("span");
      state.className = "state";
      state.textContent = isOnline ? "online" : "offline";
      li.append(who, state);
      membersEl.append(li);
    }
  }

  function setStatus(state, text) {
    dot.className = "dot " + state;
    statusEl.textContent = "— " + text;
  }

  function setJoinError(text) {
    nickError.textContent = text;
    nickInput.setAttribute("aria-invalid", text ? "true" : "false");
  }

  function finishJoinClaim() {
    if (!joining) {
      setStatus("connected", "in the room as " + nick);
      return;
    }
    joining = false;
    log.innerHTML = "";
    composer.hidden = false;
    setStatus("connected", "in the room as " + nick);
    lineInput.focus();
  }

  function rejectJoinClaim(text) {
    joining = false;
    reconnect = false;
    composer.hidden = true;
    if (!joinForm.isConnected) {
      log.innerHTML = "";
      log.append(joinForm);
    }
    joinBtn.disabled = false;
    joinBtn.textContent = "Join the room";
    setJoinError(text);
    setStatus("disconnected", "pick another name");
  }

  function connect() {
    setStatus("connecting", everConnected ? "reconnecting…" : "connecting…");
    const proto = location.protocol === "https:" ? "wss://" : "ws://";
    ws = new WebSocket(proto + location.host + "/ws?nick=" + encodeURIComponent(nick));

    ws.onopen = () => {
      backoff = 500;
      setStatus("connecting", "claiming " + nick + "…");
      if (everConnected) add("", "reconnected", "system");
      everConnected = true;
    };
    ws.onmessage = (event) => {
      const { from, text, presence, fatal } = JSON.parse(event.data);
      applyPresence(presence);
      if (fatal) {
        rejectJoinClaim(text);
        return;
      }
      finishJoinClaim();
      if (from === "room") add("", text, "system");
      else add(from, text, from === nick ? "mine" : "");
    };
    ws.onclose = () => {
      if (!reconnect) return;
      setStatus("reconnecting", "disconnected — reconnecting…");
      add("", "disconnected — reconnecting…", "system");
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, 5000); // back off, capped at 5s
    };
    ws.onerror = () => { try { ws.close(); } catch (_) {} };
  }

  function join() {
    nick = (nickInput.value || "guest").trim().slice(0, 32);
    if (!nick) return;
    members.clear();
    renderPresence();
    reconnect = true;
    joining = true;
    composer.hidden = true;
    joinBtn.disabled = true;
    joinBtn.textContent = "Claiming…";
    setJoinError("");
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

  joinForm.onsubmit = (e) => {
    e.preventDefault();
    join();
  };
  renderPresence();
</script>
</body>
</html>`;
