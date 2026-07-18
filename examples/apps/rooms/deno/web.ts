// A browser UI for the rooms chat, served by Deno.
//
// A browser cannot speak raw TCP/OCapN, so this process stands in the middle: it
// serves a web page, and for each browser tab it opens its own pancake connection
// to the directory and bridges the two.
//
//   browser ──WebSocket──▶ web.ts (a pancake connection) ──TCP/OCapN──▶ rooms server
//
// The WebSocket between the browser and web.ts is a plaintext control channel,
// not the OCapN wire. So the page's "encrypted" label is about the OCapN hop past
// web.ts, not this one, which stays on loopback in development and is `wss://`
// once the page is served over HTTPS.
//
// Each tab's connection holds several things at once on one wire: a live `watch` of
// the directory (so the browser shows the rooms that have people in them, updating
// as they come and go), the current room membership, and the ability to switch —
// leave one room and enter another — without reconnecting. The page shows the
// live room list before you even pick a name, and lets you hop between rooms once
// you are in.
//
// It also carries direct messages by introduction, which is where OCapN earns its
// keep. The bridge listens on the same Host as the directory session, publishes a
// giftable `dm` there for register/`fetch`, and when you direct-message someone
// asks the directory to introduce you. The directory answers with a three-party
// handoff give, and the binding redeems it by dialing that member directly. Your
// messages then travel straight to the other person, and the room server is no
// longer on the path they take.
//
// It is built to survive interruption. It supervises the room server and respawns
// it if it dies; if it attached to a server another web.ts already owned and that
// server later goes away, it takes ownership rather than serving a dead locator.
// The browser reconnects on its own and replays its join, so restarting this
// process (to pick up a code change, say) just shows "reconnecting…" and recovers.
//
//   deno run --allow-ffi --allow-read --allow-net --allow-run web.ts
//
// Open the printed URL. It also prints the room's locator, so you can join from
// a terminal (`chat.ts <locator> <room> <nick>`) at the same time.

import { type Behavior, formatPeerUri, type Host, listen, TRANSPORT_IROH } from "@pancake/stack";
import { listenIroh, Reachability } from "@pancake/iroh";
import { DirectMessage, Directory, Room } from "./lib/room_client.ts";
import { enterOrOpen } from "./lib/enter_room.ts";
import { ANNOUNCE_RE, announceToLocator, loopbackTcpDesignator } from "./lib/locator.ts";
import { DM } from "./lib/protocol.ts";
import {
	dmArgsRefuseNotice,
	Inbound,
	MAX_LINE,
	MAX_NICK,
	MAX_ROOM,
	type Outbound,
} from "./lib/wire.ts";
import { NICK_TAKEN, PEER_OFFLINE, roomErrorOf } from "./lib/errors.ts";

// Positional args are the HTTP port and the room port; flags start with `--`.
const flags = Deno.args.filter((a) => a.startsWith("--"));
const positional = Deno.args.filter((a) => !a.startsWith("--"));
const HTTP_PORT = Number(positional[0] ?? "8000");
// A fixed room port (override as the 2nd positional arg) so a TCP room is stable
// across server restarts and CLI clients always know where to connect.
const ROOM_PORT = positional[1] ?? "9099";
// `--transport=iroh` (or `ROOMS_TRANSPORT=iroh`) runs the room over iroh, and the
// server then announces an ocapn:// URI, so ROOM_PORT is ignored. The env var is a
// convenience for manual runs and is read only when env access is granted, so the
// default permission set never trips.
const flagTransport = flags.find((a) => a.startsWith("--transport="))?.slice("--transport=".length);
const envAllowed = Deno.permissions.querySync({ name: "env", variable: "ROOMS_TRANSPORT" })
	.state === "granted";
const chosenTransport = flagTransport ?? (envAllowed ? Deno.env.get("ROOMS_TRANSPORT") : undefined);
const TRANSPORT = chosenTransport === "iroh" ? "iroh" : "tcp";
const reachEnvAllowed = Deno.permissions.querySync({ name: "env", variable: "ROOMS_REACHABILITY" })
	.state === "granted";
const reachChoice = (reachEnvAllowed ? Deno.env.get("ROOMS_REACHABILITY") : undefined)
	?.toLowerCase();
const IROH_REACH = reachChoice === "discovery" ? Reachability.Discovery : Reachability.Direct;
const ROOT = new URL(".", import.meta.url).pathname;
const DENO_FLAGS = TRANSPORT === "iroh"
	? ["run", "-A", "--unstable-ffi"]
	: ["run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env"];

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

// One stray async error in a tab's bridge, or a transport hiccup, must never take
// the whole server down. Roots are handled where they occur; this backstop keeps
// the long-running process alive and logs anything that still slips through.
globalThis.addEventListener("unhandledrejection", (event) => {
	event.preventDefault();
	console.error("rooms: unhandled rejection (continuing):", event.reason);
});

// The room server runs as a supervised child process. `roomLocator` always points
// at the live one; when it exits, the respawn loop brings it back, so the rooms
// outlive a crash and tabs reconnect and replay their join. Aborting `shutdown`
// ends the loop when the process is stopping.
const shutdown = new AbortController();
let roomLocator = "";
let child: Deno.ChildProcess | null = null;

function spawnRoomServer(): Deno.ChildProcess {
	const serverArgs = TRANSPORT === "iroh"
		? [`${ROOT}server.ts`, "--transport=iroh"]
		: [`${ROOT}server.ts`, ROOM_PORT];
	return new Deno.Command("deno", {
		args: [...DENO_FLAGS, ...serverArgs],
		stdout: "piped",
		stderr: "inherit",
	}).spawn();
}

// Stop the room child if we spawned one (in attach mode there is none). A function
// so `child` keeps its declared type instead of being narrowed at a call site.
function killChild(): void {
	try {
		child?.kill("SIGTERM");
	} catch { /* already gone */ }
}

// Whether the fixed TCP room port is already bound — an orphaned server from a
// previous run, say. iroh has no fixed port to probe, so this only applies to TCP.
function roomPortInUse(): boolean {
	if (TRANSPORT !== "tcp") return false;
	try {
		Deno.listen({ hostname: "127.0.0.1", port: Number(ROOM_PORT) }).close();
		return false;
	} catch {
		return true;
	}
}

// Whether `locator` answers as a rooms directory. Used to tell an orphaned rooms
// server (which we can attach to) from something unrelated holding the port.
async function isRoomsServer(locator: string): Promise<boolean> {
	try {
		const dir = await Directory.connect(locator);
		await dir.close();
		return true;
	} catch {
		return false;
	}
}

// Own the room child: when it exits, respawn until `shutdown` aborts.
// Shared by the spawn path and by attach-mode take-over (so one loop, not two).
async function respawnOwnedServer(): Promise<void> {
	while (!shutdown.signal.aborted) {
		const owned = child;
		if (owned === null) {
			await delay(100);
			continue;
		}
		const status = await owned.status;
		if (shutdown.signal.aborted) return;
		console.error(`rooms: room server exited (code ${status.code}); restarting…`);
		try {
			child = spawnRoomServer();
			roomLocator = await readRoomLocator(child);
		} catch (err) {
			console.error("rooms: room server respawn failed:", err);
			child = null;
			await delay(500);
		}
	}
}

// Attach mode left us without a child. Poll the shared locator; if that server
// dies (the owning web.ts exited and tore it down, or an orphan crashed), take
// ownership by spawning — do not keep serving HTTP against a dead room forever.
// That was the lifecycle hole: attach was convenient, then unsupervised.
async function watchAttachedServer(): Promise<void> {
	const probeMs = 2_000;
	while (!shutdown.signal.aborted) {
		await delay(probeMs);
		if (shutdown.signal.aborted) return;
		if (await isRoomsServer(roomLocator)) continue;

		console.error("rooms: attached room server is gone; taking over…");
		if (roomPortInUse()) {
			const existing = loopbackTcpDesignator(Number(ROOM_PORT));
			if (await isRoomsServer(existing)) {
				roomLocator = existing;
				console.error(
					`rooms: another rooms server reclaimed port ${ROOM_PORT}; re-attaching.`,
				);
				continue;
			}
			console.error(
				`rooms: port ${ROOM_PORT} is held by something that is not a rooms server after the attached server died.`,
			);
			shutdown.abort();
			Deno.exit(1);
		}
		try {
			child = spawnRoomServer();
			roomLocator = await readRoomLocator(child);
			console.error(`rooms: now supervising room server at ${roomLocator}`);
			await respawnOwnedServer();
			return;
		} catch (err) {
			console.error("rooms: take-over spawn failed:", err);
			child = null;
			await delay(500);
		}
	}
}

async function superviseServer(): Promise<void> {
	// If the room port is already taken, don't fight it. When a previous web.ts
	// left its server running, attach to that server instead of failing to bind —
	// and watch it so we take ownership if it later dies. When something unrelated
	// holds the port, say so plainly and stop.
	if (roomPortInUse()) {
		const existing = loopbackTcpDesignator(Number(ROOM_PORT));
		if (await isRoomsServer(existing)) {
			roomLocator = existing;
			console.error(
				`rooms: a room server is already running on port ${ROOM_PORT}; attaching to it.`,
			);
			void watchAttachedServer();
			return;
		}
		console.error(
			`rooms: port ${ROOM_PORT} is already in use by something that is not a rooms server.\n` +
				`       Stop it, or start with a free room port, for example:\n` +
				`       deno run --allow-ffi --allow-read --allow-net --allow-run ${ROOT}web.ts ${HTTP_PORT} 9100`,
		);
		Deno.exit(1);
	}

	child = spawnRoomServer();
	try {
		roomLocator = await readRoomLocator(child);
	} catch (err) {
		try {
			child.kill("SIGTERM");
		} catch { /* already gone */ }
		child = null;
		console.error(
			`rooms: the room server did not start: ${err instanceof Error ? err.message : err}`,
		);
		Deno.exit(1);
	}
	// Watch the live child and respawn it when it exits, until we are shutting
	// down. This runs in the background; the first locator is already in hand.
	void respawnOwnedServer();
}

await superviseServer();
console.log(`rooms web UI:   http://localhost:${HTTP_PORT}`);
console.log(`rooms locator:  http://localhost:${HTTP_PORT}/locator`);
console.log(
	`rooms server:   ${roomLocator}  (join from a terminal too:`,
);
console.log(
	`                deno ${DENO_FLAGS.join(" ")} ${ROOT}chat.ts ${roomLocator} <room> <nick>)`,
);

// The browser UI lives in ui/: page.html, page.css, and a set of TypeScript modules
// entered through main.ts. page.html and page.css are read fresh on each request, so
// editing them shows on a browser refresh with no restart. The modules are authored in
// TypeScript (ui/deno.json targets the DOM libs) and served as JavaScript: a pre-built
// ui/page.js is used if present — the deploy builds it ahead of time with `deno bundle`,
// so its runtime needs no network — otherwise the bundle runs once here at startup (a
// module edit needs a restart to re-bundle). Everything is served with no-store, so a
// browser always fetches the current build.
const UI_DIR = `${ROOT}ui/`;
// Not minified, so the served bundle stays readable in the browser's view-source; the
// bundle carries zod, so it is roughly 150 KB. A production build can shrink it a lot
// by adding "--minify" to a pre-built page.js (see deploy/README.md).
async function bundleClient(): Promise<string> {
	const { code, stdout, stderr } = await new Deno.Command("deno", {
		args: ["bundle", "--platform", "browser", "--no-lock", "--quiet", `${UI_DIR}main.ts`],
		stdout: "piped",
		stderr: "piped",
	}).output();
	if (code !== 0) {
		throw new Error(new TextDecoder().decode(stderr).trim() || "deno bundle failed");
	}
	return new TextDecoder().decode(stdout);
}
async function clientJs(): Promise<string> {
	try {
		return await Deno.readTextFile(`${UI_DIR}page.js`); // pre-built (the deploy path)
	} catch {
		return await bundleClient(); // bundle on the fly (the dev default)
	}
}
let pageJs: string;
try {
	pageJs = await clientJs();
} catch (err) {
	console.error(`rooms: could not build the browser UI: ${reasonOf(err)}`);
	shutdown.abort();
	killChild();
	Deno.exit(1);
}

// no-store so a browser (iOS Safari especially) never serves a stale asset after the
// server is updated — every load fetches the current build.
function asset(body: string, type: string): Response {
	return new Response(body, {
		headers: { "content-type": type, "cache-control": "no-store" },
	});
}
// Read a UI file fresh for each request, so editing page.html or page.css shows on a
// browser refresh without restarting this process.
async function serveUi(name: string, type: string): Promise<Response> {
	try {
		return asset(await Deno.readTextFile(`${UI_DIR}${name}`), type);
	} catch (err) {
		return new Response(`rooms: could not read ui/${name}: ${reasonOf(err)}`, { status: 500 });
	}
}

try {
	Deno.serve({ port: HTTP_PORT, signal: shutdown.signal }, (req) => {
		const url = new URL(req.url);
		if (url.pathname === "/ws") {
			const { socket, response } = Deno.upgradeWebSocket(req);
			// One tab's bridge failing must not take the server down with it.
			bridge(socket).catch((err) => console.error("bridge ended:", err?.message ?? err));
			return response;
		}
		// CapTP peers (rooms-peer) bootstrap the live ocapn:// locator over HTTP
		// on the shared Docker network, then dial via iroh Discovery — not CapTP
		// over this port.
		if (url.pathname === "/locator") {
			if (!roomLocator) {
				return new Response("rooms: locator not ready\n", { status: 503 });
			}
			return new Response(`${roomLocator}\n`, {
				headers: {
					"content-type": "text/plain; charset=utf-8",
					"cache-control": "no-store",
				},
			});
		}
		if (url.pathname === "/page.js") return asset(pageJs, "text/javascript; charset=utf-8");
		if (url.pathname === "/page.css") return serveUi("page.css", "text/css; charset=utf-8");
		return serveUi("page.html", "text/html; charset=utf-8");
	});
} catch (err) {
	// The usual cause is a second web.ts on the same HTTP port; say so and stop the
	// child we just started rather than leave it orphaned.
	console.error(
		`rooms: could not serve on http port ${HTTP_PORT} (${
			err instanceof Error ? err.message : err
		}).\n` +
			`       Another rooms web UI may already be on it; try a different port, e.g. web.ts ${
				HTTP_PORT + 1
			}`,
	);
	shutdown.abort();
	killChild();
	Deno.exit(1);
}

// The browser-to-bridge protocol is defined once, as zod schemas, in lib/wire.ts:
// `Inbound` is what the browser sends us (validated below before we act on it), and
// `Outbound` is everything we send back (so `safeSend` is type-checked against it).
function safeSend(ws: WebSocket, msg: Outbound): void {
	if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

function safeClose(ws: WebSocket): void {
	try {
		ws.close();
	} catch { /* already closed */ }
}

/** Map a zod `too_big` failure to an honest notice — never claim a nick/room
 * overflow was a "message too long". */
function oversizeInboundNotice(
	issues: ReadonlyArray<{ code: string; path: PropertyKey[] }>,
): string | null {
	for (const issue of issues) {
		if (issue.code !== "too_big") continue;
		const leaf = String(issue.path[issue.path.length - 1] ?? "");
		if (leaf === "nick" || leaf === "to") {
			return `name too long (max ${MAX_NICK} characters)`;
		}
		if (leaf === "room") {
			return `room name too long (max ${MAX_ROOM} characters)`;
		}
		return `message too long (max ${MAX_LINE} characters)`;
	}
	return null;
}

// Dialable DM member on the same Host as the directory session: publish `dm`
// for register/`fetch`, listen for inbound redeem. Messages arrive via `onDm`.
async function startDmMember(
	host: Host,
	session: { publish(name: string, behavior: Behavior): unknown },
	onDm: (from: string, text: string) => void,
	onRefuse: (notice: string) => void,
): Promise<{ locator: string; close: () => void }> {
	const relay: Behavior = (verb, args) => {
		if (verb !== DM) return null;
		const from = String(args[0] ?? "");
		const text = String(args[1] ?? "");
		const refuse = dmArgsRefuseNotice(from, text);
		if (refuse) {
			onRefuse(refuse);
			return null;
		}
		onDm(from, text);
		return null;
	};
	host.publishGiftable("dm", relay);
	session.publish("dm", relay);
	const accept = (server: AsyncIterable<{ serve(): Promise<unknown> }>) =>
		void (async () => {
			try {
				for await (const s of server) s.serve().catch(() => {});
			} catch { /* the listener closed */ }
		})();
	const closer = (server: { close: () => void }) => () => {
		try {
			server.close();
		} catch { /* already gone */ }
	};
	if (TRANSPORT === "iroh") {
		const server = listenIroh(IROH_REACH, host.seed, host);
		accept(server);
		const locator = IROH_REACH === Reachability.Discovery
			? formatPeerUri(TRANSPORT_IROH, server.nodeId)
			: server.uri;
		return { locator, close: closer(server) };
	}
	const server = listen("127.0.0.1", 0, host);
	accept(server);
	const port = await server.ready();
	return { locator: loopbackTcpDesignator(port), close: closer(server) };
}

function reasonOf(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}

// Bridge one browser tab. On a single directory connection this streams the live
// room list, follows the browser through join, switch, and say as one room
// membership, and makes the tab a DM member so it can be introduced to other
// members and message them directly.
async function bridge(ws: WebSocket): Promise<void> {
	// The browser may send before the directory is ready, so wire its handlers up
	// first and buffer anything that arrives early.
	const pending: Inbound[] = [];
	let onInbound: ((m: Inbound) => void) | null = null;
	let onSocketClose = () => {};
	// When we last heard from this tab. Any frame — a message or a bare keepalive
	// ping — refreshes it; the liveness timer below drops the tab if it goes quiet.
	let lastSeen = Date.now();
	ws.onmessage = (event) => {
		lastSeen = Date.now();
		let raw: unknown;
		try {
			raw = JSON.parse(String(event.data));
		} catch {
			return;
		}
		// Validate against the wire schema before acting: anything that is not a known
		// Inbound message is dropped, so a malformed or hostile frame never reaches `handle`.
		// Oversize lines fail the schema instead of being silently truncated — tell the
		// tab so a half-delivered script cannot look like a successful send.
		const parsed = Inbound.safeParse(raw);
		if (!parsed.success) {
			const notice = oversizeInboundNotice(parsed.error.issues);
			if (notice) safeSend(ws, { notice });
			return;
		}
		if (onInbound) onInbound(parsed.data);
		else pending.push(parsed.data);
	};
	ws.onclose = () => onSocketClose();

	const dir = await connectDirectory();
	if (!dir) {
		safeSend(ws, { notice: "the room server is unavailable, reconnecting…" });
		safeClose(ws);
		return;
	}

	// Per-tab DM state: our own member peer that others dial, one direct line per
	// peer we message, and the nick we message under. The line is cached as the
	// in-flight introduction, not the resolved thread, so two quick messages to the
	// same peer share one introduction instead of redeeming two.
	let dmMember: { locator: string; close: () => void } | null = null;
	const dmThreads = new Map<string, Promise<DirectMessage>>();
	let myNick = "";

	// Liveness: a tab that vanished — a crash, a killed bot, a dropped network —
	// never sends a WebSocket close, so its socket stays half-open and its room
	// membership would orphan, shown online to everyone forever. The page pings on
	// a steady beat; if we hear nothing for `LIVENESS_MS`, close the socket so the
	// teardown below runs and the room drops us like any clean departure.
	const LIVENESS_MS = 45_000;
	const liveness = setInterval(() => {
		if (Date.now() - lastSeen > LIVENESS_MS) safeClose(ws); // closes into ws.onclose / onSocketClose
	}, 15_000);

	// Closing the tab stops its liveness timer and closes its DM peer and directory
	// connection together.
	onSocketClose = () => {
		clearInterval(liveness);
		dmMember?.close();
		void dir.close().catch(() => {});
	};

	const rooms = new Map<string, number>();
	const dmable = new Set<string>();
	const sendRooms = () => safeSend(ws, { rooms: [...rooms.entries()] });
	const sendDmable = () => safeSend(ws, { dmable: [...dmable] });

	// One observer carries every change to the directory's live state. Room events
	// keep the room list; member events keep the set of people you can DM. Switch
	// on the kind to route each one.
	try {
		for (
			const room of await dir.watch((event) => {
				switch (event.kind) {
					case "closed":
						rooms.delete(event.name);
						sendRooms();
						break;
					case "registered":
						dmable.add(event.name);
						sendDmable();
						break;
					case "unregistered":
						dmable.delete(event.name);
						sendDmable();
						// The peer's endpoint just died. Any direct line we hold names that
						// dead endpoint, so drop it: the next message re-introduces against
						// whatever endpoint the peer registers if and when it returns.
						dropThread(event.name);
						break;
					default:
						rooms.set(event.name, event.count);
						sendRooms();
						break;
				}
			})
		) rooms.set(room.name, room.count);
	} catch {
		await dir.close();
		safeClose(ws);
		return;
	}
	sendRooms();
	sendDmable();

	// If the directory connection drops (the server respawning), end the tab; the
	// browser reconnects and gets a fresh directory. A dropped connection makes
	// serve() reject, so catch it: the drop is expected, not a crash.
	dir.session.serve().finally(() => safeClose(ws)).catch(() => {});

	let current: Room | null = null;

	// Make this tab a DM member on the directory session's Host: publish `dm`,
	// listen for redeem, register. Runs once; later room switches reuse it.
	async function ensureDmMember(nick: string): Promise<void> {
		if (dmMember) return;
		myNick = nick;
		dmMember = await startDmMember(
			dir!.session.host,
			dir!.session,
			(from, text) => safeSend(ws, { dmFrom: { peer: from, text } }),
			(notice) => safeSend(ws, { notice }),
		);
		safeSend(ws, { dmSelf: { nick, transport: TRANSPORT } });
		dir!.register(nick, dmMember.locator).catch(() => {});
	}

	// Enter `name` as `nick`, leaving the current room first. Subscribe before
	// leaving, so a rejected claim leaves the current room intact.
	async function join(name: string, nick: string): Promise<void> {
		try {
			const ref = await enterOrOpen(dir!, name);
			// Forward every other member's typing flag straight to the browser; the
			// signal never enters the message stream, so it is a pure presence hint.
			const next = await Room.subscribe(
				dir!.session,
				ref,
				nick,
				(from, on) => safeSend(ws, { typing: { from, on } }),
			);
			if (current) await current.leave();
			current = next;
			safeSend(ws, { joined: name });
			pump(next);
			ensureDmMember(nick).catch(() => {});
		} catch (err) {
			// Branch on the typed code, not on the prose: a claimed nick is a re-prompt,
			// anything else is a plain notice.
			const re = roomErrorOf(err);
			if (re?.code === NICK_TAKEN) safeSend(ws, { nameTaken: re.detail });
			else safeSend(ws, { notice: reasonOf(err) });
		}
	}

	// Forward a room's lines to the browser until it ends (we switched away, or
	// the room hung up).
	async function pump(room: Room): Promise<void> {
		try {
			for await (const { from, text, system, presence } of room.messages) {
				safeSend(ws, {
					from: system ? "room" : from,
					text,
					presence: presence ?? null,
				});
			}
		} catch { /* the stream ended under us */ }
	}

	// Forget any direct line we hold to `peer`. A redeemed line names one endpoint;
	// once that endpoint is gone — the peer left, or the direct path broke — the
	// cached line can never reach the peer again, so the next `openDm` must
	// re-introduce against the peer's current registration rather than reuse it.
	function dropThread(peer: string): void {
		dmThreads.delete(peer.toLowerCase());
	}

	// Open a direct line to `peer`, or reuse the one we already hold. Opening it
	// asks the directory to introduce us; the binding redeems that introduction onto
	// a fresh connection straight to the peer, so every later `say` on the returned
	// thread travels peer-to-peer. `dmReady` tells the browser the line is live.
	// Concurrent callers share the one in-flight introduction, so `dmReady` fires
	// once and only one connection is redeemed.
	function openDm(peer: string): Promise<DirectMessage> {
		const key = peer.toLowerCase();
		const existing = dmThreads.get(key);
		if (existing) return existing;
		const opening = (async () => {
			const thread = await DirectMessage.open(dir!, peer);
			safeSend(ws, { dmReady: { peer, transport: TRANSPORT } });
			return thread;
		})();
		// A failed introduction must not stay cached as a rejected promise, or every
		// later attempt would replay the failure instead of introducing afresh. Only
		// clear our own entry, in case an unregister already replaced it.
		opening.catch(() => {
			if (dmThreads.get(key) === opening) dmThreads.delete(key);
		});
		dmThreads.set(key, opening);
		return opening;
	}

	async function dmOpen(peer: string): Promise<void> {
		try {
			await openDm(peer);
		} catch (err) {
			safeSend(ws, { dmFailed: { peer, offline: roomErrorOf(err)?.code === PEER_OFFLINE } });
		}
	}

	async function dmSay(peer: string, text: string): Promise<void> {
		try {
			await (await openDm(peer)).say(myNick, text);
		} catch (err) {
			// The line we just used is broken; forget it so the next attempt
			// re-introduces instead of failing on the same dead reference.
			dropThread(peer);
			safeSend(ws, {
				dmFailed: { peer, text, offline: roomErrorOf(err)?.code === PEER_OFFLINE },
			});
		}
	}

	// `m` is already validated against the wire schema, so the fields are the
	// declared types with length caps already applied — do not silently re-slice.
	const handle = (m: Inbound): void => {
		if ("say" in m) {
			current?.say(m.say).catch(() => {});
		} else if ("typing" in m) {
			current?.setTyping(m.typing).catch(() => {});
		} else if ("join" in m) {
			join(m.join.room, m.join.nick);
		} else if ("dmOpen" in m) {
			dmOpen(m.dmOpen.to);
		} else if ("dmSay" in m) {
			dmSay(m.dmSay.to, m.dmSay.text);
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

// Stop cleanly when interrupted: end the respawn loop, close the HTTP server (its
// abort signal), stop the room child, then exit.
function stop(): void {
	shutdown.abort();
	killChild();
	Deno.exit(0);
}
Deno.addSignalListener("SIGINT", stop);
Deno.addSignalListener("SIGTERM", stop);
