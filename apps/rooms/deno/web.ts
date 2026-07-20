// DENO-SPECIFIC: The rooms chat host process for Deno.
// It serves the browser page and stays out of the OCapN wire.
//
// The page is a real pancake peer. It loads `@pancake/web` (the wasm Host) and
// dials the room server itself; this process only serves the page, the wasm
// module, and one dumb byte pipe:
//
//   browser peer ──WebSocket (/relay)──▶ web.ts ──TCP──▶ rooms server
//
// `/relay?to=host:port` upgrades to a WebSocket and pipes bytes to that TCP
// target without parsing them, so the keyed OCapN session rides through end to
// end and the relay never holds a capability. It is `ws://` on loopback in
// development and `wss://` once the page is served over HTTPS. TCP relay reaches
// only the room server; iroh relay accepts any ocapn:// URI (verified by keyed
// handshake), enabling third-party handoff for browser-peer direct messages.
//
// This process also supervises the room server as a child: it respawns it if it
// dies, and if it attached to a server another web.ts already owned and that
// server later goes away, it takes ownership rather than serving a dead locator.
// The browser reconnects on its own and replays its join, so restarting this
// process (to pick up a code change, say) just shows "reconnecting…" and recovers.
//
//   deno run --allow-ffi --allow-read --allow-net --allow-run web.ts
//
// Open the printed URL. It also prints the room's locator, so you can join from
// a terminal (`chat.ts <locator> <room> <nick>`) at the same time.

import { Directory } from "../lib/room_client.ts";
import { ANNOUNCE_RE, announceToLocator, dial, loopbackTcpDesignator } from "./lib/locator.ts";
import { relayAllowed, relayOriginAllowed, relayToLocator } from "./relay_server.ts";

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
const ROOT = new URL(".", import.meta.url).pathname;
const DENO_FLAGS = TRANSPORT === "iroh"
	? ["run", "-A", "--unstable-ffi"]
	: ["run", "--allow-ffi", "--allow-read", "--allow-net", "--allow-env"];

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
const BROWSER_BUNDLE_CONFIG = `${ROOT}../../../bindings/ts/web/browser-bundle.json`;
const WASM_PATH = `${ROOT}../../../zig-out/wasm/pancake_driver.wasm`;
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
			`${UI_DIR}main.ts`,
		],
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
// A short human reason from any thrown value.
function reasonOf(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}

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

// ── The byte relay ───────────────────────────────────────────────────────
// A browser peer speaks OCapN itself but cannot open a socket directly, so this
// one endpoint carries its bytes: `/relay?to=host:port` (TCP) or
// `/relay?locator=<uri>` (iroh) upgrades to WebSocket and pipes frames to the
// target in both directions without parsing them — the keyed handshake rides
// through end to end, so the relay never holds a capability. The allow-list
// keeps TCP on the room server only; an iroh locator may be any ocapn:// URI
// because the session authority it carries is key-verified (relay_server.ts).

try {
	Deno.serve({ port: HTTP_PORT, signal: shutdown.signal }, (req) => {
		const url = new URL(req.url);
		if (url.pathname === "/relay") {
			const target = url.searchParams.get("locator") ?? url.searchParams.get("to");
			if (!target) {
				return new Response(
					"rooms: relay requires ?to=host:port (TCP) or ?locator=<uri> (iroh)\n",
					{ status: 400 },
				);
			}
			if (!relayAllowed(target, Number(ROOM_PORT))) {
				const reason = target.includes("://")
					? "an iroh locator must be an ocapn:// URI"
					: `TCP relay reaches only 127.0.0.1:${ROOM_PORT}`;
				return new Response(`rooms: relay target not allowed (${reason})\n`, {
					status: 403,
				});
			}
			if (!relayOriginAllowed(req.headers.get("origin"), req.headers.get("host"))) {
				return new Response("rooms: cross-origin relay refused\n", { status: 403 });
			}
			const { socket, response } = Deno.upgradeWebSocket(req);
			relayToLocator(socket, target);
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
		// The browser peer's wasm Host module (ADR-0070), fetched by the page's
		// `@pancake/web` init. Read fresh so a rebuilt module serves without a
		// restart, like the page assets.
		if (url.pathname === "/pancake_driver.wasm") {
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
						"rooms: pancake_driver.wasm not built (zig build wasm-driver)\n",
						{
							status: 503,
						},
					);
				}
			})();
		}
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
