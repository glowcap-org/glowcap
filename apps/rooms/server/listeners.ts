// Runtime listener administration, held as a capability (`--admin-listeners`).
//
// Like inspect, the listeners object is not a directory method: it is a second
// Host publication under an unguessable swiss, and holding that swiss is the
// whole of the authority — no ranks, no accounts. The registry below is only
// built when the flag asks for it, so a server started without it allocates
// nothing here.
//
// The capability is exactly as capable as this process: `up` can realize a
// transport only when what it needs was built in or named at start — the tcp
// family always, iroh when its archive loads, onion when a running Tor's
// endpoints arrived in the environment, the relay profiles when a relay URL
// was named at start or with the ask. Anything else refuses with a typed
// sentence naming what is missing, because an operator holding the swiss
// deserves the real boundary rather than a generic failure.

import type { Argument, Behavior, Host, Session } from "@pancake/runtime";
import { formatPeerUri, TRANSPORT_IROH, TRANSPORT_KEYED_TCP } from "@pancake/runtime";
import type { ProfileInfo } from "@pancake/runtime/transport";
import * as irohTransport from "@pancake/iroh";
import * as tcpTransport from "@pancake/tcp";
import * as relayTransport from "@pancake/relay";
import * as onionTransport from "@pancake/onion";
import { roomsListen } from "../lib/locator.ts";
import { optionalEnv } from "../lib/env.ts";
import { DOWN, LIST, UP } from "../lib/protocol.ts";
import {
	LISTENER_SERVING,
	LISTENER_TRANSPORT_HELD,
	LISTENER_UNSUPPORTED,
	NO_SUCH_LISTENER,
	RoomError,
} from "../lib/errors.ts";
import { serveAccepted } from "./sessions.ts";

/** The transports an `up` may name. The set is closed here rather than passed
 * through to a listen call, so an arbitrary wire string never reaches one. */
const TRANSPORTS = [
	"tcp",
	TRANSPORT_KEYED_TCP,
	"noise-tcp",
	"iroh",
	"keyed-relay",
	"noise-relay",
	"onion",
] as const;
export type AdminTransport = (typeof TRANSPORTS)[number];

/** The tcp-socket family, which shares the bind host, the named-port probe,
 * and the advertised-host knob. */
const TCP_FAMILY = ["tcp", TRANSPORT_KEYED_TCP, "noise-tcp"] as const satisfies readonly AdminTransport[];
type TcpFamily = (typeof TCP_FAMILY)[number];

/** The relay rendezvous family, which registers held sockets at a relay
 * instead of binding a socket of its own. */
const RELAY_FAMILY = ["keyed-relay", "noise-relay"] as const satisfies readonly AdminTransport[];
type RelayFamily = (typeof RELAY_FAMILY)[number];

function inFamily<T extends AdminTransport>(
	family: readonly T[],
	transport: AdminTransport,
): transport is T {
	return (family as readonly AdminTransport[]).includes(transport);
}

/** What an `up` may carry beside the transport, already typed and bounded by
 * the behavior: the tcp family's bind host, port, and advertised host, and
 * the relay family's relay WebSocket URL. Anything left unset falls to the
 * server's own defaults, which are the hints `list` serves. */
interface UpOption {
	bind?: string | null;
	port?: number | null;
	advertise?: string | null;
	relayUrl?: string | null;
}

/** The env default behind a named listen option, so the hints `list` serves
 * show what this server would actually do with a blank field. */
const OPTION_ENV_DEFAULTS: Record<string, string> = {
	bind: "PANCAKE_ROOMS_BIND",
	advertise: "PANCAKE_ROOMS_ANNOUNCE_HOST",
	relay: "PANCAKE_ROOMS_RELAY_URL",
};

/** What `list` says about a transport beside its live state, so an operator
 * surface renders whatever this server offers instead of keeping a copy of
 * the set. Each description comes from the package that owns the profile
 * (`ProfileInfo`); this server contributes only which profiles it can
 * realize (`TRANSPORTS`). */
const CATALOG: ReadonlyMap<AdminTransport, ProfileInfo> = (() => {
	const described: readonly ProfileInfo[] = [
		...tcpTransport.profiles,
		...irohTransport.profiles,
		...relayTransport.profiles,
		...onionTransport.profiles,
	];
	const catalog = new Map<AdminTransport, ProfileInfo>();
	for (const transport of TRANSPORTS) {
		const info = described.find((profile) => profile.transport === transport);
		if (info === undefined) throw new Error(`no composed package describes ${transport}`);
		catalog.set(transport, info);
	}
	return catalog;
})();

/** The one sentence for a missing Tor, shared by the standing answer in
 * `list` and the refusal an `up` gives anyway. */
const ONION_NEEDS_TOR =
	"this server was started without a running Tor (PANCAKE_ONION_SOCKS and PANCAKE_ONION_CONTROL are not set), so no onion listener can come up";

/** How long a relay registration may take before the `up` refuses instead of
 * answering a row nothing stands behind. */
const RELAY_REGISTER_DEADLINE_MS = 5_000;

/** Open one register socket to prove the relay answers, then close it. The
 * relay drops a registration when its socket closes, so the probe consumes
 * nothing. The native provider keeps registration retries in the background,
 * so a completed listen is not the evidence the relay exists — this probe
 * is, and it runs before the provider adopts the route, because the provider
 * serves one route per loop and must not adopt a dead one. */
function probeRegisterEndpoint(url: string, designator: string): Promise<void> {
	return new Promise((resolve, reject) => {
		let ws: WebSocket;
		try {
			ws = new WebSocket(`${url}?id=${designator}`);
		} catch (error) {
			reject(new RoomError(LISTENER_UNSUPPORTED, `the relay refused a register socket: ${error}`));
			return;
		}
		const expiry = setTimeout(() => {
			ws.close();
			reject(new RoomError(LISTENER_UNSUPPORTED, "the relay did not answer a register socket in time"));
		}, RELAY_REGISTER_DEADLINE_MS);
		ws.addEventListener("open", () => {
			clearTimeout(expiry);
			ws.close();
			resolve();
		}, { once: true });
		ws.addEventListener("error", () => {
			clearTimeout(expiry);
			reject(
				new RoomError(LISTENER_UNSUPPORTED, `no relay answered a register socket at ${url}`),
			);
		}, { once: true });
	});
}

/** Both first-party relays register at `/register` beside whatever path
 * dialers use, so the register endpoint is derived from the relay URL rather
 * than asked for separately. */
function rendezvousRegisterUrl(relayUrl: string): string {
	let base: URL;
	try {
		base = new URL(relayUrl);
	} catch {
		throw new RoomError(LISTENER_UNSUPPORTED, `"${relayUrl}" is not a WebSocket URL`);
	}
	if (base.protocol !== "ws:" && base.protocol !== "wss:") {
		throw new RoomError(LISTENER_UNSUPPORTED, `a relay URL uses ws or wss, got "${relayUrl}"`);
	}
	base.pathname = "/register";
	base.search = "";
	base.hash = "";
	return base.href;
}

/** How many listeners one server holds at once. A resource bound, not an
 * authorization: whoever holds the capability may use all of it. */
const MAX_ADMIN_LISTENERS = 8;

/** What every transport's server object answers: admit sessions, stop
 * admitting, and select its locator as the Host's signed location. The tcp,
 * iroh, and onion servers all extend the binding's `DriverServer`, which is
 * where this contract actually lives. */
interface AdminServer extends AsyncIterable<Session> {
	close(): Promise<void>;
	select(): void;
}

interface Row {
	id: number;
	transport: AdminTransport;
	locator: string;
	server: AdminServer;
}

/** Refuse a named local port another listener already holds.
 *
 * A pancake listener asks for a reusable address, which on Linux lets a second
 * one hold the same address rather than refusing it: both bind, both announce,
 * and the kernel hands each arriving connection to whichever it likes. Two
 * servers with different identities then answer one address, and in a room
 * that looks like two members joining the same name and never seeing each
 * other, with nothing said on either side.
 *
 * So ask first, with a socket that does not share: `Deno.listen` sets no such
 * option, so it is refused by exactly the listener this needs to find and by
 * nothing else. Only for a port that was named — asking for an ephemeral one
 * is asking for whichever is free. The onion arm probes the same way for the
 * local endpoint Tor forwards its service to. */
export function refuseHeldPort(hostname: string, port: number): void {
	try {
		Deno.listen({ hostname, port }).close();
	} catch {
		throw new Error(
			`${hostname}:${port} is already in use, most likely by another rooms server. ` +
				"Two of them can hold one address without either being told, so this one is " +
				"stopping rather than splitting members between rooms they cannot see across. " +
				"Stop the other server, or give this one a different port.",
		);
	}
}

/** iroh dial posture from the environment: `direct` (default, hermetic) or
 * `discovery` (n0 + pkarr). Throws on an unknown word; the boot path wraps
 * this in its own exit, a runtime `up` surfaces the sentence. */
export function irohReachability():
	| typeof irohTransport.Reachability.Direct
	| typeof irohTransport.Reachability.Discovery {
	const choice = (optionalEnv("PANCAKE_ROOMS_REACHABILITY") ?? "direct").toLowerCase();
	if (choice === "discovery") return irohTransport.Reachability.Discovery;
	if (choice === "direct") return irohTransport.Reachability.Direct;
	throw new Error(`unknown reachability "${choice}" (expected direct or discovery)`);
}

/** Whether a listen failure means the transport was never available here — the
 * archive is not built (`… transport unavailable: could not load …`) or the
 * runtime refuses the loader — as opposed to an ordinary failure like a held
 * port, which stays what it is. */
function unavailable(error: unknown): boolean {
	const said = error instanceof Error ? error.message : String(error);
	return /transport unavailable|could not (load|open)|unstable/i.test(said);
}

/** The live listeners of one rooms server, and the verbs the admin capability
 * drives them with. Built only when `--admin-listeners` asked for it. */
export class ListenerRegistry {
	readonly #host: Host;
	readonly #rows: Row[] = [];
	/** The dialable locator this server announced (`ROOMS-SERVER-LISTENING`).
	 * The web relay dials exactly this, so the row wearing it is the one
	 * carrying every browser tab — verified by comparison rather than assumed
	 * to be whichever listener came first. */
	#announced = "";
	#nextId = 1;

	constructor(host: Host) {
		this.#host = host;
	}

	/** Adopt the listener the boot path already opened and announced. */
	adoptBoot(transport: AdminTransport, server: AdminServer, announced: string): void {
		this.#announced = announced;
		this.#rows.push({ id: this.#nextId++, transport, locator: announced, server });
	}

	#serving(row: Row): boolean {
		return row.locator === this.#announced;
	}

	/** What this server can already tell would refuse an `up`, before one is
	 * asked. Only cheaply knowable obstacles belong here — an archive that may
	 * or may not load answers at the ask instead. */
	#unavailable(transport: AdminTransport): string {
		if (transport !== "onion") return "";
		const socks = optionalEnv("PANCAKE_ONION_SOCKS");
		const control = optionalEnv("PANCAKE_ONION_CONTROL");
		return socks === undefined || control === undefined ? ONION_NEEDS_TOR : "";
	}

	/** The knobs a seat's `up` accepts, as `[name, kind, hint]` rows. The
	 * package declares them; this server swaps in the hint an env default
	 * makes true, so a blank field means what the list says it means. */
	#servedTakes(transport: AdminTransport): Argument {
		return CATALOG.get(transport)!.takes.map((option): Argument => {
			const env = OPTION_ENV_DEFAULTS[option.name];
			const configured = env === undefined ? undefined : optionalEnv(env);
			return [option.name, option.kind, configured ?? option.hint];
		});
	}

	/** One transport's seat: the catalog entry plus its live state. Down seats
	 * carry id `0` and an empty locator. */
	#entry(transport: AdminTransport): Argument {
		const info = CATALOG.get(transport)!;
		const live = this.#rows.find((row) => row.transport === transport);
		return [
			transport,
			info.summary,
			info.reference,
			info.referenceName,
			this.#servedTakes(transport),
			this.#unavailable(transport),
			live?.id ?? 0,
			live?.locator ?? "",
			live !== undefined && this.#serving(live),
		];
	}

	rows(): Argument[] {
		return TRANSPORTS.map((transport) => this.#entry(transport));
	}

	async up(transport: AdminTransport, option: UpOption): Promise<Argument> {
		if (this.#rows.length >= MAX_ADMIN_LISTENERS) {
			throw new Error(`this server holds at most ${MAX_ADMIN_LISTENERS} listeners at once`);
		}
		// The native runtime holds one live listener per transport symbol for
		// loop listeners; a rendezvous registration never reaches it, so the
		// registry holds the same line for every symbol itself and the runtime
		// mapping below stays a backstop.
		if (this.#rows.some((held) => held.transport === transport)) {
			throw new RoomError(
				LISTENER_TRANSPORT_HELD,
				`this runtime holds one live listener per transport, and its ${transport} listener is already up; take that one down first`,
			);
		}
		const brought = await this.#bringUp(transport, option).catch((error) => {
			// The native runtime admits one live listener per transport symbol
			// (`HostRuntime.reserveListenerProfile`), so a second listener on a
			// transport already up is its refusal, said as this capability's own.
			const said = error instanceof Error ? error.message : String(error);
			if (said.includes("ListenerProfileInUse")) {
				throw new RoomError(
					LISTENER_TRANSPORT_HELD,
					`this runtime holds one live listener per transport, and its ${transport} listener is already up; take that one down first`,
				);
			}
			throw error;
		});
		const row: Row = { id: this.#nextId++, transport, ...brought };
		this.#rows.push(row);
		// Serve the new listener's sessions the same way the boot listener's are
		// served; the directory is a Host-wide publication, so nothing more is
		// needed for a session arriving here to reach it.
		void serveAccepted(brought.server).catch((error) => {
			console.error(`rooms: listener ${row.id} stopped serving: ${error}`);
		});
		// The binding's listen selects the new listener's locator as the location
		// signed into new sessions. An admin `up` must not move the Host's signed
		// location off the announced listener the fleet already dials, so hand the
		// selection straight back.
		const serving = this.#rows.find((held) => this.#serving(held));
		serving?.server.select();
		return this.#entry(transport);
	}

	async #bringUp(
		transport: AdminTransport,
		option: UpOption,
	): Promise<{ locator: string; server: AdminServer }> {
		if (inFamily(TCP_FAMILY, transport)) {
			return await this.#bringUpTcpFamily(transport, option);
		}
		if (inFamily(RELAY_FAMILY, transport)) {
			return await this.#bringUpRendezvous(transport, option.relayUrl ?? null);
		}
		if (transport === "iroh") {
			try {
				const reach = irohReachability();
				const server = await irohTransport.listen(
					{ reachability: reach, idleTimeoutMs: 8_000 },
					{ host: this.#host },
				);
				const locator = reach === irohTransport.Reachability.Discovery
					? formatPeerUri(TRANSPORT_IROH, server.nodeId)
					: server.uri;
				return { locator, server };
			} catch (error) {
				if (unavailable(error)) {
					throw new RoomError(
						LISTENER_UNSUPPORTED,
						"the iroh archive is not built into this server (zig build iroh-abi, cargo required), so no iroh listener can come up",
					);
				}
				throw error;
			}
		}
		// Onion: pancake starts no Tor, so the endpoints of an already-running
		// daemon must have arrived in the environment. Without them there is
		// nothing to publish a service through, however the archive was built. A
		// runtime-up service takes a fresh address: the stored onion key under
		// PANCAKE_ROOMS_STATE belongs to the boot service alone.
		const socks = optionalEnv("PANCAKE_ONION_SOCKS");
		const control = optionalEnv("PANCAKE_ONION_CONTROL");
		if (socks === undefined || control === undefined) {
			throw new RoomError(LISTENER_UNSUPPORTED, ONION_NEEDS_TOR);
		}
		try {
			const server = await onionTransport.listen({ socks, control }, this.#host);
			return { locator: server.uri, server };
		} catch (error) {
			if (unavailable(error)) {
				throw new RoomError(
					LISTENER_UNSUPPORTED,
					"the onion archive is not built into this server, so no onion listener can come up",
				);
			}
			throw error;
		}
	}

	/** The three tcp-socket profiles share the bind host, the named-port
	 * probe, and the advertised-host knob; they differ only in which listen
	 * the provider package realizes. Each knob falls back to the env default
	 * the served hint names. The keyed and sealed profiles announce their
	 * complete `ocapn://` locator because the key designator, not the
	 * address, is the name a peer dials. */
	async #bringUpTcpFamily(
		transport: TcpFamily,
		option: UpOption,
	): Promise<{ locator: string; server: AdminServer }> {
		const bindHost = option.bind ?? optionalEnv("PANCAKE_ROOMS_BIND") ?? "127.0.0.1";
		const port = option.port ?? 0;
		if (port !== 0) refuseHeldPort(bindHost, port);
		const advertisedHost = option.advertise ?? optionalEnv("PANCAKE_ROOMS_ANNOUNCE_HOST");
		if (transport === "tcp") {
			const server = await roomsListen(bindHost, port, this.#host, advertisedHost);
			return { locator: server.designator, server };
		}
		const profile = transport === TRANSPORT_KEYED_TCP ? tcpTransport.keyed : tcpTransport.noise;
		const server = await profile.listen(bindHost, port, { host: this.#host, advertisedHost });
		return { locator: server.uri, server };
	}

	/** The relay profiles register held inbound sockets at a relay instead of
	 * binding a socket, so what they need is the relay's WebSocket URL — from
	 * the ask, or `PANCAKE_ROOMS_RELAY_URL` at start. The relay is probed
	 * before the provider adopts the route (`probeRegisterEndpoint` says
	 * why), so a dead relay refuses the `up` instead of answering a row
	 * nothing stands behind. */
	async #bringUpRendezvous(
		transport: RelayFamily,
		relayUrl: string | null,
	): Promise<{ locator: string; server: AdminServer }> {
		const route = relayUrl ?? optionalEnv("PANCAKE_ROOMS_RELAY_URL") ?? null;
		if (route === null) {
			throw new RoomError(
				LISTENER_UNSUPPORTED,
				`a ${transport} listener registers at a relay; name its WebSocket URL with the ask, or start the server with PANCAKE_ROOMS_RELAY_URL`,
			);
		}
		const registerUrl = rendezvousRegisterUrl(route);
		await probeRegisterEndpoint(registerUrl, this.#host.designator());
		const profile = transport === "keyed-relay" ? relayTransport.keyed : relayTransport.noise;
		const server = await profile.listen({
			relayUrl: route,
			registerUrl,
			host: this.#host,
			signal: AbortSignal.timeout(RELAY_REGISTER_DEADLINE_MS),
		});
		return { locator: server.uri, server };
	}

	async down(id: number): Promise<void> {
		const at = this.#rows.findIndex((row) => row.id === id);
		if (at === -1) throw new RoomError(NO_SUCH_LISTENER, `no listener is numbered ${id}`);
		const row = this.#rows[at];
		if (this.#serving(row)) {
			throw new RoomError(
				LISTENER_SERVING,
				`listener ${id} answers the locator this server announced, which the web relay and this admin session ride, so taking it down would cut them off`,
			);
		}
		// Stop admission first, remove the row only when that committed. Sessions
		// the listener already accepted stay live: down ends admission, not
		// members' conversations.
		await row.server.close();
		this.#rows.splice(at, 1);
	}
}

/** Run `work` from the event loop rather than inside the turn that asked.
 *
 * A behavior turn runs inside the native driver's own step, and the driver
 * refuses listener lifecycle operations re-entered there (`reentrancyCode`,
 * `src/c_abi/driver/loop.zig`): a synchronous `listener_close` mid-step is an
 * invalid argument, not a queued request. Deferring onto a timer moves the
 * open, select, or close after the step returns; the turn's answer was already
 * deferred onto a resolver vow the moment the behavior returned a promise, so
 * the caller notices nothing but the answer. */
function offTurn<T>(work: () => Promise<T>): Promise<T> {
	return new Promise((resolve, reject) => {
		setTimeout(() => work().then(resolve, reject), 0);
	});
}

/** The behavior published under the admin swiss. Every argument arrives off a
 * session this server does not own, so each is bounded and typed before it
 * reaches the registry — in the turn, so a malformed ask refuses at once. */
export function listenersBehavior(registry: ListenerRegistry): Behavior {
	return (verb: string, args: Argument[]): ReturnType<Behavior> => {
		if (verb === LIST) {
			return registry.rows();
		}
		if (verb === UP) {
			if (args.length < 1 || args.length > 2) {
				throw new Error("up takes a transport and, optionally, its named options");
			}
			const named = args[0];
			if (typeof named !== "string" || named.length > 16) {
				throw new Error("up takes the transport as a short string");
			}
			const transport = TRANSPORTS.find((known) => known === named);
			if (transport === undefined) {
				throw new RoomError(
					LISTENER_UNSUPPORTED,
					`"${named}" names no transport this server knows (${TRANSPORTS.join(", ")})`,
				);
			}
			const option: UpOption = {};
			if (args.length === 2) {
				const pairs = args[1];
				if (!Array.isArray(pairs) || pairs.length > 8) {
					throw new Error("up's options are a short list of [name, value] pairs");
				}
				const declared = CATALOG.get(transport)!.takes;
				for (const pair of pairs) {
					if (!Array.isArray(pair) || pair.length !== 2 || typeof pair[0] !== "string") {
						throw new Error("an up option is a [name, value] pair");
					}
					const [name, value] = pair;
					const knob = declared.find((takes) => takes.name === name);
					if (knob === undefined) {
						const known = declared.map((takes) => takes.name).join(", ");
						throw new Error(
							`a ${transport} listener has no "${name}" option` +
								(known === "" ? "" : ` (it takes ${known})`),
						);
					}
					if (knob.kind === "port") {
						if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 65535) {
							throw new Error(`${name} is an integer between 0 and 65535`);
						}
					} else if (typeof value !== "string" || value.length === 0 || value.length > 4096) {
						throw new Error(`${name} is a non-empty string under 4 KiB`);
					}
					if (name === "bind") option.bind = value as string;
					else if (name === "port") option.port = value as number;
					else if (name === "advertise") option.advertise = value as string;
					else if (name === "relay") option.relayUrl = value as string;
				}
			}
			return offTurn(() => registry.up(transport, option));
		}
		if (verb === DOWN) {
			if (args.length !== 1) throw new Error("down takes the listener's number");
			const id = args[0];
			if (typeof id !== "number" || !Number.isInteger(id) || id < 1 || id > 1_000_000) {
				throw new Error("down takes the number list answered");
			}
			return offTurn(() => registry.down(id)).then(() => undefined);
		}
		throw new Error(`listeners has no method ${verb}`);
	};
}
