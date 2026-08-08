// DENO-SPECIFIC: The rooms chat host process for Deno.
// It serves the browser page and stays out of the OCapN wire.
//
// The page is a real pancake peer. It loads `@pancake/web` (the wasm Host) and
// dials the room server itself; this process only serves the page, the wasm
// module, and one dumb byte pipe:
//
//   browser peer ──WebSocket (/relay)──▶ serve.ts ──TCP──▶ rooms server
//
// `/relay?target=<locator>` upgrades to a WebSocket and pipes bytes to the far
// side the locator names (a `host:port` over TCP, an `ocapn://` URI over iroh)
// without parsing them, so the keyed OCapN session rides through end to end and
// the relay never holds a capability. It is `ws://` on loopback in development
// and `wss://` once the page is served over HTTPS. TCP relay reaches only the
// room server; iroh relay accepts any ocapn:// URI (verified by keyed
// handshake), enabling third-party handoff for browser-peer direct messages.
// A cold-dial to a browser is a bridge, not a dial: `/relay?rendezvous=<id>`.
//
// This process also supervises the room server as a child: it respawns it if it
// dies, and if it attached to a server another serve.ts already owned and that
// server later goes away, it takes ownership rather than serving a dead locator.
// The browser reconnects on its own and replays its join, so restarting this
// process (to pick up a code change, say) just shows "reconnecting…" and recovers.
//
//   deno run --allow-ffi --allow-read --allow-net --allow-run serve.ts
//
// Open the printed URL. It also prints the room's locator, so you can join from
// a terminal (`chat.ts <locator> <room> <nick>`) at the same time.

import { Directory } from "../lib/room_client.ts";
import { classifyRelayTarget, type RelayTarget } from "@pancake/stack";
import { dial, loopbackTcpDesignator, readAnnouncedLocator } from "../lib/locator.ts";
import {
	bridgeRendezvous,
	parseTcpPeers,
	registerRendezvous,
	relayAllowed,
	relayOriginAllowed,
	relayToTarget,
} from "./relay.ts";

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
// The live timeline endpoint the room server serves when ROOMS_VIZ_PORT is set
// (the child inherits this environment). The page asks for it at `/viz` and
// publishes its own trace there, which is the only way a direct message — a
// session between two members that this server never carries — reaches the
// timeline. Empty when tracing is off, and the page then installs no tap.
const vizEnvAllowed = Deno.permissions.querySync({ name: "env", variable: "ROOMS_VIZ_PORT" })
	.state === "granted";
const VIZ_PORT = (vizEnvAllowed ? Deno.env.get("ROOMS_VIZ_PORT")?.trim() : undefined) ?? "";
// Cleartext-TCP peers a browser may open a direct message to, as
// `host:port,host:port`. The relay dials iroh anywhere and TCP only where it is
// told, because a TCP address can be any service on the network rather than an
// OCapN peer holding a key (`relayAllowed`). A member reachable only over
// cleartext TCP — a Goblins vat on a TCP netlayer — belongs here; one on iroh
// needs no entry.
const tcpPeersAllowed = Deno.permissions.querySync({
	name: "env",
	variable: "PANCAKE_RELAY_TCP_PEERS",
}).state === "granted";
const RELAY_TCP_PEERS = parseTcpPeers(
	tcpPeersAllowed ? Deno.env.get("PANCAKE_RELAY_TCP_PEERS") : undefined,
);
const ROOT = new URL(".", import.meta.url).pathname;
// `--no-lock` on both arms, because this process spawns the room server as a
// child and the child needs the same posture the parent was given. The deploy
// runs with the repository mounted read-only and passes `--no-lock` on the
// command line for that reason; without it here, the parent starts, every child
// dies writing `deno.lock`, and the supervisor respawns it forever. Nothing
// needs the lockfile: it is gitignored, and the one npm dependency is version
// pinned in the import map.
// The same scoped set on both arms. The iroh room server needs one thing the TCP
// one does not — `--unstable-ffi`, for the transport's dynamic library — and
// nothing else: it reads that library, opens sockets, and reads the environment
// exactly as the TCP arm does. It used to be given everything, which is a wider
// grant than a network-facing child has any use for.
const DENO_FLAGS = [
	"run",
	"--allow-ffi",
	"--allow-read",
	"--allow-net",
	"--allow-env",
	"--no-lock",
	...(TRANSPORT === "iroh" ? ["--unstable-ffi"] : []),
];

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

// One stray async error in the relay or the supervisor, or a transport hiccup, must never take
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
		? [`${ROOT}../server/main.ts`, "--transport=iroh"]
		: [`${ROOT}../server/main.ts`, ROOM_PORT];
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
		const dir = await Directory.connect(locator, dial);
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
			roomLocator = await readAnnouncedLocator(child);
		} catch (err) {
			console.error("rooms: room server respawn failed:", err);
			child = null;
			await delay(500);
		}
	}
}

// Attach mode left us without a child. Poll the shared locator; if that server
// dies (the owning serve.ts exited and tore it down, or an orphan crashed), take
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
			roomLocator = await readAnnouncedLocator(child);
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
	// If the room port is already taken, don't fight it. When a previous serve.ts
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
				`       deno run --allow-ffi --allow-read --allow-net --allow-run ${ROOT}serve.ts ${HTTP_PORT} 9100`,
		);
		Deno.exit(1);
	}

	child = spawnRoomServer();
	try {
		roomLocator = await readAnnouncedLocator(child);
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
	`                deno ${
		DENO_FLAGS.join(" ")
	} ${ROOT}../clients/deno/chat.ts ${roomLocator} <room> <nick>)`,
);

// The browser UI lives in ui/: page.html, page.css, and a set of React components
// entered through main.tsx. page.html and page.css are read fresh on each request, so
// editing them shows on a browser refresh with no restart. The components are authored in
// TypeScript and JSX (ui/deno.json targets the DOM libs) and served as JavaScript: a
// pre-built ui/page.js is used if present — the deploy builds it ahead of time with
// `deno bundle`, so the runtime does not need to download bundler dependencies —
// otherwise the bundle is built here. Either way it is rebuilt whenever a module it was
// built from is newer than it, so a reload shows an edit. Everything is served with
// no-store, so a browser always fetches the current build.
const UI_DIR = `${ROOT}ui/`;
// Every directory the browser bundle draws modules from. A staleness check that
// misses one serves code from before an edit while the page assets around it are
// current, which reads as "my change did nothing" and is very hard to see.
const SOURCE_DIRS = [UI_DIR, `${ROOT}../lib/`, `${ROOT}../../../bindings/ts/`];
// Not minified, so the served bundle stays readable in the browser's view-source.
// A production build can shrink it a lot by adding "--minify" to a pre-built
// page.js (see deploy/README.md).
const BROWSER_BUNDLE_CONFIG = `${ROOT}../../../bindings/ts/web/browser-bundle.json`;
const WASM_PATH = `${ROOT}../../../zig-out/wasm/pancake_host.wasm`;
async function bundleClient(): Promise<string> {
	const { code, stdout, stderr } = await new Deno.Command("deno", {
		args: [
			"bundle",
			"--platform",
			"browser",
			"--no-lock",
			"--quiet",
			"--config",
			BROWSER_BUNDLE_CONFIG,
			`${UI_DIR}main.tsx`,
		],
		stdout: "piped",
		stderr: "piped",
	}).output();
	if (code !== 0) {
		throw new Error(new TextDecoder().decode(stderr).trim() || "deno bundle failed");
	}
	return new TextDecoder().decode(stdout);
}
// The newest modification time across every module the bundle is built from, or
// null if none can be read. It walks, rather than reading one directory, so
// putting a component in a subdirectory cannot quietly stop the staleness check
// from seeing it.
async function newestSourceTime(): Promise<number | null> {
	let newest: number | null = null;
	const note = (at: number | undefined) => {
		if (at !== undefined && (newest === null || at > newest)) newest = at;
	};
	const walk = async (dir: string): Promise<void> => {
		try {
			for await (const entry of Deno.readDir(dir)) {
				const path = `${dir}${entry.name}`;
				if (entry.isDirectory) {
					// Installed packages are not what anyone is editing, and
					// walking them costs more than the check is worth.
					if (entry.name !== "node_modules") await walk(`${path}/`);
					continue;
				}
				if (!entry.isFile) continue;
				if (!/\.(tsx?|css|html)$/.test(entry.name)) continue;
				note((await Deno.stat(path)).mtime?.getTime());
			}
		} catch {
			// A directory that cannot be read says nothing about staleness.
		}
	};
	for (const dir of SOURCE_DIRS) await walk(dir);
	return newest;
}

/** The bundle being served, and the newest source time it was built from.
 *
 * A bundle is stale the moment a module it was built from is newer than it, and
 * that is one rule whether the bundle came off disk or was built here. It is
 * the only thing the page loads that could go quietly out of date: page.html,
 * page.css, and the wasm module are all read fresh per request, so a stale
 * bundle serves old code inside a page that otherwise reloaded, and the edit
 * looks like it did nothing. */
let pageJs = "";
let pageJsAt = 0;
/** The source time a rebuild already failed on, so a broken edit is reported
 * once rather than on every page load. Moving a source retries. */
let failedSourceAt = 0;
/** The rebuild in flight, so concurrent page loads share one, and the source
 * time it is building for. A page load that joins a build already running has
 * to report against that build's source time, not its own. */
let rebuilding: { at: number; done: Promise<void> } | null = null;

async function bundleInto(sourceAt: number): Promise<void> {
	const code = await bundleClient();
	pageJs = code;
	pageJsAt = sourceAt;
}

/** Bring the bundle up to date if a module it was built from has moved. Returns
 * the reason a rebuild failed, or null when there was nothing to do or it
 * worked. A failure leaves the last good build standing: a deployment with no
 * bundler has one prepared, and a syntax error mid-edit should not take the
 * page down. */
async function refreshPageJs(): Promise<string | null> {
	const sourceAt = await newestSourceTime();
	if (sourceAt === null || sourceAt <= pageJsAt || sourceAt === failedSourceAt) return null;
	if (rebuilding === null) rebuilding = { at: sourceAt, done: bundleInto(sourceAt) };
	const attempt = rebuilding;
	try {
		await attempt.done;
		return null;
	} catch (err) {
		// The failure belongs to the source time the build was actually for. A
		// load that joined a build already running would otherwise blame its own
		// newer edit for a build nobody ran on it, and then skip the rebuild that
		// edit is owed.
		failedSourceAt = attempt.at;
		return reasonOf(err);
	} finally {
		if (rebuilding === attempt) rebuilding = null;
	}
}

// The deploy path: a bundle prepared ahead of time, so the runtime needs no
// bundler. `refreshPageJs` holds it to the same staleness rule as one built
// here, and if there is no bundler to rebuild with, this is what stands.
try {
	pageJs = await Deno.readTextFile(`${UI_DIR}page.js`);
	pageJsAt = (await Deno.stat(`${UI_DIR}page.js`)).mtime?.getTime() ?? 0;
} catch {
	// No prepared bundle: one is built below, which is the dev default.
}
// Build at startup rather than on the first page load, so a bundler failure is
// an error in the terminal the server was started from.
const startupFailure = await refreshPageJs();
if (pageJs === "") {
	console.error(
		`rooms: could not build the browser UI: ${startupFailure ?? "no bundle produced"}`,
	);
	shutdown.abort();
	killChild();
	Deno.exit(1);
}
if (startupFailure !== null) {
	console.warn(`rooms: could not rebundle (${startupFailure}); serving ui/page.js as built`);
}

// no-store so a browser (iOS Safari especially) never serves a stale asset after the
// server is updated — every load fetches the current build.
// A short human reason from any thrown value.
function reasonOf(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}

function asset(body: string, type: string): Response {
	return new Response(body, {
		headers: { "content-type": type, "cache-control": "no-store" },
	});
}
// The typefaces ui/tokens.css names, by exact filename. Fonts are immutable once
// published, so unlike the page assets they are cached hard.
const FONTS = new Set([
	"ibm-plex-sans-latin-wght-normal.woff2",
	"ibm-plex-sans-latin-wght-italic.woff2",
	"ibm-plex-mono-latin-400-normal.woff2",
	"ibm-plex-mono-latin-400-italic.woff2",
	"ibm-plex-mono-latin-600-normal.woff2",
]);

async function serveFont(name: string): Promise<Response> {
	if (!FONTS.has(name)) return new Response("not found\n", { status: 404 });
	try {
		return new Response(await Deno.readFile(`${UI_DIR}fonts/${name}`), {
			headers: {
				"content-type": "font/woff2",
				"cache-control": "public, max-age=31536000, immutable",
			},
		});
	} catch (err) {
		return new Response(`rooms: could not read ui/fonts/${name}: ${reasonOf(err)}`, {
			status: 500,
		});
	}
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

// ── The byte relay ───────────────────────────────────────────────────────
// A browser peer speaks OCapN itself but cannot open a socket directly, so this
// endpoint carries its bytes. A *dial* rides `/relay?target=<locator>`: a
// `host:port` reaches the room server over TCP, an `ocapn://…iroh` URI reaches a
// member over iroh (relay.ts dials and pipes without parsing, so the keyed
// handshake rides through end to end). A *cold-dial* to a browser is a different
// operation — a bridge, not a dial — so it has its own path: `/relay?rendezvous=
// <designator>` bridges onto the inbound socket the browser holds by registering
// at `/register?id=<designator>` (ADR-0088). The allow-list keeps TCP on the room
// server only; an ocapn:// dial target may name any iroh node, key-verified end
// to end.
//
// A relay session is a persistent, mostly-quiet byte pipe (a chat peer types
// rarely), so liveness is the WebSocket ping/pong, not a byte-traffic idle
// timeout that cannot tell a live-but-quiet peer from a dead one (that byte-idle
// is off in relay.ts, or a quiet peer would be dropped and reconnect every
// idle window). Deno pings; a live browser auto-pongs and stays connected, and a
// dead one is reclaimed after this many seconds.
const RELAY_WS_IDLE_TIMEOUT_S = 120;

try {
	Deno.serve({ port: HTTP_PORT, signal: shutdown.signal }, (req) => {
		const url = new URL(req.url);
		// A browser that cannot be dialed registers its keyed identity and a held
		// inbound socket here; a peer redeeming an introduction to it dials
		// `/relay?rendezvous=<designator>` and is bridged onto the held socket
		// (ADR-0088). Byte-transparent like every relay leg.
		if (url.pathname === "/register") {
			const id = url.searchParams.get("id");
			if (!id) {
				return new Response("rooms: register requires ?id=<designator>\n", { status: 400 });
			}
			if (!relayOriginAllowed(req.headers.get("origin"), req.headers.get("host"))) {
				return new Response("rooms: cross-origin register refused\n", { status: 403 });
			}
			// A held registration parks idle until a cold-dial bridges it, so it
			// needs its own liveness bound: Deno pings the socket and closes it if
			// no pong lands within `idleTimeout` (ADR-0086's idle reclaim is scoped
			// to a *bridged* pair, not a held idle one). A live browser auto-pongs
			// and stays registered; a peer that died without a clean close (mobile
			// sleep, a dropped network) is reclaimed here, so `Rendezvous.has`
			// never reports a corpse as present and a dialer never bridges a corpse.
			const { socket, response } = Deno.upgradeWebSocket(req, { idleTimeout: 30 });
			registerRendezvous(socket, id);
			return response;
		}
		if (url.pathname === "/relay") {
			// A cold-dial to a browser is a *bridge* to a held socket, not a dial, so
			// it is its own path: `?rendezvous=<designator>` bridges onto the inbound
			// socket that identity holds here (ADR-0088).
			const rendezvousId = url.searchParams.get("rendezvous");
			if (rendezvousId) {
				if (!relayOriginAllowed(req.headers.get("origin"), req.headers.get("host"))) {
					return new Response("rooms: cross-origin relay refused\n", { status: 403 });
				}
				const { socket, response } = Deno.upgradeWebSocket(req, {
					idleTimeout: RELAY_WS_IDLE_TIMEOUT_S,
				});
				bridgeRendezvous(socket, rendezvousId);
				return response;
			}
			// A dial: `?target=<locator>` — a `host:port` dials TCP, an `ocapn://` URI
			// dials iroh. The shared `classifyRelayTarget` sorts the locator once
			// through the core; the classified target then gates admission and drives
			// the dial. A cold-dial to a browser is a bridge, not a dial, and took the
			// `?rendezvous=` branch above.
			const target = url.searchParams.get("target");
			if (!target) {
				return new Response(
					"rooms: relay requires ?target=<host:port | ocapn:// URI> or ?rendezvous=<id>\n",
					{ status: 400 },
				);
			}
			if (target.length > 2048) {
				return new Response("rooms: relay target too long\n", { status: 400 });
			}
			let classified: RelayTarget;
			try {
				classified = classifyRelayTarget(target);
			} catch {
				return new Response("rooms: unparseable relay target locator\n", { status: 400 });
			}
			if (!relayAllowed(classified, Number(ROOM_PORT), RELAY_TCP_PEERS)) {
				return new Response(
					`rooms: relay target not allowed (TCP relay reaches 127.0.0.1:${ROOM_PORT} ` +
						`and the peers named in PANCAKE_RELAY_TCP_PEERS)\n`,
					{ status: 403 },
				);
			}
			if (!relayOriginAllowed(req.headers.get("origin"), req.headers.get("host"))) {
				return new Response("rooms: cross-origin relay refused\n", { status: 403 });
			}
			const { socket, response } = Deno.upgradeWebSocket(req, {
				idleTimeout: RELAY_WS_IDLE_TIMEOUT_S,
			});
			relayToTarget(socket, classified);
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
		// Where a browser member publishes its own trace, so its direct
		// messages appear on the same timeline as the room's own sessions. The
		// page builds the socket URL against its own hostname, so this answers
		// with the port alone; a run whose endpoint is not reachable from the
		// browser passes `?viz=<ws url>` on the page URL instead.
		if (url.pathname === "/viz") {
			if (VIZ_PORT === "") {
				return new Response("rooms: no live timeline endpoint\n", { status: 404 });
			}
			if (VIZ_PORT === "0") {
				// An ephemeral endpoint port is chosen inside the room server
				// and announced on its stderr, which this process passes
				// through rather than reading. Nothing here can name it.
				return new Response(
					"rooms: the live timeline endpoint took an ephemeral port; " +
						"set ROOMS_VIZ_PORT to a fixed one, or open the page with ?viz=<ws url>\n",
					{ status: 409 },
				);
			}
			return new Response(`${VIZ_PORT}\n`, {
				headers: {
					"content-type": "text/plain; charset=utf-8",
					"cache-control": "no-store",
				},
			});
		}
		if (url.pathname === "/page.js") {
			return (async () => {
				const failed = await refreshPageJs();
				if (failed !== null) {
					console.warn(
						`rooms: could not rebuild the browser UI (${failed}); serving the last build`,
					);
				}
				return asset(pageJs, "text/javascript; charset=utf-8");
			})();
		}
		// The browser peer's wasm Host module (ADR-0070), fetched by the page's
		// `@pancake/web` init. Read fresh so a rebuilt module serves without a
		// restart, like the page assets.
		if (url.pathname === "/pancake_host.wasm") {
			return (async () => {
				try {
					const bytes = await Deno.readFile(WASM_PATH);
					return new Response(bytes, {
						headers: {
							"content-type": "application/wasm",
							"cache-control": "no-store",
						},
					});
				} catch {
					return new Response(
						"rooms: pancake_host.wasm not built (zig build wasm-driver)\n",
						{
							status: 503,
						},
					);
				}
			})();
		}
		if (url.pathname === "/page.css") return serveUi("page.css", "text/css; charset=utf-8");
		// The shared UI core (ui/tokens.css), reached through a symlink in ui/.
		if (url.pathname === "/tokens.css") return serveUi("tokens.css", "text/css; charset=utf-8");
		// The typefaces ui/tokens.css declares. Served from an allowlist rather than
		// by joining the request path onto a directory, so a crafted path cannot
		// walk out of ui/fonts and read the rest of the machine.
		if (url.pathname.startsWith("/fonts/")) {
			return serveFont(url.pathname.slice("/fonts/".length));
		}
		return serveUi("page.html", "text/html; charset=utf-8");
	});
} catch (err) {
	// The usual cause is a second serve.ts on the same HTTP port; say so and stop the
	// child we just started rather than leave it orphaned.
	console.error(
		`rooms: could not serve on http port ${HTTP_PORT} (${
			err instanceof Error ? err.message : err
		}).\n` +
			`       Another rooms web UI may already be on it; try a different port, e.g. serve.ts ${
				HTTP_PORT + 1
			}`,
	);
	shutdown.abort();
	killChild();
	Deno.exit(1);
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
