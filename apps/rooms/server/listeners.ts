// Runtime listener administration, held as a capability (`--admin-listeners`).
//
// Like inspect, the listeners object is not a directory method: it is a second
// Host publication under an unguessable swiss, and holding that swiss is the
// whole of the authority — no ranks, no accounts. The server always keeps the
// small listener inventory because it also owns durable route advertisement;
// the flag controls only whether administration is published.
//
// The capability is exactly as capable as this process: `up` can realize a
// transport only when what it needs was built in or named at start — the tcp
// family always, iroh when its archive loads, onion when a running Tor's
// endpoints arrived in the environment, the relay profiles when a relay URL
// was named at start or with the ask. Anything else refuses with a typed
// sentence naming what is missing, because an operator holding the swiss
// deserves the real boundary rather than a generic failure.

import { type Argument, type Host, retainCleanupFailures, type Session } from "@pancake/runtime";
import {
	FEATURE_MULTI_LOCATION,
	formatLocatorUri,
	formatPeerUri,
	TRANSPORT_IROH,
	TRANSPORT_KEYED_RELAY,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_RELAY,
	TRANSPORT_NOISE_TCP,
	TRANSPORT_ONION,
	TRANSPORT_TCP,
} from "@pancake/runtime";
import type { ProfileInfo } from "@pancake/runtime/transport";
import * as irohTransport from "@pancake/iroh";
import * as tcpTransport from "@pancake/tcp";
import * as relayTransport from "@pancake/relay";
import * as onionTransport from "@pancake/onion";
import { roomsListen } from "../lib/locator.ts";
import { roomsIdentityRoute } from "../lib/routes.ts";
import { optionalEnv } from "../lib/env.ts";
import {
	LISTENER_OPTION_NAMES,
	LISTENER_TRANSPORTS,
	type ListenerOptions,
	type ListenerTransport,
} from "../lib/listeners.ts";
import {
	LISTENER_SERVING,
	LISTENER_TRANSPORT_HELD,
	LISTENER_UNSUPPORTED,
	NO_SUCH_LISTENER,
	RoomError,
} from "../lib/errors.ts";
import type { RoomServerSessions } from "./sessions.ts";
import type { TroubleJournal } from "./journal.ts";
import type { RoomServerOperationsState } from "./operations_state.ts";

/** The transports an `up` may name. The set is closed here rather than passed
 * through to a listen call, so an arbitrary wire string never reaches one. */
const TRANSPORTS = LISTENER_TRANSPORTS;
export type AdminTransport = ListenerTransport;

/** The tcp-socket family, which shares the bind host, the named-port probe,
 * and the advertised-host knob. */
const TCP_FAMILY = [
	TRANSPORT_TCP,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_NOISE_TCP,
] as const satisfies readonly AdminTransport[];
type TcpFamily = (typeof TCP_FAMILY)[number];

/** The relay rendezvous family, which registers held sockets at a relay
 * instead of binding a socket of its own. */
const RELAY_FAMILY = [TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY] as const satisfies readonly AdminTransport[];
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
export interface ListenerUpOptions {
	bind?: string | null;
	port?: number | null;
	advertise?: string | null;
	relayUrl?: string | null;
}

function listenerOptions(option: ListenerUpOptions): ListenerOptions {
	return {
		...(option.bind == null ? {} : { bind: option.bind }),
		...(option.port == null ? {} : { port: option.port }),
		...(option.advertise == null ? {} : { advertise: option.advertise }),
		...(option.relayUrl == null ? {} : { relay: option.relayUrl }),
	};
}

function upOption(options: ListenerOptions): ListenerUpOptions {
	return {
		...(typeof options.bind === "string" ? { bind: options.bind } : {}),
		...(typeof options.port === "number" ? { port: options.port } : {}),
		...(typeof options.advertise === "string" ? { advertise: options.advertise } : {}),
		...(typeof options.relay === "string" ? { relayUrl: options.relay } : {}),
	};
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
		if (info == null) throw new Error(`no composed package describes ${transport}`);
		const declared = info.takes.map((option) => option.name).sort().join("\u0000");
		const persisted = [...LISTENER_OPTION_NAMES[transport]].sort().join("\u0000");
		if (declared !== persisted) throw new Error(`listener option vocabulary differs for ${transport}`);
		catalog.set(transport, info);
	}
	return catalog;
})();

/** Why a missing Tor stops an onion listener, shared by the standing answer
 * in `list` and the refusal an `up` gives anyway. Both positions render it on
 * its own, so it is written as sentences rather than as a clause something
 * else introduces. */
const ONION_NEEDS_TOR =
	"This server was started without a running Tor, so no onion listener can come up. PANCAKE_ONION_SOCKS and PANCAKE_ONION_CONTROL are not set.";

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
			reject(new RoomError(LISTENER_UNSUPPORTED, `The relay refused a register socket: ${error}`));
			return;
		}
		const expiry = setTimeout(() => {
			ws.close();
			reject(new RoomError(LISTENER_UNSUPPORTED, "The relay did not answer a register socket in time."));
		}, RELAY_REGISTER_DEADLINE_MS);
		ws.addEventListener("open", () => {
			clearTimeout(expiry);
			ws.close();
			resolve();
		}, { once: true });
		ws.addEventListener("error", () => {
			clearTimeout(expiry);
			reject(
				new RoomError(LISTENER_UNSUPPORTED, `No relay answered a register socket at ${url}.`),
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
		throw new RoomError(LISTENER_UNSUPPORTED, `"${relayUrl}" is not a WebSocket URL.`);
	}
	if (base.protocol !== "ws:" && base.protocol !== "wss:") {
		throw new RoomError(LISTENER_UNSUPPORTED, `A relay URL uses ws or wss, and "${relayUrl}" uses neither.`);
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
	managed: boolean;
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

/** The live listeners and the verbs the optional admin capability drives. */
export class ListenerRegistry {
	readonly #host: Host;
	readonly #state: RoomServerOperationsState | null;
	readonly #sessions: RoomServerSessions;
	readonly #journal: TroubleJournal;
	readonly #rows: Row[] = [];
	/** The dialable locator this server announced (`ROOMS-SERVER-LISTENING`).
	 * The web relay dials exactly this, so the row wearing it is the one
	 * carrying every browser tab — verified by comparison rather than assumed
	 * to be whichever listener came first. */
	#announced = "";
	#nextId = 1;

	constructor(
		host: Host,
		sessions: RoomServerSessions,
		journal: TroubleJournal,
		state: RoomServerOperationsState | null = null,
	) {
		this.#host = host;
		this.#sessions = sessions;
		this.#state = state;
		this.#journal = journal;
	}

	/** Adopt the listener the boot path already opened and announced. */
	adoptBoot(transport: AdminTransport, server: AdminServer, announced: string): void {
		this.#announced = announced;
		this.#rows.push({ id: this.#nextId++, transport, locator: announced, server, managed: false });
	}

	async restore(): Promise<void> {
		if (this.#state == null) return;
		for (const intent of this.#state.listeners()) {
			if (this.#rows.some((row) => row.transport === intent.transport)) continue;
			try {
				await this.up(intent.transport, upOption(intent.options), false);
			} catch (error) {
				this.#journal.note(`could not restore the ${intent.transport} listener`, error);
			}
		}
	}

	#serving(row: Row): boolean {
		return row.locator === this.#announced;
	}

	/** What this server can already tell would refuse an `up`, before one is
	 * asked. Only cheaply knowable obstacles belong here — an archive that may
	 * or may not load answers at the ask instead. */
	#unavailable(transport: AdminTransport): string {
		if (transport !== TRANSPORT_ONION) return "";
		const socks = optionalEnv("PANCAKE_ONION_SOCKS");
		const control = optionalEnv("PANCAKE_ONION_CONTROL");
		return socks == null || control == null ? ONION_NEEDS_TOR : "";
	}

	/** The knobs a seat's `up` accepts, as `[name, kind, hint]` rows. The
	 * package declares them; this server swaps in the hint an env default
	 * makes true, so a blank field means what the list says it means. */
	#servedTakes(transport: AdminTransport): Argument {
		return CATALOG.get(transport)!.takes.map((option): Argument => {
			const env = OPTION_ENV_DEFAULTS[option.name];
			const configured = env == null ? undefined : optionalEnv(env);
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
			live != null && this.#serving(live),
		];
	}

	rows(): Argument[] {
		return TRANSPORTS.map((transport) => this.#entry(transport));
	}

	/** The location new durable Rooms links should carry for this caller. */
	advertisedLocation(session: Session): string {
		const concrete = this.#rows.find((row) => row.transport === session.transportName)?.locator ?? this.#announced;
		const profile = session.profile;
		if (profile.captpVersion !== "next" || (profile.features & FEATURE_MULTI_LOCATION) === 0) return concrete;
		const identity = roomsIdentityRoute(this.#host.designator(), this.#rows.map((row) => row.locator));
		return identity === null ? concrete : formatLocatorUri(identity);
	}

	async up(transport: AdminTransport, option: ListenerUpOptions, remember = true): Promise<Argument> {
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
				`This runtime holds one live listener per transport, and its ${transport} listener is already up. Take that one down first.`,
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
					`This runtime holds one live listener per transport, and its ${transport} listener is already up. Take that one down first.`,
				);
			}
			throw error;
		});
		if (remember && this.#state != null) {
			try {
				await this.#state.rememberListener({ transport, options: listenerOptions(option) });
			} catch (error) {
				throw await retainCleanupFailures(error, [() => brought.server.close()]);
			}
		}
		const row: Row = { id: this.#nextId++, transport, ...brought, managed: this.#state != null };
		this.#rows.push(row);
		// Serve the new listener's sessions the same way the boot listener's are
		// served; the directory is a Host-wide publication, so nothing more is
		// needed for a session arriving here to reach it.
		void this.#sessions.serve(brought.server).catch((error) => {
			this.#journal.note(`listener ${row.id} stopped serving`, error);
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
		option: ListenerUpOptions,
	): Promise<{ locator: string; server: AdminServer }> {
		if (inFamily(TCP_FAMILY, transport)) {
			return await this.#bringUpTcpFamily(transport, option);
		}
		if (inFamily(RELAY_FAMILY, transport)) {
			return await this.#bringUpRendezvous(transport, option.relayUrl ?? null);
		}
		if (transport === TRANSPORT_IROH) {
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
						"The iroh archive is not built into this server, so no iroh listener can come up. Building it takes zig build iroh-abi, which needs cargo.",
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
		if (socks == null || control == null) {
			throw new RoomError(LISTENER_UNSUPPORTED, ONION_NEEDS_TOR);
		}
		try {
			const server = await onionTransport.listen({ socks, control }, this.#host);
			return { locator: server.uri, server };
		} catch (error) {
			if (unavailable(error)) {
				throw new RoomError(
					LISTENER_UNSUPPORTED,
					"The onion archive is not built into this server, so no onion listener can come up.",
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
		option: ListenerUpOptions,
	): Promise<{ locator: string; server: AdminServer }> {
		const bindHost = option.bind ?? optionalEnv("PANCAKE_ROOMS_BIND") ?? "127.0.0.1";
		const port = option.port ?? 0;
		if (port !== 0) refuseHeldPort(bindHost, port);
		const advertisedHost = option.advertise ?? optionalEnv("PANCAKE_ROOMS_ANNOUNCE_HOST");
		if (transport === TRANSPORT_TCP) {
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
				`A ${transport} listener registers at a relay. Name its WebSocket URL with the ask, or start the server with PANCAKE_ROOMS_RELAY_URL.`,
			);
		}
		const registerUrl = rendezvousRegisterUrl(route);
		await probeRegisterEndpoint(registerUrl, this.#host.designator());
		const profile = transport === TRANSPORT_KEYED_RELAY ? relayTransport.keyed : relayTransport.noise;
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
		if (at === -1) throw new RoomError(NO_SUCH_LISTENER, `No listener is numbered ${id}.`);
		const row = this.#rows[at];
		if (this.#serving(row)) {
			throw new RoomError(
				LISTENER_SERVING,
				`Listener ${id} answers the locator this server announced. The web relay and this admin session ride it, so taking it down would cut them off.`,
			);
		}
		if (row.managed) await this.#state?.forgetListener(row.transport);
		// Desired state commits first, so a close failure cannot resurrect this
		// listener after restart. Existing sessions stay live: down ends admission.
		await row.server.close();
		this.#rows.splice(at, 1);
	}

	/** Stop every listener this process owns. Used by controlled shutdown; the
	 * inventory is detached first so repeated signals and close failures cannot
	 * close one listener twice or strand another. */
	async close(): Promise<void> {
		const rows = this.#rows.splice(0);
		this.#announced = "";
		const results = await Promise.allSettled(rows.map((row) => row.server.close()));
		const failures = results.filter((result): result is PromiseRejectedResult => result.status === "rejected");
		if (failures.length > 0) {
			throw new AggregateError(failures.map((failure) => failure.reason), "could not close every room listener");
		}
	}
}
