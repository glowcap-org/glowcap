// The rooms chat server, written on pancake actors in native Deno.
//
// It hosts a *directory* of chat rooms and accepts any number of OCapN clients —
// in any language, over either transport. A client fetches the directory, then
// `open`s a new room or `enter`s an existing one; either call returns a live
// reference to that room. The client subscribes to the room with a nickname and
// a capability to its own inbox; the room keeps every subscriber's inbox
// capability and, when anyone posts, calls each one back with `notify`. The
// clients never poll: the room pushes to them because it holds a live capability
// to each.
//
// The directory is the server's one published bootstrap object; rooms are the
// references it hands back. A room exists only while someone is in it — when its
// last member leaves, the room is removed and its name frees up. The directory
// also answers `list` (the live rooms, as `[name, count]` pairs) and `watch`
// (hand it an inbox; it pushes a `notify(event, name, count)` delta on every
// open/close/count change), so a client can discover and follow rooms, not just
// open and enter them.
//
// The directory is published on the Host, which makes it fetchable by name and
// there before any connection is; the directory and room
// behaviors are plain functions of `(verb, args)`; a subscriber's inbox arrives
// as a `Ref` the room sends to. No peer, no vat, no manual flush, no hand-rolled
// serve loop — the capability model is the whole program.
//
// Transport is chosen by the `PANCAKE_ROOMS_TRANSPORT` env var (or
// `--transport=…`): the default `tcp` listens on `127.0.0.1:<port>` (override
// with `PANCAKE_ROOMS_BIND`); `iroh` binds an encrypted-QUIC endpoint; `onion`
// publishes a Tor hidden service through an already-running Tor named by
// `PANCAKE_ONION_SOCKS` and `PANCAKE_ONION_CONTROL`, forwarding it to
// `127.0.0.1:<port>` and keeping the service key under `PANCAKE_ROOMS_STATE`
// so the address survives a restart.
// `PANCAKE_ROOMS_REACHABILITY=discovery` puts the
// iroh endpoint on n0 relays + DNS/pkarr and announces a bare
// `ocapn://<nodeid>.iroh` URI (dial-by-id); the default `direct` announces
// `ocapn://…?direct-addresses=…` for hermetic same-host demos. On TCP,
// `PANCAKE_ROOMS_ANNOUNCE_HOST` (when set) is the dialable hostname printed and
// advertised. Either way the announce line is
// `ROOMS-SERVER-LISTENING <locator>`, which the demo harness and web bridge read
// to point clients at the right place.
//
// Run it:  deno run --allow-ffi --allow-net --allow-read --allow-env server.ts 9099
//          PANCAKE_ROOMS_TRANSPORT=iroh deno run -A --unstable-ffi server.ts
//          PANCAKE_ROOMS_TRANSPORT=iroh PANCAKE_ROOMS_REACHABILITY=discovery deno run -A --unstable-ffi server.ts

import { enableTrace, formatPeerUri, type Host, type Session, TRANSPORT_IROH } from "@pancake/runtime";
import * as irohTransport from "@pancake/iroh";
import { announceToLocator, roomsHost, roomsListen } from "../lib/locator.ts";
import { flagOrEnv, optionalEnv, transportChoice, vizPortChoice } from "../lib/env.ts";
import { BOOT_CAPS } from "../lib/boot_caps.ts";
import { startViz } from "./viz.ts";
import { impossibleStatus } from "../lib/errors.ts";
import { DIRECTORY } from "../lib/protocol.ts";
import { RoomLinks, RoomServerState } from "./state.ts";
import { linkedRoomBehavior } from "./room.ts";
import { useRoomLinks } from "./registry.ts";
import { serveAccepted } from "./sessions.ts";
import {
	type AdminTransport,
	irohReachability,
	ListenerRegistry,
	listenersBehavior,
	refuseHeldPort,
} from "./listeners.ts";
import { directoryBehavior, inspectBehavior } from "./directory_behavior.ts";
export { directoryBehavior } from "./directory_behavior.ts";

// One stray async failure (a register fetch, a notify) must not take CapTP
// down. Deno exits on unhandled rejections unless prevented; `serve.ts` already
// has this backstop, and the CapTP child needs the same.
globalThis.addEventListener("unhandledrejection", (event) => {
	event.preventDefault();
	console.error("rooms: unhandled rejection (continuing):", event.reason);
});

function diagnosticsEnabled(): boolean {
	return flagOrEnv(Deno.args, BOOT_CAPS.diagnostics.flag, BOOT_CAPS.diagnostics.env);
}

function adminListenersEnabled(): boolean {
	return flagOrEnv(Deno.args, BOOT_CAPS.adminListeners.flag, BOOT_CAPS.adminListeners.env);
}

function vizEnabled(): boolean {
	return flagOrEnv(Deno.args, BOOT_CAPS.viz.flag, BOOT_CAPS.viz.env);
}

function hexSwiss(bytes: Uint8Array): string {
	return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** The unguessable swiss an operator capability is published under.
 *
 * When `PANCAKE_ROOMS_STATE` is set, the name is reused for the life of that
 * directory (kept in `<state>/<file>`) so a supervised respawn republishes the
 * same capability the operator already copied. A new name on every child would
 * leave the printed swiss answering nothing. */
async function persistentSwiss(file: string): Promise<string> {
	const directory = optionalEnv("PANCAKE_ROOMS_STATE");
	let swiss = "";
	if (directory !== undefined) {
		try {
			swiss = (await Deno.readTextFile(`${directory}/${file}`)).trim();
		} catch {
			swiss = "";
		}
	}
	// A reused name must still be a swiss: 32 bytes of hex. Anything else is
	// debris in the state file, not a capability we should publish.
	if (!/^[0-9a-f]{64}$/.test(swiss)) {
		swiss = hexSwiss(crypto.getRandomValues(new Uint8Array(32)));
		if (directory !== undefined) {
			await Deno.writeTextFile(`${directory}/${file}`, `${swiss}\n`);
		}
	}
	return swiss;
}

/** One operator capability's place in the boot output: the stable `ROOMS-*`
 * token line an operator greps for, which is also its label — the token names
 * the flag that minted it. Collected at publish time and printed only once
 * the server is listening, because the swiss is the line an operator needs to
 * copy and the last line is the one they see. */
interface BootCapability {
	token: string;
	swiss: string;
}

/** Publish the inspect object under an unguessable swiss. The swiss is the
 * capability: whoever can fetch it can snapshot this directory. */
async function maybePublishInspect(host: Host): Promise<BootCapability | null> {
	if (!diagnosticsEnabled()) return null;
	const swiss = await persistentSwiss(BOOT_CAPS.diagnostics.file);
	host.publishGiftable(swiss, inspectBehavior());
	return { token: BOOT_CAPS.diagnostics.token, swiss };
}

/** Publish the listener-admin object under an unguessable swiss, and hand back
 * the registry the boot listener joins once it is up.
 *
 * Without the flag nothing happens here at all — no registry, no publication,
 * no allocation — the same zero-cost-when-absent posture as inspect. Published
 * before the boot listener opens, so a reused swiss from a supervised respawn
 * never has a window in which it answers `unknown swissnum`. */
async function maybePublishListeners(
	host: Host,
): Promise<{ registry: ListenerRegistry; cap: BootCapability } | null> {
	if (!adminListenersEnabled()) return null;
	const swiss = await persistentSwiss(BOOT_CAPS.adminListeners.file);
	const registry = new ListenerRegistry(host);
	host.publishGiftable(swiss, listenersBehavior(registry));
	return { registry, cap: { token: BOOT_CAPS.adminListeners.token, swiss } };
}

/** The boot block a person reads, on stderr so the machine-parsed stdout
 * stays one token line.
 *
 * Under a supervisor (serve.ts sets `PANCAKE_ROOMS_SUPERVISED=1`) the supervisor owns
 * the presentation and prints its own serving block, so only the flush-left
 * `ROOMS-*` token lines print here — they are the grep contract of the flags
 * that minted them, and repeating the prose around them would say everything
 * twice. Standalone, this block is the presentation: what is serving where
 * with each copyable value ending its own aligned line, the token lines, and
 * one ready line last. */
function printBootBlock(transport: AdminTransport, locator: string, caps: readonly BootCapability[]): void {
	if (optionalEnv("PANCAKE_ROOMS_SUPERVISED") === "1") {
		for (const cap of caps) console.error(`${cap.token} ${cap.swiss}`);
		return;
	}
	console.error("rooms: directory listening");
	console.error("");
	console.error(`  transport   ${transport}`);
	console.error(`  locator     ${locator}`);
	if (caps.length > 0) {
		console.error("");
		console.error("  operator capabilities, fetch each by its swiss:");
		console.error("");
		for (const cap of caps) console.error(`${cap.token} ${cap.swiss}`);
	}
	console.error("");
	console.error("rooms: ready");
}

// The live timeline endpoint (ocapnviz Live mode): `--viz` (or
// `PANCAKE_ROOMS_VIZ=1`) serves it, the same enabling shape as the other
// operation capabilities. Without the flag nothing happens here at all — no
// swiss is minted, persisted, or published, no endpoint binds, and the tap
// stays cold so every emit site is one null check. The endpoint binds the
// canonical trace port unless `PANCAKE_ROOMS_VIZ_PORT` overrides it
// (`vizPortChoice`); the override changes only the default, it enables
// nothing. `0` takes an ephemeral port, the way the room's own positional
// port argument does; either way the port it actually bound is the one it
// announces.
//
// Enabling the endpoint is what mints the viz capability: the same
// PANCAKE_ROOMS_STATE-persisted swiss admits every socket (producers and
// viewers alike), names the durable trace publication inside the announced
// sturdyref, and prints as the `ROOMS-VIZ` token line beside the other
// operator capabilities.
//
// The room's own trace goes in through the same door every other peer's does,
// so a member's direct messages — sessions the room never carries — appear on
// the same timeline. Each session's `a` endpoint is this host's own key
// designator, the name a partner knows it by and so the one name two producers
// can agree on; "rooms" rides beside it as what a reader should see.
async function maybeStartViz(): Promise<BootCapability | null> {
	if (!vizEnabled()) return null;
	let port: number;
	try {
		port = Number(vizPortChoice());
	} catch (err) {
		console.error(`server.ts: ${err instanceof Error ? err.message : err}`);
		Deno.exit(2);
	}
	const swiss = await persistentSwiss(BOOT_CAPS.viz.file);
	const viz = startViz(port, swiss);
	enableTrace(viz.sink, { selfLabel: "rooms" });
	return { token: BOOT_CAPS.viz.token, swiss };
}

function transportArg(): ReturnType<typeof transportChoice> {
	const flag = Deno.args.find((a) => a.startsWith("--transport="));
	try {
		return transportChoice(flag?.slice("--transport=".length));
	} catch (err) {
		console.error(`server.ts: ${err instanceof Error ? err.message : err}`);
		Deno.exit(2);
	}
}

/** iroh dial posture: `direct` (default, hermetic) or `discovery` (n0 + pkarr). */
function reachabilityArg():
	| typeof irohTransport.Reachability.Direct
	| typeof irohTransport.Reachability.Discovery {
	try {
		return irohReachability();
	} catch (err) {
		console.error(`server.ts: ${err instanceof Error ? err.message : err}`);
		Deno.exit(2);
	}
}

/** Serve the directory on every connection `server` accepts until it closes. */
export async function serveDirectory(
	host: Host,
	server: AsyncIterable<Session>,
	links?: RoomLinks,
): Promise<void> {
	// Published on the Host before the first session is taken, and not onto each
	// one as it arrives. A loop-backed listener dispatches an accepted session's
	// first message as it steps, which can be before this loop's body has run at
	// all: publishing per session left a dial that fetched immediately racing the
	// accept, and losing it was answered `unknown swissnum`. A Host-wide object
	// exists before any connection does, so there is no window to lose.
	useRoomLinks(links ?? null);
	host.publishGiftable(DIRECTORY, directoryBehavior(links));
	await serveAccepted(server);
}

// The top-level bootstrap runs only when this file is the program, so the demo
// orchestrator (and tests) can import the behaviors without binding a socket.
/** Everything between "this process was asked to be a room server" and "it is
 * listening". Named so its failures have somewhere to land: the backstop above
 * keeps one stray notify from taking CapTP down, and it was catching these too
 * — a server that could not start printed a stack trace, went on running with
 * nothing listening, and exited 0, which tells whatever supervises it that all
 * is well. */
async function start(): Promise<void> {
	// Positional args are the port (TCP only); iroh has no port to pin.
	const positional = Deno.args.filter((a) => !a.startsWith("--"));
	const viz = await maybeStartViz();
	const transport = transportArg();
	const state = await RoomServerState.open(optionalEnv("PANCAKE_ROOMS_STATE"));
	const host = roomsHost(state.identitySeed);
	const links = await RoomLinks.restore(
		state,
		(name, entropy) => host.publishDurable(linkedRoomBehavior(name), entropy),
	);
	useRoomLinks(links);
	// Both capabilities publish before the listener opens (a reused swiss must
	// never have a window answering `unknown swissnum`), but their swiss lines
	// wait for the boot block below: the last thing an operator sees is what
	// they need to copy.
	// Collected in the table's own print order (`BOOT_CAPS` is alphabetical),
	// so an operator scanning the block finds a line by name.
	const caps: BootCapability[] = [];
	const published = await maybePublishListeners(host);
	if (published !== null) caps.push(published.cap);
	const inspect = await maybePublishInspect(host);
	if (inspect !== null) caps.push(inspect);
	if (viz !== null) caps.push(viz);
	const registry = published?.registry ?? null;

	// Every arm below ends here: the boot listener joins the admin registry
	// (when one was minted) before the announce line invites anyone to dial it,
	// and the announce token is the exact locator the web relay dials — which is
	// how the registry knows which listener a `down` must never take. The
	// stdout announce stays first and alone, because its readers wait for it;
	// the human block rides behind it on stderr.
	const announce = async (
		bootTransport: AdminTransport,
		bootServer: Parameters<ListenerRegistry["adoptBoot"]>[1],
		token: string,
	): Promise<void> => {
		registry?.adoptBoot(bootTransport, bootServer, announceToLocator(token));
		console.log(`ROOMS-SERVER-LISTENING ${token}`);
		printBootBlock(bootTransport, announceToLocator(token), caps);
		await serveDirectory(host, bootServer, links);
	};

	// The harness and the web bridge parse the announce line: a bare port is a
	// TCP locator (127.0.0.1:<port>), an ocapn:// URI names its own transport.
	if (transport === "iroh") {
		// One seed for the host identity AND the endpoint, so every accepted
		// session signs with the endpoint's own key.
		const reach = reachabilityArg();
		// A room reads a live session as presence: a member holds its nickname
		// for exactly as long as its connection is open. Over TCP a member that
		// is killed is gone at once, because the operating system sends a FIN
		// as the process dies. UDP has no equivalent, so here the connection
		// ends only when QUIC gives up on a peer that stopped answering, and
		// until then the room still holds the nickname of somebody who left.
		// Eight seconds is the room's answer to how long that may take.
		const iroh = await irohTransport.listen(
			{ reachability: reach, idleTimeoutMs: 8_000 },
			{ host },
		);
		const token = reach === irohTransport.Reachability.Discovery
			? formatPeerUri(TRANSPORT_IROH, iroh.nodeId)
			: iroh.uri;
		await announce("iroh", iroh, token);
	} else if (transport === "onion") {
		// The onion arm hosts the directory as a Tor hidden service through the
		// product-level onion listener. pancake starts no Tor: the endpoints of
		// an already-running daemon arrive in the environment (the web
		// supervisor starts a private one and fills them in). The positional
		// port becomes the local endpoint Tor forwards circuits to, which is how
		// the web supervisor's relay reaches this room without a circuit.
		const socks = optionalEnv("PANCAKE_ONION_SOCKS");
		const control = optionalEnv("PANCAKE_ONION_CONTROL");
		if (socks === undefined || control === undefined) {
			throw new Error(
				"the onion transport needs PANCAKE_ONION_SOCKS and PANCAKE_ONION_CONTROL naming a running Tor's SOCKS and control endpoints",
			);
		}
		const forwardPort = Number(positional[0] ?? "0");
		if (forwardPort !== 0) refuseHeldPort("127.0.0.1", forwardPort);
		// The service key is the onion address. Kept beside the identity seed
		// under PANCAKE_ROOMS_STATE, so a supervised respawn answers at the address
		// members already hold; without a state directory every run mints a
		// fresh service.
		const stateDir = optionalEnv("PANCAKE_ROOMS_STATE");
		const keyFile = stateDir === undefined ? null : `${stateDir}/onion-key`;
		let serviceKey: Uint8Array | undefined;
		if (keyFile !== null) {
			try {
				const stored = await Deno.readFile(keyFile);
				if (stored.length > 0) serviceKey = stored;
			} catch {
				// No stored key: ask Tor for a fresh service and store its key below.
			}
		}
		// Imported here rather than at the top, so the hermetic suite (which
		// imports this module for `serveDirectory`) never touches the onion
		// archive it does not install.
		const onion = await import("@pancake/onion");
		const server = await onion.listen({
			socks,
			control,
			serviceKey,
			forward: forwardPort === 0 ? undefined : `127.0.0.1:${forwardPort}`,
		}, host);
		if (keyFile !== null && serviceKey === undefined && server.serviceKey.length > 0) {
			await Deno.writeFile(keyFile, server.serviceKey);
		}
		await announce("onion", server, server.uri);
	} else {
		const bindHost = optionalEnv("PANCAKE_ROOMS_BIND") ?? "127.0.0.1";
		const announceHost = optionalEnv("PANCAKE_ROOMS_ANNOUNCE_HOST");
		const asked = Number(positional[0] ?? "0");
		if (asked !== 0) refuseHeldPort(bindHost, asked);
		// A wildcard bind has no address of its own to sign, so it needs the
		// dialable hostname before the listener opens; saying which knob is
		// missing beats surfacing the core's refusal after the fact.
		if ((bindHost === "0.0.0.0" || bindHost === "::" || bindHost === "[::]") && announceHost === undefined) {
			throw new Error(
				`PANCAKE_ROOMS_BIND=${bindHost} binds every interface, so PANCAKE_ROOMS_ANNOUNCE_HOST must name the dialable hostname to advertise`,
			);
		}
		// The host is minted here rather than left to `listen`'s default,
		// so this branch names the rooms codec exactly as the iroh branch
		// above does. A default host would speak the Syrup interop floor
		// and refuse every rooms peer's frames.
		const tcp = await roomsListen(bindHost, asked, host, announceHost);
		// With an announce host, the listener itself advertises
		// `<announce-host>:<port>` (roomsListen signs it into the locator), so
		// the announce line simply reads the listener's own designator back.
		await announce("tcp", tcp, announceHost ? tcp.designator : String(tcp.port));
	}
}

if (import.meta.main) {
	try {
		await start();
	} catch (err) {
		// Said as a sentence an operator can act on, and exited non-zero so a
		// supervisor learns the same thing. The state file is named because it is
		// the one input here a person can repair by hand.
		const said = err instanceof Error ? err.message : String(err);
		console.error(`rooms: could not start: ${said}`);
		// A status no version of this defines, which is what a shared library built
		// from a different revision than this source looks like from here.
		const code = (err as { code?: unknown }).code;
		if (impossibleStatus(code)) {
			console.error(
				`rooms: ${code} is not a status this version defines. That usually means the pancake shared ` +
					"libraries were built from a different revision than this source: rebuild them with " +
					"`zig build rooms-deploy-prep` and start again.",
			);
		}
		const state = optionalEnv("PANCAKE_ROOMS_STATE");
		if (state !== undefined && /rooms state/.test(said)) {
			console.error(
				`rooms: ${state}/rooms.json holds this server's identity and its durable room links. ` +
					"Repair it, or move it aside to start fresh — the links it names will not come back.",
			);
		}
		Deno.exit(1);
	}
}
