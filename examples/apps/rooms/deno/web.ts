// A browser UI for the rooms chat, served by Deno.
//
// A browser cannot speak raw TCP/OCapN, so this process stands in the middle: it
// serves a web page, and for each browser tab it opens its own pancake connection
// to the directory and bridges the two.
//
//   browser ──WebSocket──▶ web.ts (a pancake connection) ──TCP/OCapN──▶ rooms server
//
// Each tab's connection holds three things at once on one wire: a live `watch` of
// the directory (so the browser shows the rooms that have people in them, updating
// as they come and go), the current room membership, and the ability to switch —
// leave one room and enter another — without reconnecting. The page shows the
// live room list before you even pick a name, and lets you hop between rooms once
// you are in.
//
// It is built to survive interruption. It supervises the room server and respawns
// it if it dies; the browser reconnects on its own and replays its join, so
// restarting this process (to pick up a code change, say) just shows
// "reconnecting…" and recovers.
//
//   deno run --allow-ffi --allow-read --allow-net --allow-run web.ts
//
// Open the printed URL. It also prints the room's locator, so you can join from
// a terminal (`chat.ts <locator> <room> <nick>`) at the same time.

import { Directory, Room } from "./room_client.ts";
import { enterOrOpen } from "./enter_room.ts";
import { ANNOUNCE_RE, announceToLocator } from "./locator.ts";
import { parsePresenceEvent } from "./presence.ts";

const HTTP_PORT = Number(Deno.args[0] ?? "8000");
// A fixed room port (override as the 2nd arg) so a TCP room is stable across
// server restarts and CLI clients always know where to connect.
const ROOM_PORT = Deno.args[1] ?? "9099";
// `ROOMS_TRANSPORT=iroh` runs the room over iroh; the server then announces an
// ocapn:// URI (it has no host:port to pin, so ROOM_PORT is ignored). Read the
// env var only when env access is granted, so the default permission set works.
const envAllowed = Deno.permissions.querySync({ name: "env", variable: "ROOMS_TRANSPORT" })
	.state === "granted";
const TRANSPORT = (envAllowed && Deno.env.get("ROOMS_TRANSPORT") === "iroh") ? "iroh" : "tcp";
const ROOT = new URL(".", import.meta.url).pathname;
const DENO_FLAGS = TRANSPORT === "iroh"
	? ["run", "-A", "--unstable-ffi"]
	: ["run", "--allow-ffi", "--allow-read", "--allow-net"];

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

// The room server runs as a child process. We keep `roomLocator` pointing at the
// live one and respawn it if it ever exits, so the rooms outlive a crash.
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
	// If it dies, bring it back. Tabs reconnect and replay their join, so members
	// recover.
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
	`                deno ${DENO_FLAGS.join(" ")} ${ROOT}chat.ts ${roomLocator} <room> <nick>)`,
);

Deno.serve({ port: HTTP_PORT }, (req) => {
	const url = new URL(req.url);
	if (url.pathname === "/ws") {
		const { socket, response } = Deno.upgradeWebSocket(req);
		// One tab's bridge failing must not take the server down with it.
		bridge(socket).catch((err) => console.error("bridge ended:", err?.message ?? err));
		return response;
	}
	return new Response(PAGE, {
		headers: { "content-type": "text/html; charset=utf-8" },
	});
});

// What the browser sends us over the socket: ask to be in a room (the initial
// join and every switch), or say a line in the current room.
type Inbound =
	| { join: { room: string; nick: string } }
	| { say: string };

function safeSend(ws: WebSocket, msg: unknown): void {
	if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

function safeClose(ws: WebSocket): void {
	try {
		ws.close();
	} catch { /* already closed */ }
}

// Bridge one browser tab: open a directory connection, stream the live room list
// to the browser, and follow the browser's join/switch/say as one membership on
// that connection.
async function bridge(ws: WebSocket): Promise<void> {
	// The browser may send before the directory is ready, so wire its handlers up
	// first and buffer anything that arrives early.
	const pending: Inbound[] = [];
	let onInbound: ((m: Inbound) => void) | null = null;
	let onSocketClose = () => {};
	ws.onmessage = (event) => {
		let m: Inbound;
		try {
			m = JSON.parse(String(event.data));
		} catch {
			return;
		}
		if (onInbound) onInbound(m);
		else pending.push(m);
	};
	ws.onclose = () => onSocketClose();

	const dir = await connectDirectory();
	if (!dir) {
		safeSend(ws, { notice: "the room server is unavailable — reconnecting…" });
		safeClose(ws);
		return;
	}
	onSocketClose = () => void dir.close().catch(() => {});

	const rooms = new Map<string, number>();
	const sendRooms = () => safeSend(ws, { rooms: [...rooms.entries()] });

	// Follow the directory and stream every change of the live room list.
	try {
		for (
			const room of await dir.watch((event) => {
				if (event.kind === "closed") rooms.delete(event.name);
				else rooms.set(event.name, event.count);
				sendRooms();
			})
		) rooms.set(room.name, room.count);
	} catch {
		await dir.close();
		safeClose(ws);
		return;
	}
	sendRooms();

	// If the directory connection drops (the server respawning), end the tab; the
	// browser reconnects and gets a fresh directory.
	dir.conn.serve().finally(() => safeClose(ws));

	let current: Room | null = null;

	// Enter `name` as `nick`, leaving the current room first. Subscribe before
	// leaving, so a rejected claim leaves the current room intact.
	async function join(name: string, nick: string): Promise<void> {
		try {
			const ref = await enterOrOpen(dir!, name);
			const next = await Room.subscribe(dir!.conn, ref, nick);
			if (current) await current.leave();
			current = next;
			safeSend(ws, { joined: name });
			pump(next);
		} catch (err) {
			const message = err instanceof Error ? err.message : String(err);
			if (/is already claimed/.test(message)) {
				safeSend(ws, { nameTaken: message });
			} else safeSend(ws, { notice: message });
		}
	}

	// Forward a room's lines to the browser until it ends (we switched away, or
	// the room hung up).
	async function pump(room: Room): Promise<void> {
		try {
			for await (const { from, text, system } of room.messages) {
				safeSend(ws, {
					from: system ? "room" : from,
					text,
					presence: system ? parsePresenceEvent(text) : null,
				});
			}
		} catch { /* the stream ended under us */ }
	}

	const handle = (m: Inbound): void => {
		if ("say" in m && typeof m.say === "string") {
			current?.say(m.say).catch(() => {});
		} else if ("join" in m && m.join) {
			join(String(m.join.room).slice(0, 32), String(m.join.nick).slice(0, 32));
		}
	};
	onInbound = handle;
	for (const m of pending) handle(m);
}

// Open a directory connection, retrying briefly so a momentary gap — the server
// mid-respawn — does not turn into a hard failure. Returns null if it stays
// unreachable.
async function connectDirectory(): Promise<Directory | null> {
	for (let attempt = 0; attempt < 5; attempt++) {
		try {
			return await Directory.connect(roomLocator);
		} catch {
			await delay(200 * (attempt + 1));
		}
	}
	return null;
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

// The whole UI: one self-contained page, no build step and no framework, dressed
// in pancake's own palette (cream paper, cocoa ink, an amber accent, a teal
// flourish — the colours of the docs site). The layout is a warm room sidebar
// (the live room list, with inline room creation), a room header, a left/right
// chat-bubble stream (others left, you right, author-grouped), a collapsible
// member pane, and a composer. Messages render light markdown, links, :emoji:
// shortcodes, @mentions, and /me actions; the composer is a multi-line box with
// an emoji picker (Enter sends, Shift+Enter newlines). Day and "new messages"
// dividers mark the stream, a light/"syrup" dark theme and your nick + last room
// persist across visits, and @mentions can raise an opt-in desktop notification.
// It is built for robustness, not looks alone: it tracks connection status and
// reconnects on its own, replaying its join so a dropped server or a restarted
// `web.ts` shows a "reconnecting…" banner and then recovers; every inbound frame
// is parsed defensively; message text is rendered through textContent so it can
// never inject markup; autoscroll sticks to the bottom only when you are already
// there (with a "jump to latest" button otherwise); and the tab title carries an
// unread badge while it is unfocused.
const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>pancake rooms</title>
<style>
  /* pancake's own palette — cream paper, cocoa ink, an amber accent, a teal
     flourish (the docs-site colours), so rooms looks like it belongs to pancake
     rather than to any chat app it borrows ideas from. */
  :root {
    color-scheme: light;
    --ink: #3a3027;
    --ink-soft: #6b5d4d;
    --paper: #fff3df;
    --paper-raised: #fff9ee;
    --accent: #c76f18;
    --accent-deep: #a4560c;
    --teal: #257f88;
    --teal-deep: #1b5f66;
    --rule: #e7d4b7;
    --danger: #b23b2e;
    --ok: #257f88;
    --warn: #c76f18;
    --hover: color-mix(in srgb, var(--ink) 6%, transparent);
    --shadow-sm: 0 1px 2px rgba(58,48,39,.10);
    --shadow: 0 18px 50px rgba(58,48,39,.16);
    /* The teal four-point twinkle from the pancake hero art, reused as a spark. */
    --sparkle: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cpath d='M8 0.6 Q8.9 6.5 15.4 8 Q8.9 9.5 8 15.4 Q7.1 9.5 0.6 8 Q7.1 6.5 8 0.6 Z' fill='%23257f88'/%3E%3C/svg%3E");
  }
  /* "Syrup" — the same warmth turned down to a dark roast. */
  html[data-theme="dark"] {
    --ink: #f3e6d0;
    --ink-soft: #b9a684;
    --paper: #211911;
    --paper-raised: #2c2217;
    --accent: #e8912d;
    --accent-deep: #c76f18;
    --teal: #4bb3bd;
    --teal-deep: #2c97a1;
    --rule: #3c3022;
    --danger: #e07a5f;
    --ok: #4bb3bd;
    --warn: #e8912d;
    --hover: color-mix(in srgb, #ffffff 7%, transparent);
    --shadow-sm: 0 1px 2px rgba(0,0,0,.4);
    --shadow: 0 18px 50px rgba(0,0,0,.55);
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0;
    font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif;
    color: var(--ink);
    background:
      radial-gradient(120% 70% at 50% -10%, color-mix(in srgb, var(--accent) 12%, var(--paper)) 0%, var(--paper) 55%) no-repeat,
      var(--paper);
  }
  /* The amber→teal hairline the docs site runs above everything. */
  .app::before { content: ""; position: fixed; inset: 0 0 auto 0; height: 3px; z-index: 5; background: linear-gradient(90deg, var(--accent) 0%, var(--teal) 100%); }
  .app { height: 100vh; display: grid; grid-template-columns: 264px minmax(0, 1fr); }
  ::selection { background: color-mix(in srgb, var(--accent) 28%, transparent); }

  /* ── Sidebar ──────────────────────────────────────────────────────────── */
  .sidebar { background: linear-gradient(180deg, var(--paper-raised), color-mix(in srgb, var(--accent) 5%, var(--paper-raised))); border-right: 1px solid var(--rule); display: flex; flex-direction: column; min-height: 0; }
  .workspace { display: flex; align-items: baseline; gap: 8px; padding: 16px 18px; color: var(--ink); font-weight: 800; font-size: 18px; letter-spacing: -.01em; border-bottom: 1px solid var(--rule); }
  .workspace::before { content: ""; width: 16px; height: 16px; align-self: center; background: var(--sparkle) center/contain no-repeat; flex: none; }
  .workspace small { font-weight: 600; font-size: 12px; letter-spacing: .12em; text-transform: uppercase; color: var(--accent-deep); }
  .section { padding: 12px 10px; min-height: 0; display: flex; flex-direction: column; overflow: hidden; }
  .section-head { display: flex; align-items: center; justify-content: space-between; padding: 4px 8px; font-size: 12px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: var(--ink-soft); }
  .section-head button { all: unset; cursor: pointer; width: 24px; height: 24px; line-height: 22px; text-align: center; border-radius: 7px; color: var(--accent-deep); font-size: 18px; }
  .section-head button:hover { background: color-mix(in srgb, var(--accent) 14%, transparent); }
  #roomList { margin: 4px 0 0; padding: 0; list-style: none; min-height: 0; overflow-y: auto; }
  #roomList li { display: flex; align-items: center; gap: 8px; padding: 7px 8px; border-radius: 9px; cursor: pointer; color: var(--ink); }
  #roomList li:hover { background: var(--hover); }
  #roomList li.here { background: color-mix(in srgb, var(--accent) 16%, transparent); color: var(--accent-deep); font-weight: 700; box-shadow: inset 3px 0 0 var(--accent); }
  #roomList .hash { color: var(--accent); flex: none; font-weight: 700; }
  #roomList .rname { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; }
  #roomList .rcount { font-size: 12px; flex: none; background: color-mix(in srgb, var(--teal) 16%, transparent); color: var(--teal-deep); padding: 1px 8px; border-radius: 9px; min-width: 22px; text-align: center; font-weight: 600; }
  #roomList li.here .rcount { background: color-mix(in srgb, var(--accent) 24%, transparent); color: var(--accent-deep); }
  #roomList .empty { padding: 6px 8px; color: var(--ink-soft); font-size: 13px; cursor: default; }
  .newroom { display: none; padding: 4px 8px 0; }
  .newroom.show { display: block; }
  .newroom input { width: 100%; font: inherit; padding: 7px 10px; border-radius: 9px; border: 1px solid var(--rule); background: var(--paper); color: var(--ink); }
  .newroom input::placeholder { color: var(--ink-soft); }
  .newroom input:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 30%, transparent); }
  .sidebar-foot { margin-top: auto; display: flex; align-items: center; gap: 9px; padding: 12px 18px; border-top: 1px solid var(--rule); font-size: 13px; color: var(--ink-soft); }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--ink-soft); flex: none; box-shadow: 0 0 0 3px color-mix(in srgb, var(--ink) 8%, transparent); }
  .dot.connected { background: var(--ok); box-shadow: 0 0 0 3px color-mix(in srgb, var(--ok) 22%, transparent); }
  .dot.connecting, .dot.reconnecting { background: var(--warn); box-shadow: 0 0 0 3px color-mix(in srgb, var(--warn) 22%, transparent); }
  .dot.disconnected { background: var(--danger); box-shadow: 0 0 0 3px color-mix(in srgb, var(--danger) 22%, transparent); }

  /* ── Main column ──────────────────────────────────────────────────────── */
  .workarea { min-width: 0; min-height: 0; display: grid; grid-template-rows: auto 1fr auto; }
  .topbar { display: flex; align-items: center; gap: 12px; padding: 12px 20px; border-bottom: 1px solid var(--rule); background: color-mix(in srgb, var(--paper-raised) 70%, transparent); }
  .topbar h1 { margin: 0; font-size: 17px; font-weight: 800; letter-spacing: -.01em; display: flex; align-items: center; gap: 4px; min-width: 0; }
  .topbar h1 .hash { color: var(--accent); font-weight: 700; }
  .topbar .meta { font-size: 13px; color: var(--ink-soft); white-space: nowrap; }
  .topbar .spacer { flex: 1; }
  .topbar .ghost { all: unset; cursor: pointer; padding: 6px 12px; border-radius: 9px; border: 1px solid var(--rule); color: var(--ink-soft); font-size: 13px; font-weight: 600; display: inline-flex; align-items: center; gap: 6px; }
  .topbar .ghost:hover { background: var(--hover); color: var(--ink); }
  .banner { padding: 8px 20px; font-size: 13px; color: var(--accent-deep); background: color-mix(in srgb, var(--accent) 14%, var(--paper)); border-bottom: 1px solid var(--rule); display: none; }
  .banner.show { display: block; }

  .content { min-height: 0; display: grid; grid-template-columns: minmax(0,1fr) 240px; }
  .content.no-members { grid-template-columns: minmax(0,1fr); }
  .content.no-members .members { display: none; }

  /* ── Message stream — left/right chat bubbles ─────────────────────────── */
  .stream { position: relative; min-height: 0; }
  #log { position: absolute; inset: 0; overflow-y: auto; padding: 16px 0 20px; display: flex; flex-direction: column; gap: 2px; }
  .row { display: flex; gap: 10px; padding: 2px 20px; align-items: flex-start; }
  .row.them { justify-content: flex-start; }
  .row.mine { justify-content: flex-end; }
  .row .avatar { width: 32px; height: 32px; border-radius: 10px; flex: none; display: flex; align-items: center; justify-content: center; color: #fff; font-weight: 700; font-size: 13px; box-shadow: var(--shadow-sm); }
  .row.mine .avatar { display: none; }
  .stack { display: flex; flex-direction: column; max-width: min(560px, 76%); min-width: 0; }
  .row.mine .stack { align-items: flex-end; }
  .who { font-size: 12px; font-weight: 700; color: var(--ink-soft); margin: 0 0 4px 12px; }
  .bubble { background: var(--paper-raised); border: 1px solid var(--rule); color: var(--ink); padding: 8px 13px; border-radius: 16px; border-top-left-radius: 6px; overflow-wrap: anywhere; white-space: pre-wrap; box-shadow: var(--shadow-sm); }
  .bubble + .bubble { margin-top: 3px; }
  .row.mine .bubble { background: linear-gradient(135deg, var(--accent) 0%, var(--accent-deep) 100%); color: #fff8ef; border-color: transparent; border-radius: 16px; border-top-right-radius: 6px; border-top-left-radius: 16px; }
  .time { font-size: 10.5px; color: var(--ink-soft); margin: 4px 0 2px 12px; }
  .row.mine .time { margin: 4px 4px 2px 0; }
  .sys { align-self: center; padding: 6px 0; }
  .sys span { font-size: 12.5px; color: var(--ink-soft); background: color-mix(in srgb, var(--ink) 6%, transparent); padding: 3px 13px; border-radius: 12px; }
  .jump { position: absolute; left: 50%; bottom: 16px; transform: translateX(-50%); display: none; cursor: pointer; border: 1px solid var(--rule); background: var(--paper-raised); color: var(--accent-deep); font: inherit; font-size: 13px; font-weight: 700; padding: 7px 16px; border-radius: 20px; box-shadow: var(--shadow); }
  .jump.show { display: block; }

  /* ── Member pane ──────────────────────────────────────────────────────── */
  .members { min-height: 0; border-left: 1px solid var(--rule); padding: 16px; display: flex; flex-direction: column; gap: 10px; background: color-mix(in srgb, var(--paper-raised) 60%, transparent); }
  .members h2 { margin: 0; font-size: 12px; letter-spacing: .08em; text-transform: uppercase; color: var(--ink-soft); font-weight: 700; }
  #presenceSummary { margin: 0; font-size: 13px; color: var(--ink-soft); }
  #members { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 2px; overflow-y: auto; min-height: 0; }
  #members li { display: flex; align-items: center; gap: 9px; padding: 6px 8px; border-radius: 9px; }
  #members li:hover { background: var(--hover); }
  #members .pip { width: 9px; height: 9px; border-radius: 50%; flex: none; border: 1.5px solid currentColor; }
  #members .online { color: var(--teal-deep); }
  #members .online .pip { background: var(--teal); color: var(--teal); }
  #members .offline { color: var(--ink-soft); opacity: .7; }
  #members .offline .pip { background: transparent; }
  #members .name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--ink); }
  #members .offline .name { color: var(--ink-soft); }
  .empty { color: var(--ink-soft); font-size: 13px; }

  /* ── Composer ─────────────────────────────────────────────────────────── */
  .composer { padding: 0 20px 20px; }
  .composer form { display: flex; align-items: center; gap: 8px; border: 1px solid var(--rule); border-radius: 14px; padding: 6px 6px 6px 16px; background: var(--paper-raised); box-shadow: var(--shadow-sm); }
  .composer form:focus-within { border-color: var(--accent); box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 28%, transparent); }
  .composer input { flex: 1; font: inherit; border: 0; background: none; color: var(--ink); padding: 7px 0; outline: none; }
  .composer input::placeholder { color: var(--ink-soft); }
  .composer button { all: unset; cursor: pointer; background: linear-gradient(135deg, var(--accent), var(--accent-deep)); color: #fff8ef; padding: 9px 18px; border-radius: 10px; font-weight: 700; }
  .composer button:hover { filter: brightness(1.05); }
  .composer button:disabled { opacity: .4; cursor: not-allowed; filter: none; }

  /* ── Join card ────────────────────────────────────────────────────────── */
  .join-wrap { display: grid; place-items: center; padding: 24px; height: 100%; }
  .join { width: min(390px, 100%); display: flex; flex-direction: column; gap: 13px; border: 1px solid var(--rule); border-radius: 18px; padding: 28px; background: var(--paper-raised); box-shadow: var(--shadow); position: relative; overflow: hidden; }
  .join::before { content: ""; position: absolute; inset: 0 0 auto 0; height: 4px; background: linear-gradient(90deg, var(--accent), var(--teal)); }
  .join h2 { margin: 4px 0 0; font-size: 21px; letter-spacing: -.01em; display: flex; align-items: center; gap: 9px; }
  .join h2::before { content: ""; width: 20px; height: 20px; background: var(--sparkle) center/contain no-repeat; flex: none; }
  .join p.lead { margin: -4px 0 6px; color: var(--ink-soft); font-size: 14px; }
  .join label { font-size: 12px; font-weight: 700; color: var(--ink-soft); margin-bottom: -7px; }
  .join input { font: inherit; padding: 11px 13px; border-radius: 11px; border: 1px solid var(--rule); background: var(--paper); color: var(--ink); }
  .join input:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 2px color-mix(in srgb, var(--accent) 28%, transparent); }
  .join button { all: unset; text-align: center; cursor: pointer; background: linear-gradient(135deg, var(--accent), var(--accent-deep)); color: #fff8ef; padding: 12px; border-radius: 11px; font-weight: 800; margin-top: 2px; }
  .join button:hover { filter: brightness(1.05); }
  .join button:disabled { opacity: .55; cursor: progress; filter: none; }
  .error { min-height: 1.2em; margin: -4px 0 0; color: var(--danger); font-size: 13px; }

  /* ── Rich text inside bubbles ─────────────────────────────────────────── */
  .bubble a { color: var(--teal-deep); text-decoration: underline; text-underline-offset: 2px; }
  .row.mine .bubble a { color: #fff8ef; }
  .bubble code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; background: color-mix(in srgb, var(--ink) 9%, transparent); padding: 1px 5px; border-radius: 5px; }
  .row.mine .bubble code { background: rgba(255,255,255,.2); }
  .mention { color: var(--accent-deep); background: color-mix(in srgb, var(--accent) 16%, transparent); padding: 0 4px; border-radius: 5px; font-weight: 600; }
  .row.mine .mention { color: #fff8ef; background: rgba(255,255,255,.24); }
  .mention.you { background: var(--accent); color: #fff8ef; }
  .row.them .bubble.hl { box-shadow: 0 0 0 2px var(--accent); }

  /* ── Day + unread dividers ────────────────────────────────────────────── */
  .divider { align-self: stretch; display: flex; align-items: center; gap: 12px; padding: 8px 20px; color: var(--ink-soft); font-size: 12px; }
  .divider::before, .divider::after { content: ""; height: 1px; background: var(--rule); flex: 1; }
  .divider span { white-space: nowrap; font-weight: 600; }
  .divider.unread { color: var(--accent-deep); }
  .divider.unread::before, .divider.unread::after { background: color-mix(in srgb, var(--accent) 50%, transparent); }

  /* ── /me action lines ─────────────────────────────────────────────────── */
  .sys.action span { font-style: italic; color: var(--accent-deep); background: color-mix(in srgb, var(--accent) 12%, transparent); }

  /* ── Per-message hover actions ────────────────────────────────────────── */
  .row { position: relative; }
  .row .acts { position: absolute; top: -10px; display: none; gap: 2px; background: var(--paper-raised); border: 1px solid var(--rule); border-radius: 9px; padding: 2px; box-shadow: var(--shadow-sm); z-index: 2; }
  .row.them .acts { left: 54px; }
  .row.mine .acts { right: 20px; }
  .row:hover .acts { display: flex; }
  .row .acts button { all: unset; cursor: pointer; font-size: 12.5px; line-height: 1; padding: 5px 7px; border-radius: 7px; color: var(--ink-soft); }
  .row .acts button:hover { background: var(--hover); color: var(--ink); }

  /* ── Topbar icon buttons (theme, notifications) ───────────────────────── */
  .topbar .icon { all: unset; cursor: pointer; width: 34px; height: 34px; display: inline-flex; align-items: center; justify-content: center; border-radius: 9px; border: 1px solid var(--rule); color: var(--ink-soft); font-size: 15px; }
  .topbar .icon:hover { background: var(--hover); color: var(--ink); }
  .topbar .icon.on { color: var(--accent-deep); border-color: color-mix(in srgb, var(--accent) 45%, transparent); background: color-mix(in srgb, var(--accent) 12%, transparent); }

  /* ── Composer extras: textarea, emoji ─────────────────────────────────── */
  .composer { position: relative; }
  .composer form { align-items: flex-end; }
  .composer textarea { flex: 1; font: inherit; border: 0; background: none; color: var(--ink); padding: 7px 0; outline: none; resize: none; max-height: 140px; line-height: 1.45; }
  .composer textarea::placeholder { color: var(--ink-soft); }
  .composer .emoji-btn { all: unset; cursor: pointer; font-size: 18px; padding: 5px 7px; border-radius: 9px; }
  .composer .emoji-btn:hover { background: var(--hover); }
  .composer .hint { padding: 4px 6px 0; font-size: 11.5px; color: var(--ink-soft); height: 0; overflow: hidden; transition: height .12s; }
  .composer form:focus-within ~ .hint, .composer .hint.show { height: 18px; }
  .emoji-pop { position: absolute; bottom: 64px; right: 20px; display: none; grid-template-columns: repeat(8, 1fr); gap: 2px; background: var(--paper-raised); border: 1px solid var(--rule); border-radius: 12px; padding: 8px; box-shadow: var(--shadow); z-index: 6; }
  .emoji-pop.show { display: grid; }
  .emoji-pop button { all: unset; cursor: pointer; font-size: 19px; padding: 5px; border-radius: 8px; text-align: center; }
  .emoji-pop button:hover { background: var(--hover); }

  @media (max-width: 820px) {
    .app { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
    .sidebar { flex-direction: row; align-items: center; overflow-x: auto; gap: 4px; padding: 0 6px; border-right: 0; border-bottom: 1px solid var(--rule); }
    .workspace { border: 0; padding: 12px; white-space: nowrap; }
    .section { flex-direction: row; align-items: center; padding: 6px; }
    .section-head { display: none; }
    #roomList { display: flex; flex-direction: row; gap: 4px; }
    .newroom { display: none !important; }
    .sidebar-foot { margin: 0; border: 0; padding: 0 12px; }
    .content { grid-template-columns: minmax(0,1fr); }
    .members { display: none; }
    .stack { max-width: 82%; }
  }
</style>
</head>
<body>
<div class="app">
  <nav class="sidebar" aria-label="Rooms">
    <div class="workspace">pancake <small>rooms</small></div>
    <div class="section">
      <div class="section-head">
        <span>Rooms</span>
        <button id="newRoomBtn" title="Create or open a room" aria-label="Create or open a room">+</button>
      </div>
      <div id="newRoom" class="newroom">
        <input id="newRoomInput" placeholder="new-room-name" aria-label="New room name" maxlength="32" />
      </div>
      <ul id="roomList"></ul>
    </div>
    <div class="sidebar-foot"><span id="dot" class="dot"></span><span id="status">connecting…</span></div>
  </nav>

  <div class="workarea">
    <header class="topbar">
      <h1 id="roomTitle"><span class="hash">#</span><span id="roomName">rooms</span></h1>
      <span class="meta" id="roomMeta"></span>
      <span class="spacer"></span>
      <button id="notifyToggle" class="icon" title="Notify me when I'm mentioned" aria-label="Toggle mention notifications" aria-pressed="false" hidden>🔕</button>
      <button id="themeToggle" class="icon" title="Toggle light / syrup" aria-label="Toggle light or dark theme">🌙</button>
      <button id="membersToggle" class="ghost" aria-pressed="true" hidden>Members</button>
    </header>
    <div id="banner" class="banner" role="status" aria-live="polite"></div>

    <div class="content" id="content">
      <div class="stream">
        <section id="log" aria-live="polite" aria-label="Messages">
          <div class="join-wrap" id="joinScreen">
            <form id="joinForm" class="join">
              <h2>Join a room</h2>
              <p class="lead">Pick a room and a name to start chatting — capability-secure, no account.</p>
              <label for="room">Room</label>
              <input id="room" placeholder="general" value="general" aria-label="Room name" maxlength="32" />
              <label for="nick">Display name</label>
              <input id="nick" placeholder="your name" aria-describedby="nickError" maxlength="32" autofocus />
              <p id="nickError" class="error" role="alert" aria-live="polite"></p>
              <button id="joinBtn">Join room</button>
            </form>
          </div>
        </section>
        <button id="jump" class="jump" aria-label="Jump to latest messages">↓ Latest messages</button>
      </div>
      <aside class="members" id="memberPane" aria-label="Members">
        <h2>Members</h2>
        <p id="presenceSummary">Join to see who is here.</p>
        <ul id="members"></ul>
      </aside>
    </div>

    <div class="composer">
      <div id="emojiPop" class="emoji-pop" role="menu" aria-label="Emoji"></div>
      <form id="composer" hidden>
        <textarea id="line" rows="1" placeholder="Message" autocomplete="off" aria-label="Message"></textarea>
        <button type="button" id="emojiBtn" class="emoji-btn" title="Emoji" aria-label="Insert emoji">🙂</button>
        <button id="sendBtn" type="submit">Send</button>
      </form>
      <div id="hint" class="hint"><b>Enter</b> to send · <b>Shift+Enter</b> for a new line · <b>**bold**</b> · <b>*italic*</b> · <b>\`code\`</b> · <b>@name</b> · <b>:smile:</b> · <b>/me</b></div>
    </div>
  </div>
</div>
<script>
  const log = document.getElementById("log");
  const joinScreen = document.getElementById("joinScreen");
  const joinForm = document.getElementById("joinForm");
  const roomInput = document.getElementById("room");
  const nickInput = document.getElementById("nick");
  const nickError = document.getElementById("nickError");
  const joinBtn = document.getElementById("joinBtn");
  const statusEl = document.getElementById("status");
  const dot = document.getElementById("dot");
  const banner = document.getElementById("banner");
  const composer = document.getElementById("composer");
  const lineInput = document.getElementById("line");
  const sendBtn = document.getElementById("sendBtn");
  const roomListEl = document.getElementById("roomList");
  const presenceSummary = document.getElementById("presenceSummary");
  const membersEl = document.getElementById("members");
  const roomName = document.getElementById("roomName");
  const roomMeta = document.getElementById("roomMeta");
  const membersToggle = document.getElementById("membersToggle");
  const themeToggle = document.getElementById("themeToggle");
  const notifyToggle = document.getElementById("notifyToggle");
  const content = document.getElementById("content");
  const jumpBtn = document.getElementById("jump");
  const newRoomBtn = document.getElementById("newRoomBtn");
  const newRoom = document.getElementById("newRoom");
  const newRoomInput = document.getElementById("newRoomInput");
  const emojiBtn = document.getElementById("emojiBtn");
  const emojiPop = document.getElementById("emojiPop");

  const members = new Map();
  const liveRooms = new Map();
  let nick = "";
  let room = "";        // the room we are in (or want to be in)
  let joinedRoom = "";  // the room the server has confirmed us in
  let ws = null;
  let backoff = 500;
  let everConnected = false;
  let lastGroup = { from: null, at: 0 }; // for author-grouping consecutive lines
  let lastDayKey = "";  // for date dividers between days
  let unreadDivider = null; // the "new messages" marker, while present
  let unread = 0;

  // Small, swallow-errors localStorage wrapper (private-mode / disabled storage).
  const LS = {
    get(k) { try { return localStorage.getItem(k); } catch (_) { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (_) {} },
  };

  // ── Light / "syrup" dark theme, remembered across visits ────────────────
  function applyTheme(t) {
    document.documentElement.dataset.theme = t;
    themeToggle.textContent = t === "dark" ? "☀\uFE0E" : "🌙";
    themeToggle.title = t === "dark" ? "Switch to light" : "Switch to syrup (dark)";
  }
  let theme = LS.get("rooms.theme") ||
    (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
  applyTheme(theme);
  themeToggle.onclick = () => { theme = theme === "dark" ? "light" : "dark"; applyTheme(theme); LS.set("rooms.theme", theme); };

  // ── Desktop notifications when you are @mentioned (opt-in) ───────────────
  let notifyOn = LS.get("rooms.notify") === "1";
  function renderNotifyBtn() {
    notifyToggle.textContent = notifyOn ? "🔔" : "🔕";
    notifyToggle.classList.toggle("on", notifyOn);
    notifyToggle.setAttribute("aria-pressed", String(notifyOn));
  }
  notifyToggle.onclick = async () => {
    if (!notifyOn) {
      if (!("Notification" in window)) { addSystem("This browser can't show desktop notifications"); return; }
      let perm = Notification.permission;
      if (perm === "default") perm = await Notification.requestPermission();
      if (perm !== "granted") { addSystem("Notifications are blocked in your browser settings"); return; }
      notifyOn = true;
    } else notifyOn = false;
    LS.set("rooms.notify", notifyOn ? "1" : "0");
    renderNotifyBtn();
  };
  function maybeNotify(from, text) {
    if (!notifyOn || !document.hidden) return;
    if (!("Notification" in window) || Notification.permission !== "granted") return;
    try { new Notification("#" + joinedRoom + " · " + from, { body: text.slice(0, 140) }); } catch (_) {}
  }

  // A stable per-name avatar tint, drawn from pancake's warm palette (ambers,
  // teals, cocoas) so every speaker stays on-brand.
  const AVATAR = ["#c76f18","#257f88","#a4560c","#1b5f66","#b5862f","#5e8c61","#9c4a2f","#3a7d8c","#7a5c34","#2f6f78"];
  function hueOf(name) { let h = 0; for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0; return AVATAR[h % AVATAR.length]; }
  function initials(name) {
    const parts = name.replace(/[^\\p{L}\\p{N} _-]/gu, "").split(/[ _-]+/).filter(Boolean);
    if (parts.length === 0) return "?";
    return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
  }
  function fmtTime(d) {
    let h = d.getHours(), ampm = h >= 12 ? "PM" : "AM"; h = h % 12 || 12;
    return h + ":" + String(d.getMinutes()).padStart(2, "0") + " " + ampm;
  }

  // ── Rich text: :shortcode: emoji, minimal markdown, links, @mentions ─────
  const EMOJI = {
    ":smile:":"😄",":laughing:":"😆",":grin:":"😁",":joy:":"😂",":wink:":"😉",
    ":heart:":"❤️",":+1:":"👍",":-1:":"👎",":fire:":"🔥",":tada:":"🎉",":eyes:":"👀",
    ":rocket:":"🚀",":wave:":"👋",":pancakes:":"🥞",":coffee:":"☕",":thinking:":"🤔",
    ":sob:":"😭",":clap:":"👏",":100:":"💯",":ok_hand:":"👌",":star:":"⭐",":check:":"✅",
  };
  const PICKER = ["😀","😄","😂","😉","😍","🤔","😎","😭","👍","👎","👏","🙏","🔥","🎉","❤️","💯","👀","🚀","🥞","☕","✨","✅","❌","⭐"];

  function substituteEmoji(text) {
    return text.replace(/:[a-z0-9_+\\-]+:/g, (m) => EMOJI[m] || m);
  }
  function mentionsYou(text) {
    if (!nick) return false;
    const re = /@([\\w][\\w-]*)/g;
    let m;
    while ((m = re.exec(text)) !== null) { if (m[1].toLowerCase() === nick.toLowerCase()) return true; }
    return false;
  }
  // Build a safe DOM fragment — every literal goes in via textContent / .href, so
  // message text can never inject markup.
  function renderRich(text) {
    const frag = document.createDocumentFragment();
    const s = substituteEmoji(text);
    const re = /(\\x60[^\\x60]+\\x60)|(\\*\\*[^*]+\\*\\*)|(~~[^~]+~~)|(\\*[^*]+\\*)|(_[^_]+_)|(https?:\\/\\/[^\\s]+)|(@[\\w][\\w-]*)/g;
    let i = 0, m;
    while ((m = re.exec(s)) !== null) {
      if (m.index > i) frag.appendChild(document.createTextNode(s.slice(i, m.index)));
      let node;
      if (m[1]) { node = document.createElement("code"); node.textContent = m[1].slice(1, -1); }
      else if (m[2]) { node = document.createElement("strong"); node.textContent = m[2].slice(2, -2); }
      else if (m[3]) { node = document.createElement("s"); node.textContent = m[3].slice(2, -2); }
      else if (m[4]) { node = document.createElement("em"); node.textContent = m[4].slice(1, -1); }
      else if (m[5]) { node = document.createElement("em"); node.textContent = m[5].slice(1, -1); }
      else if (m[6]) {
        let url = m[6], trail = "";
        const tm = url.match(/[)\\].,!?:;]+$/);
        if (tm) { trail = tm[0]; url = url.slice(0, -trail.length); }
        const a = document.createElement("a");
        a.href = url; a.target = "_blank"; a.rel = "noopener noreferrer"; a.textContent = url;
        frag.appendChild(a);
        if (trail) frag.appendChild(document.createTextNode(trail));
        i = m.index + m[0].length;
        continue;
      } else {
        node = document.createElement("span");
        node.className = "mention" + (nick && m[7].slice(1).toLowerCase() === nick.toLowerCase() ? " you" : "");
        node.textContent = m[7];
      }
      frag.appendChild(node);
      i = m.index + m[0].length;
    }
    if (i < s.length) frag.appendChild(document.createTextNode(s.slice(i)));
    return frag;
  }
  function makeBubble(text, highlight) {
    const b = document.createElement("div");
    b.className = "bubble" + (highlight ? " hl" : "");
    b.appendChild(renderRich(text));
    return b;
  }
  // A small hover toolbar per message: copy the text, or drop an @mention of the
  // author into the composer.
  function makeActs(from) {
    const acts = document.createElement("div");
    acts.className = "acts";
    const copy = document.createElement("button");
    copy.type = "button"; copy.title = "Copy message"; copy.textContent = "Copy";
    copy.onclick = () => {
      const row = copy.closest(".row");
      const txt = [...row.querySelectorAll(".bubble")].map((b) => b.textContent).join("\\n");
      if (navigator.clipboard) navigator.clipboard.writeText(txt).catch(() => {});
    };
    const reply = document.createElement("button");
    reply.type = "button"; reply.title = "Mention " + from; reply.textContent = "@";
    reply.onclick = () => insertMention(from);
    acts.append(copy, reply);
    return acts;
  }

  // ── Day + "new messages" dividers ───────────────────────────────────────
  function dayKey(d) { return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate(); }
  function dayLabel(d) {
    const today = new Date(), yest = new Date(); yest.setDate(today.getDate() - 1);
    if (dayKey(d) === dayKey(today)) return "Today";
    if (dayKey(d) === dayKey(yest)) return "Yesterday";
    return d.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
  }
  function maybeDayDivider(now) {
    const d = new Date(now), k = dayKey(d);
    if (k === lastDayKey) return;
    lastDayKey = k;
    const div = document.createElement("div");
    div.className = "divider day";
    const span = document.createElement("span");
    span.textContent = dayLabel(d);
    div.append(span);
    log.append(div);
  }
  function ensureUnreadDivider() {
    if (unreadDivider || !joinedRoom) return;
    unreadDivider = document.createElement("div");
    unreadDivider.className = "divider unread";
    const span = document.createElement("span");
    span.textContent = "New messages";
    unreadDivider.append(span);
    log.append(unreadDivider);
  }
  function clearUnreadDivider() {
    if (unreadDivider) { unreadDivider.remove(); unreadDivider = null; }
  }

  // Append a chat line as a bubble — others on the left (with an avatar and a
  // name), you on the right. Consecutive lines from the same author within a few
  // minutes stack as extra bubbles under the one header, with the timestamp
  // following the latest bubble. "/me …" renders as an italic action narration.
  function add(from, text, mine) {
    if (text.slice(0, 4) === "/me ") { addAction(from, text.slice(4)); return; }
    const now = Date.now();
    maybeDayDivider(now);
    if (document.hidden) ensureUnreadDivider();
    const mentioned = !mine && mentionsYou(text);
    const last = log.lastElementChild;
    const grouped = lastGroup.from === from && (now - lastGroup.at) < 5 * 60 * 1000
      && last && last.classList && last.classList.contains("row") && last.dataset.from === from;
    if (grouped) {
      const stack = last.querySelector(".stack");
      const time = stack.querySelector(".time");
      stack.insertBefore(makeBubble(text, mentioned), time);
      time.textContent = fmtTime(new Date(now));
    } else {
      const row = document.createElement("div");
      row.className = "row " + (mine ? "mine" : "them");
      row.dataset.from = from;
      const stack = document.createElement("div");
      stack.className = "stack";
      if (!mine) {
        const who = document.createElement("div");
        who.className = "who";
        who.textContent = from;
        stack.append(who);
      }
      const time = document.createElement("div");
      time.className = "time";
      time.textContent = fmtTime(new Date(now));
      stack.append(makeBubble(text, mentioned), time);
      if (mine) {
        row.append(stack);
      } else {
        const av = document.createElement("div");
        av.className = "avatar";
        av.style.background = hueOf(from);
        av.textContent = initials(from);
        row.append(av, stack);
      }
      row.append(makeActs(from));
      log.append(row);
    }
    lastGroup = { from, at: now };
    if (mentioned) maybeNotify(from, text);
    afterAppend();
  }

  // An italic "/me" action narration, centered like a system line.
  function addAction(from, rest) {
    const now = Date.now();
    maybeDayDivider(now);
    if (document.hidden) ensureUnreadDivider();
    const el = document.createElement("div");
    el.className = "sys action";
    const span = document.createElement("span");
    span.textContent = "✻ " + from + " " + rest;
    el.append(span);
    log.append(el);
    lastGroup = { from: null, at: 0 };
    afterAppend();
  }

  // A centered system divider (joins, leaves, reconnects). Resets grouping so the
  // next chat line starts a fresh author block.
  function addSystem(text) {
    maybeDayDivider(Date.now());
    if (document.hidden) ensureUnreadDivider();
    const el = document.createElement("div");
    el.className = "sys";
    const span = document.createElement("span");
    span.textContent = text;
    el.append(span);
    log.append(el);
    lastGroup = { from: null, at: 0 };
    afterAppend();
  }

  // Autoscroll only when already pinned to the bottom; otherwise leave the reader
  // where they are and surface a "jump to latest" affordance. Count unread while
  // the tab is hidden so the title can badge it.
  function nearBottom() { return log.scrollHeight - log.scrollTop - log.clientHeight < 80; }
  function afterAppend() {
    if (nearBottom()) { log.scrollTop = log.scrollHeight; jumpBtn.classList.remove("show"); }
    else jumpBtn.classList.add("show");
    if (document.hidden) { unread++; updateTitle(); }
  }
  function updateTitle() {
    document.title = (unread > 0 ? "(" + unread + ") " : "") + (joinedRoom ? "#" + joinedRoom + " · " : "") + "pancake rooms";
  }

  function renderRooms() {
    const rows = [...liveRooms.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
    roomListEl.innerHTML = "";
    if (rows.length === 0) {
      const empty = document.createElement("li");
      empty.className = "empty";
      empty.textContent = "No rooms yet.";
      roomListEl.append(empty);
      return;
    }
    for (const [name, count] of rows) {
      const li = document.createElement("li");
      if (name === joinedRoom) li.className = "here";
      const hash = document.createElement("span");
      hash.className = "hash";
      hash.textContent = "#";
      const rname = document.createElement("span");
      rname.className = "rname";
      rname.textContent = name;
      const rcount = document.createElement("span");
      rcount.className = "rcount";
      rcount.textContent = count;
      li.append(hash, rname, rcount);
      li.onclick = () => pickRoom(name);
      roomListEl.append(li);
    }
  }

  // Clicking a room either fills the join field (before you join) or switches
  // you into it (once you have a name and are connected).
  function pickRoom(name) {
    if (joinedRoom && nick && ws && ws.readyState === WebSocket.OPEN) {
      if (name === joinedRoom) return;
      switchRoom(name);
    } else {
      roomInput.value = name;
      nickInput.focus();
    }
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
    if (joinedRoom) roomMeta.textContent = online + " online";
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
      const pip = document.createElement("span");
      pip.className = "pip";
      const who = document.createElement("span");
      who.className = "name";
      who.textContent = name === nick ? name + " (you)" : name;
      li.append(pip, who);
      membersEl.append(li);
    }
  }

  function setStatus(state, text) {
    dot.className = "dot " + state;
    statusEl.textContent = text;
  }

  function setJoinError(text) {
    nickError.textContent = text;
    nickInput.setAttribute("aria-invalid", text ? "true" : "false");
  }

  function setBanner(text) {
    if (text) { banner.textContent = text; banner.classList.add("show"); }
    else banner.classList.remove("show");
  }

  function send(msg) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
  }

  function setComposerEnabled(on) {
    lineInput.disabled = !on;
    sendBtn.disabled = !on;
    emojiBtn.disabled = !on;
    lineInput.placeholder = joinedRoom ? ("Message #" + joinedRoom) : "Message";
  }

  // Show the chat view for the room the server just confirmed.
  function enterView(name) {
    joinedRoom = name;
    members.clear();
    renderPresence();
    renderRooms();
    log.innerHTML = "";
    lastGroup = { from: null, at: 0 };
    lastDayKey = "";
    unreadDivider = null;
    joinScreen.style.display = "none";
    composer.hidden = false;
    membersToggle.hidden = false;
    notifyToggle.hidden = false;
    renderNotifyBtn();
    roomName.textContent = name;
    setComposerEnabled(true);
    setStatus("connected", "connected as " + nick);
    LS.set("rooms.nick", nick);
    LS.set("rooms.room", name);
    updateTitle();
    lineInput.focus();
  }

  function switchRoom(name) {
    room = name;
    setStatus("connecting", "entering #" + name + "…");
    send({ join: { room: name, nick } });
  }

  function rejectJoin(text) {
    composer.hidden = true;
    membersToggle.hidden = true;
    joinScreen.style.display = "";
    joinBtn.disabled = false;
    joinBtn.textContent = "Join room";
    setJoinError(text);
    setStatus("disconnected", "pick another name");
  }

  function connect() {
    setStatus("connecting", everConnected ? "reconnecting…" : "connecting…");
    if (everConnected && joinedRoom) setBanner("Disconnected — reconnecting…");
    const proto = location.protocol === "https:" ? "wss://" : "ws://";
    ws = new WebSocket(proto + location.host + "/ws");

    ws.onopen = () => {
      backoff = 500;
      setBanner("");
      if (everConnected && joinedRoom) addSystem("Reconnected");
      everConnected = true;
      // If we were in a room, replay the join to be put back; otherwise wait for
      // the user to pick one. Either way the room list arrives shortly.
      if (joinedRoom && nick) { setStatus("connecting", "rejoining #" + joinedRoom + "…"); send({ join: { room: joinedRoom, nick } }); }
      else setStatus("connecting", "pick a room");
    };
    ws.onmessage = (event) => {
      let m;
      try { m = JSON.parse(event.data); } catch (_) { return; } // ignore malformed frames
      if (m.rooms) {
        liveRooms.clear();
        for (const [name, count] of m.rooms) liveRooms.set(name, Number(count));
        renderRooms();
        return;
      }
      if (m.nameTaken) { rejectJoin(m.nameTaken); return; }
      if (m.notice) { addSystem(m.notice); return; }
      if (m.joined) { enterView(m.joined); return; }
      if (m.presence) applyPresence(m.presence);
      if (m.from === "room") addSystem(m.text);
      else if (typeof m.from === "string") add(m.from, m.text, m.from === nick);
    };
    ws.onclose = () => {
      setStatus("reconnecting", "reconnecting…");
      if (joinedRoom) setBanner("Disconnected — reconnecting…");
      setComposerEnabled(false);
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, 5000); // back off, capped at 5s
    };
    ws.onerror = () => { try { ws.close(); } catch (_) {} };
  }

  function join() {
    nick = (nickInput.value || "guest").trim().slice(0, 32);
    room = (roomInput.value || "general").trim().slice(0, 32);
    if (!nick || !room) return;
    joinBtn.disabled = true;
    joinBtn.textContent = "Joining…";
    setJoinError("");
    setStatus("connecting", "entering #" + room + "…");
    send({ join: { room, nick } });
  }

  // Inline "+" room creation: open or switch to whatever you type.
  newRoomBtn.onclick = () => {
    newRoom.classList.toggle("show");
    if (newRoom.classList.contains("show")) newRoomInput.focus();
  };
  newRoomInput.onkeydown = (e) => {
    if (e.key === "Escape") { newRoom.classList.remove("show"); return; }
    if (e.key !== "Enter") return;
    const name = newRoomInput.value.trim().slice(0, 32);
    if (!name) return;
    newRoomInput.value = "";
    newRoom.classList.remove("show");
    pickRoom(name);
  };

  membersToggle.onclick = () => {
    const hidden = content.classList.toggle("no-members");
    membersToggle.setAttribute("aria-pressed", String(!hidden));
  };

  jumpBtn.onclick = () => { log.scrollTop = log.scrollHeight; jumpBtn.classList.remove("show"); };
  log.addEventListener("scroll", () => { if (nearBottom()) jumpBtn.classList.remove("show"); });

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) { unread = 0; updateTitle(); setTimeout(clearUnreadDivider, 1500); }
  });

  // ── Composer: auto-growing multiline, Enter sends / Shift+Enter newline ──
  function autoGrow() {
    lineInput.style.height = "auto";
    lineInput.style.height = Math.min(lineInput.scrollHeight, 140) + "px";
  }
  function sendMessage() {
    const text = lineInput.value.trim();
    if (!text) return;
    if (ws && ws.readyState === WebSocket.OPEN) {
      send({ say: text });
      lineInput.value = "";
      autoGrow();
    } else {
      addSystem("Not connected — your message was not sent");
    }
  }
  function insertMention(name) {
    if (lineInput.disabled) return;
    const v = lineInput.value;
    const sep = v && !/\\s$/.test(v) ? " " : "";
    lineInput.value = v + sep + "@" + name + " ";
    lineInput.focus();
    autoGrow();
  }
  function insertAtCursor(s) {
    const start = lineInput.selectionStart != null ? lineInput.selectionStart : lineInput.value.length;
    const end = lineInput.selectionEnd != null ? lineInput.selectionEnd : lineInput.value.length;
    lineInput.value = lineInput.value.slice(0, start) + s + lineInput.value.slice(end);
    const pos = start + s.length;
    lineInput.selectionStart = lineInput.selectionEnd = pos;
    autoGrow();
  }
  lineInput.addEventListener("input", autoGrow);
  lineInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      if (composer.requestSubmit) composer.requestSubmit(); else sendMessage();
    }
  });
  composer.onsubmit = (e) => { e.preventDefault(); sendMessage(); };

  // ── Emoji picker ────────────────────────────────────────────────────────
  for (const e of PICKER) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = e;
    b.onclick = () => { insertAtCursor(e); emojiPop.classList.remove("show"); lineInput.focus(); };
    emojiPop.append(b);
  }
  emojiBtn.onclick = () => { if (!emojiBtn.disabled) emojiPop.classList.toggle("show"); };
  document.addEventListener("click", (e) => {
    if (!emojiPop.contains(e.target) && e.target !== emojiBtn) emojiPop.classList.remove("show");
  });

  joinForm.onsubmit = (e) => {
    e.preventDefault();
    join();
  };

  // Prefill the join form from the last visit, so returning is one click.
  const savedNick = LS.get("rooms.nick");
  if (savedNick) nickInput.value = savedNick;
  const savedRoom = LS.get("rooms.room");
  if (savedRoom) roomInput.value = savedRoom;
  if (savedNick) joinBtn.focus();

  renderNotifyBtn();
  setComposerEnabled(false);
  renderPresence();
  renderRooms();
  updateTitle();
  connect();
</script>
</body>
</html>`;
