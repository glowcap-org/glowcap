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
// An `ocapn://…onion` target must name the supervised room's own service, and
// is carried to that service's local forward endpoint — the same bytes a Tor
// circuit would deliver there, without the circuit.
// A cold-dial to a browser is a bridge, not a dial: `/relay?rendezvous=<id>`.
//
// This process also supervises the room server as a child: it respawns it if it
// dies, and if it attached to a server another serve.ts already owned and that
// server later goes away, it takes ownership rather than serving a dead locator.
// The browser reconnects on its own and replays its join, so restarting this
// process (to pick up a code change, say) just shows "reconnecting…" and recovers.
//
//   deno run --allow-ffi --allow-read --allow-write --allow-net --allow-env --allow-run serve.ts
//
// Open the printed URL. It also prints the room's locator, so you can join from
// a terminal (`chat.ts <locator> <room> <nick>`) at the same time.

import { isLoopbackHost, isWildcardHost } from "../lib/bind_host.ts";
import { Directory } from "../lib/room/client.ts";
import { dialDirectory, isUriLocator, loopbackTcpDesignator, readAnnouncedLocator } from "../lib/locator.ts";
import { addressDesignator } from "@pancake/tcp";
import { openRoomsRuntime } from "../lib/runtime.ts";
import { nextRestartWait } from "./restart.ts";
import { Reachability } from "@pancake/iroh";
import { parseTcpPeers, shutdownRelay } from "./relay.ts";
import { prepareAndListen } from "./serve_http.ts";
import { ensureTor, type TorEndpoints } from "./tor.ts";
import { flagOrEnv, optionalEnv, transportChoice, vizPortChoice } from "../lib/env.ts";
import { BOOT_CAPS } from "../lib/boot_caps.ts";

// Positional args are the HTTP port and the room port; flags start with `--`.
const flags = Deno.args.filter((a) => a.startsWith("--"));
const positional = Deno.args.filter((a) => !a.startsWith("--"));
const HTTP_PORT = Number(positional[0] ?? "8000");
// A fixed room port (override as the 2nd positional arg) so a TCP room is stable
// across server restarts and CLI clients always know where to connect.
const ROOM_PORT = positional[1] ?? "9099";
// `--diagnostics` (or `PANCAKE_ROOMS_DIAGNOSTICS=1`) mints an unguessable
// inspect capability on the room server and prints it here. The other entries
// in `BOOT_CAPS` follow the same operator-capability shape. None is a page flag:
// the Operations page takes each by
// fetching its swiss number on the live directory session, the same way it
// fetches `directory`.
const DIAGNOSTICS = flagOrEnv(flags, BOOT_CAPS.diagnostics.flag, BOOT_CAPS.diagnostics.env);
const ADMIN_LISTENERS = flagOrEnv(flags, BOOT_CAPS.adminListeners.flag, BOOT_CAPS.adminListeners.env);
const PEERING = flagOrEnv(flags, BOOT_CAPS.peering.flag, BOOT_CAPS.peering.env);
// `--viz` (or `PANCAKE_ROOMS_VIZ=1`) has the room server serve the live
// timeline endpoint and mint the viz capability, the same enabling shape as
// the other entries.
// `--irc` (or `PANCAKE_ROOMS_IRC=1`) mints the IRC gateway capability:
// holding it bridges IRC channels into this directory as ordinary rooms.
const IRC = flagOrEnv(flags, BOOT_CAPS.irc.flag, BOOT_CAPS.irc.env);
const OPERATOR = flagOrEnv(flags, BOOT_CAPS.operator.flag, BOOT_CAPS.operator.env);
const VIZ = flagOrEnv(flags, BOOT_CAPS.viz.flag, BOOT_CAPS.viz.env);
// `--history` (or `PANCAKE_ROOMS_HISTORY=1`) has the room server keep listed
// rooms' last lines in its state directory and answer them to members. A
// policy flag, not a capability: there is no swiss to take, only a stated
// retention the room's own divider names.
const HISTORY = flagOrEnv(flags, "--history", "PANCAKE_ROOMS_HISTORY");
// `--storage=` rides to the server as the env var it honors, the same road
// the LAN flags take: one destination, its shape judged by the server alone.
const flagStorage = flags.findLast((a) => a.startsWith("--storage="))?.slice("--storage=".length) || undefined;
// `--transport=<tcp|iroh|onion>` (or `PANCAKE_ROOMS_TRANSPORT`) picks the room's wire.
// Over iroh and onion the server announces an ocapn:// URI; over onion ROOM_PORT
// becomes the local endpoint Tor forwards the service to, which is also where
// the relay reaches it. The last flag wins, so a build step that bakes a default
// (`rooms-web` bakes iroh) can still be overridden with `-- --transport=…`. The
// env var is a convenience for manual runs and is read only when env access is
// granted, so the default permission set never trips.
const flagTransport = flags.findLast((a) => a.startsWith("--transport="))?.slice("--transport=".length);
const TRANSPORT = (() => {
	try {
		return transportChoice(flagTransport);
	} catch (err) {
		console.error(`rooms: ${err instanceof Error ? err.message : err}`);
		Deno.exit(2);
	}
})();
// `--bind=<host>` and `--announce-host=<host>` are the TCP room's LAN knobs,
// forwarded to the spawned server as the `PANCAKE_ROOMS_BIND` and
// `PANCAKE_ROOMS_ANNOUNCE_HOST` env vars it already honors (setting the env
// vars directly keeps working): the bind host it listens on (default
// 127.0.0.1), and the dialable hostname it prints and advertises. `tcp` is
// cleartext and proves no peer, so exposing it on a LAN shows the conversation
// to that network.
const flagBind = flags.findLast((a) => a.startsWith("--bind="))?.slice("--bind=".length) || undefined;
const flagAnnounceHost = flags.findLast((a) => a.startsWith("--announce-host="))?.slice("--announce-host=".length) ||
	undefined;
const BIND_HOST = flagBind ?? optionalEnv("PANCAKE_ROOMS_BIND") ?? "127.0.0.1";
const ANNOUNCE_HOST = flagAnnounceHost ?? optionalEnv("PANCAKE_ROOMS_ANNOUNCE_HOST");
// The port the room server's live timeline endpoint binds while `--viz` is on:
// the canonical default unless `PANCAKE_ROOMS_VIZ_PORT` overrides it, resolved
// here with the same `vizPortChoice` the child uses so the origin door and the
// endpoint cannot disagree. The page publishes its own trace through that
// door — `/viz` and `/publish` upgrades are carried to the endpoint — which is
// the only way a direct message (a session between two members that this
// server never carries) reaches the timeline. Empty when viz is off, and the
// page then installs no tap. Enabling also mints the viz capability the
// endpoint requires of every socket. A local tab publishes through this door
// only while a reader holds that swiss (the "Protocol visualizer" toggle in
// Settings under Holdings). A shared session publishes from the session
// process; attached tabs do not arm a second producer here.
const VIZ_PORT = (() => {
	if (!VIZ) return "";
	try {
		return vizPortChoice();
	} catch (err) {
		console.error(`rooms: ${err instanceof Error ? err.message : err}`);
		Deno.exit(2);
	}
})();
// Cleartext-TCP peers a browser may open a direct message to, as
// `host:port,host:port`. The relay dials iroh anywhere and TCP only where it is
// told, because a TCP address can be any service on the network rather than an
// OCapN peer holding a key (`relayAllowed`). A member reachable only over
// cleartext TCP — a Goblins vat on a TCP netlayer — belongs here; one on iroh
// needs no entry.
const RELAY_TCP_PEERS = parseTcpPeers(optionalEnv("PANCAKE_RELAY_TCP_PEERS"));
// A browser served on the announce host dials the room as `<host>:<port>`, so
// that pair joins the allow-list beside the operator-named peers: it is still
// only the room server, under the name this deployment tells browsers to use.
if (ANNOUNCE_HOST !== undefined && TRANSPORT === "tcp") {
	RELAY_TCP_PEERS.push({ hostname: ANNOUNCE_HOST, port: Number(ROOM_PORT) });
}
const ROOT = new URL(".", import.meta.url).pathname;
// A supervised child is another process incarnation of the same room server,
// not a new authority. Keep its Host identity and durable room publications in
// one state directory for the supervisor's whole lifetime. An operator-supplied
// PANCAKE_ROOMS_STATE survives the supervisor too; the temporary default is
// removed when this development process stops.
const configuredRoomState = optionalEnv("PANCAKE_ROOMS_STATE");
const temporaryRoomState = configuredRoomState ? null : await Deno.makeTempDir({ prefix: "pancake-rooms-" });
const ROOM_STATE = configuredRoomState || temporaryRoomState!;
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
	`--allow-write=${ROOM_STATE}`,
	"--no-lock",
	...(TRANSPORT === "iroh" ? ["--unstable-ffi"] : []),
];

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Every background root is expected to handle its own failure. If one escapes,
// this process no longer knows which effect committed, so stop the room and let
// the outer service supervisor restart the whole owned unit from durable state.
globalThis.addEventListener("unhandledrejection", (event) => {
	event.preventDefault();
	console.error("rooms: fatal unhandled rejection:", event.reason);
	requestStop(1);
});

// The room server runs as a supervised child process. `roomLocator` always points
// at the live one; when it exits, the respawn loop brings it back, so the rooms
// outlive a crash and tabs reconnect and replay their join. Aborting `shutdown`
// ends the loop when the process is stopping.
const shutdown = new AbortController();
let roomLocator = "";
let child: Deno.ChildProcess | null = null;
// The Tor whose endpoints the onion room server receives. Owned here rather
// than by the child, so a respawned child keeps the same daemon and, with the
// service key the server stores under PANCAKE_ROOMS_STATE, the same onion address.
let tor: TorEndpoints | null = null;
// Tor's control round-trip can sit behind a still-bootstrapping daemon, so the
// onion announce gets a longer leash than a local bind.
const ANNOUNCE_DEADLINE_MS = TRANSPORT === "onion" ? 60_000 : 10_000;

// Stopping, stated with the state it stops and above everything that can ask
// for it. It used to sit at the foot of the file, which read fine and was a
// hazard: `stopping` is a `let`, so the startup path calling `stop` — a room
// server that would not start, a port already taken — reached it before its
// declaration had run and died of a ReferenceError while trying to shut down
// cleanly. The one failure a shutdown must survive is the one that called it.
//
// Stop cleanly when interrupted: end the respawn loop, close the HTTP server (its
// abort signal), stop and join the room child, release temporary durable state,
// then exit. Cleanup failure changes a successful exit into a failure instead of
// silently leaking state the process claimed to own.
let stopping = false;
async function stop(requestedExitCode: number): Promise<never> {
	if (stopping) await new Promise<never>(() => {});
	stopping = true;
	shutdown.abort();
	shutdownRelay();
	const owned = child;
	if (owned !== null) {
		try {
			owned.kill("SIGTERM");
		} catch {
			// `status` below is the authority: a child that won the race and already
			// exited needs no signal, while every live child must accept this one.
		}
		await owned.status;
	}
	let exitCode = requestedExitCode;
	if (tor !== null) {
		try {
			await tor.stop();
		} catch (err) {
			exitCode = 1;
			console.error("rooms: could not stop the private Tor:", err);
		}
	}
	if (temporaryRoomState !== null) {
		try {
			await Deno.remove(temporaryRoomState, { recursive: true });
		} catch (err) {
			exitCode = 1;
			console.error("rooms: could not remove temporary room state:", err);
		}
	}
	Deno.exit(exitCode);
}

/** Give an asynchronous stop an error owner when no caller can await it. */
function requestStop(exitCode: number): void {
	void stop(exitCode).catch((err) => {
		console.error("rooms: shutdown failed:", err);
		Deno.exit(1);
	});
}

// Answer an interrupt from here on, which is before the first room server is
// spawned rather than after the page is being served. These listeners replace
// the default action, so until they exist an interrupt ends this process
// outright and the room server it had already started is left holding its port
// with nobody above it. Startup is where that window is widest: an onion or
// iroh announce can take a minute. Everything `stop` touches is initialized
// above, which is what makes registering this early safe.
Deno.addSignalListener("SIGINT", () => requestStop(0));
Deno.addSignalListener("SIGTERM", () => requestStop(0));

function spawnRoomServer(): Deno.ChildProcess {
	// The onion arm keeps ROOM_PORT as its positional: the server binds it as
	// the local endpoint Tor forwards the service to, which is also where the
	// relay reaches the room for this page's tabs.
	const serverArgs = TRANSPORT === "iroh"
		? [`${ROOT}../server/main.ts`, "--transport=iroh"]
		: TRANSPORT === "onion"
		? [`${ROOT}../server/main.ts`, "--transport=onion", ROOM_PORT]
		: [`${ROOT}../server/main.ts`, ROOM_PORT];
	if (DIAGNOSTICS) serverArgs.push(BOOT_CAPS.diagnostics.flag);
	if (ADMIN_LISTENERS) serverArgs.push(BOOT_CAPS.adminListeners.flag);
	if (PEERING) serverArgs.push(BOOT_CAPS.peering.flag);
	if (IRC) serverArgs.push(BOOT_CAPS.irc.flag);
	if (OPERATOR) serverArgs.push(BOOT_CAPS.operator.flag);
	if (VIZ) serverArgs.push(BOOT_CAPS.viz.flag);
	if (HISTORY) serverArgs.push("--history");
	return new Deno.Command("deno", {
		args: [...DENO_FLAGS, ...serverArgs],
		env: {
			PANCAKE_ROOMS_STATE: ROOM_STATE,
			// This supervisor owns the operator-facing boot block, so the child
			// keeps its stderr to the greppable `ROOMS-*` token lines.
			PANCAKE_ROOMS_SUPERVISED: "1",
			...(DIAGNOSTICS ? { PANCAKE_ROOMS_DIAGNOSTICS: "1" } : {}),
			...(ADMIN_LISTENERS ? { PANCAKE_ROOMS_ADMIN_LISTENERS: "1" } : {}),
			...(OPERATOR ? { PANCAKE_ROOMS_OPERATOR: "1" } : {}),
			...(PEERING ? { PANCAKE_ROOMS_PEERING: "1" } : {}),
			...(VIZ ? { PANCAKE_ROOMS_VIZ: "1" } : {}),
			// The LAN flags ride to the server as the env vars it honors; env
			// vars an operator set directly are inherited untouched.
			...(flagStorage !== undefined ? { PANCAKE_ROOMS_STORAGE: flagStorage } : {}),
			...(flagBind !== undefined ? { PANCAKE_ROOMS_BIND: flagBind } : {}),
			...(flagAnnounceHost !== undefined ? { PANCAKE_ROOMS_ANNOUNCE_HOST: flagAnnounceHost } : {}),
			...(tor !== null ? { PANCAKE_ONION_SOCKS: tor.socks, PANCAKE_ONION_CONTROL: tor.control } : {}),
		},
		stdout: "piped",
		stderr: "inherit",
	}).spawn();
}

// Whether the fixed room port is already bound — an orphaned server from a
// previous run, say. iroh has no fixed port to probe; TCP binds the configured
// bind host, and an onion room binds loopback as the service's local forward
// endpoint.
function roomPortInUse(): boolean {
	if (TRANSPORT === "iroh") return false;
	try {
		Deno.listen({
			hostname: TRANSPORT === "onion" ? "127.0.0.1" : BIND_HOST,
			port: Number(ROOM_PORT),
		}).close();
		return false;
	} catch {
		return true;
	}
}

// Where an already-running TCP room server is dialed for attach checks: the
// configured bind host, with the any-address forms folded to loopback because
// this process shares the machine with that server. Both arms join host and
// port through the core grammar, so an IPv6 bind host stays well-formed.
function attachDesignator(): string {
	if (isWildcardHost(BIND_HOST) || isLoopbackHost(BIND_HOST)) {
		return loopbackTcpDesignator(Number(ROOM_PORT));
	}
	return addressDesignator(BIND_HOST, Number(ROOM_PORT));
}

// Whether `locator` answers as a rooms directory. Used to tell an orphaned rooms
// server (which we can attach to) from something unrelated holding the port.
async function isRoomsServer(locator: string): Promise<boolean> {
	let runtime: Awaited<ReturnType<typeof openRoomsRuntime>> | null = null;
	try {
		const opened = await openRoomsRuntime({
			iroh: isUriLocator(locator) ? { reachability: Reachability.Direct } : undefined,
		});
		runtime = opened;
		const dir = await Directory.connect(locator, (address) => dialDirectory(address, opened));
		await dir.close();
		return true;
	} catch {
		return false;
	} finally {
		await runtime?.close().catch(() => {});
	}
}

// Own the room child: when it exits, respawn until `shutdown` aborts.
// Shared by the spawn path and by attach-mode take-over (so one loop, not two).
//
// Every path through here has to lead back to a spawn. A failed respawn used to
// leave `child` empty with nothing that would ever fill it again: the loop spun
// on its own idle delay, the room server stayed gone, and the page went on
// dialling a locator with nothing behind it while the console said nothing more.
async function respawnOwnedServer(): Promise<void> {
	let wait = 0;
	while (!shutdown.signal.aborted) {
		const owned = child;
		if (owned !== null) {
			const startedAt = Date.now();
			const status = await owned.status;
			if (shutdown.signal.aborted) return;
			// A server that had been running and then died comes straight back,
			// which is what this loop is for. One that never got going waits, so
			// the reason it printed stays readable instead of scrolling past under
			// thousands of copies of itself.
			const ranFor = Date.now() - startedAt;
			wait = nextRestartWait(wait, ranFor);
			console.error(
				`rooms: room server exited (code ${status.code}) after ${ranFor} ms; ` +
					(wait === 0 ? "restarting…" : `restarting in ${wait} ms…`),
			);
		}
		if (wait > 0) {
			await delay(wait);
			if (shutdown.signal.aborted) return;
		}
		try {
			child = spawnRoomServer();
			roomLocator = await readAnnouncedLocator(child, ANNOUNCE_DEADLINE_MS);
		} catch (err) {
			// A child that started and then would not announce is still running and
			// still holding whatever the next one needs, so it goes before the next
			// attempt rather than being forgotten with the variable that named it.
			try {
				child?.kill();
			} catch {
				// Already gone.
			}
			child = null;
			// A start that never ran is never steady, whatever the last one did.
			wait = nextRestartWait(wait, 0);
			console.error(`rooms: room server respawn failed; trying again in ${wait} ms:`, err);
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
			const existing = attachDesignator();
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
			await stop(1);
		}
		try {
			child = spawnRoomServer();
			roomLocator = await readAnnouncedLocator(child, ANNOUNCE_DEADLINE_MS);
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
		// An onion room cannot be re-attached through its local forward
		// endpoint: the onion address it answers under cannot be recovered from
		// that endpoint, so a locator taken this way would announce the wrong
		// transport. Say so and stop rather than serve a misnamed room.
		if (TRANSPORT === "onion") {
			console.error(
				`rooms: port ${ROOM_PORT} is already in use, so the onion service's local forward endpoint cannot bind.\n` +
					`       Stop whatever holds it, or start with a free room port.`,
			);
			await stop(1);
		}
		const existing = attachDesignator();
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
				`       deno run --allow-ffi --allow-read --allow-write --allow-net --allow-env --allow-run ${ROOT}serve.ts ${HTTP_PORT} 9100`,
		);
		await stop(1);
	}

	child = spawnRoomServer();
	try {
		roomLocator = await readAnnouncedLocator(child, ANNOUNCE_DEADLINE_MS);
	} catch (err) {
		console.error(
			`rooms: the room server did not start: ${err instanceof Error ? err.message : err}`,
		);
		await stop(1);
	}
	// Watch the live child and respawn it when it exits, until we are shutting
	// down. This runs in the background; the first locator is already in hand.
	void respawnOwnedServer();
}

/** The serving block, printed once the HTTP server is actually listening.
 * The room child has already printed the one canonical, pasteable `ROOMS-*`
 * capability bundle, so this block does not render those swisses a second way. */
function printServingBlock(): void {
	console.log("rooms: serving");
	console.log("");
	console.log(`  web ui           http://localhost:${HTTP_PORT}`);
	console.log(`  web locator      http://localhost:${HTTP_PORT}/locator`);
	console.log(`  room directory   ${roomLocator}`);
	console.log("");
	if (TRANSPORT === "onion") {
		console.log("  The onion address may take some seconds to become dialable from outside");
		console.log("  while Tor publishes it; this page's own tabs reach the room at once.");
		console.log("  A terminal client needs an onion-capable runtime; the working example");
		console.log("  is apps/rooms/demos/onion_demo.ts.");
	} else {
		// The client's own grant, not this supervisor's DENO_FLAGS: chat.ts
		// dials and reads, and pasting a supervisor-only write grant (the temp
		// state directory) into a shell would outlive both. The path is
		// resolved so the pasted line carries no `..`.
		const chatFlags = [
			"--allow-ffi",
			"--allow-read",
			"--allow-net",
			"--allow-env",
			"--no-lock",
			...(TRANSPORT === "iroh" ? ["--unstable-ffi"] : []),
		];
		const chat = new URL(`file://${ROOT}../clients/deno/chat.ts`).pathname;
		console.log("  join from a terminal:");
		console.log(`  deno run ${chatFlags.join(" ")} ${chat} ${roomLocator} <room> <nick>`);
	}
	console.log("");
	console.log("rooms: ready");
}

// The onion room needs a Tor before its first child spawns. Endpoints already
// named in the environment are honored; otherwise a private daemon starts here
// and stops with this process.
if (TRANSPORT === "onion") {
	try {
		tor = await ensureTor();
	} catch (err) {
		console.error(`rooms: ${err instanceof Error ? err.message : err}`);
		await stop(1);
	}
}

await superviseServer();

await prepareAndListen({
	root: ROOT,
	httpPort: HTTP_PORT,
	signal: shutdown.signal,
	roomPort: ROOM_PORT,
	relayTcpPeers: RELAY_TCP_PEERS,
	vizPort: VIZ_PORT,
	locator: () => roomLocator,
	stop,
});

// Last, after everything above is serving: one block, ending on the ready
// line, because the last lines are the ones an operator sees.
printServingBlock();
