// The listen / accept surface (binding spine Pass 3d): `Server`,
// `KeyedTcpServer`, and the top-level `listen` / `listenKeyedTcp` hosters.
// Session owns mint/handshake (`establishAccepted`); this module owns the
// listening socket, accept loop, and self-designator bind. iroh hosting lives
// in `@pancake/iroh`, not here.

import { Session } from "./session.ts";
import { Host } from "./host.ts";
import { net } from "./internal/ffi/runtime.ts";
import { type NetConn, type NetListener } from "./internal/seam.ts";
import { INVALID_ARGUMENT } from "@pancake/abi";
import { PancakeError } from "./errors.ts";
import { type Codec } from "./value.ts";
import {
	keyedTcpLocator,
	socketAddrDesignator,
	TRANSPORT_KEYED_TCP,
	TRANSPORT_TCP,
} from "./locator.ts";

/** Wrap a socket a server already accepted and complete the keyed handshake
 * from the responder side. Resolves once the session is open. */
async function acceptTcp(tcp: NetConn, host: Host): Promise<Session> {
	const la = tcp.localAddr();
	try {
		// serverDesignator unused for address transports; acceptedLocalAddr signs.
		return await Session.establishAccepted(
			host,
			TRANSPORT_TCP,
			"",
			tcp,
			socketAddrDesignator(la.hostname, la.port),
		);
	} catch (err) {
		tcp.close();
		throw err;
	}
}

/** A listening server. Iterate it for an accepted `Session` per partner —
 * `for await (const session of listen(host, port)) { ... }`.
 *
 * Binding the socket is asynchronous on some runtimes, so `await
 * server.ready()` for the bound port (the value you need when you pass port 0
 * for an ephemeral one). The async iterator awaits the bind itself, so a
 * `for await` works without `ready()`; the `port` getter requires `ready()` to
 * have resolved. */
export class Server {
	#pending: Promise<NetListener>;
	#listener: NetListener | null = null;
	// One identity and one shared gift registry for the whole host: every
	// accepted session keys its handshake with this host's seed and shares
	// its gift registry, so a gift deposited on one accepted session is
	// withdrawable on another — the exporter-host shape a three-party handoff
	// recipient relies on (ADR-0009/ADR-0056).
	readonly #host: Host;

	constructor(pending: Promise<NetListener>, host: Host = new Host()) {
		this.#pending = pending;
		this.#host = host;
	}

	/** The server's shared host, its retained identity and gift registry. An
	 * exporter application reads it to originate gifts that recipients withdraw
	 * across the host's sessions. */
	get host(): Host {
		return this.#host;
	}

	/** Await the bind and return the bound TCP port. Idempotent. */
	async ready(): Promise<number> {
		if (this.#listener === null) this.#listener = await this.#pending;
		return this.#listener.port;
	}

	/** The bound TCP port. Throws until `ready()` has resolved the bind. */
	get port(): number {
		if (this.#listener === null) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"server not bound yet; await server.ready() before reading port",
			);
		}
		return this.#listener.port;
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<Session> {
		const listener = await this.#pending;
		this.#listener = listener;
		// Closing the listener when iteration ends (a `break`, a `return`, or the
		// listener itself closing) frees the bound socket, so a one-client server
		// (`for await (const session of server) { …; break; }`) leaves nothing
		// holding the runtime's event loop open.
		try {
			while (true) {
				let tcp: NetConn;
				try {
					tcp = await listener.accept();
				} catch {
					return; // the listener was closed
				}
				// A handshake failure belongs to that one connection, a client that
				// dialed and died, or a stray port probe. Skipping it keeps the
				// listener accepting, so one rude caller cannot take the whole
				// server down.
				let session: Session;
				try {
					session = await acceptTcp(tcp, this.#host);
				} catch {
					continue;
				}
				yield session;
			}
		} finally {
			listener.close();
		}
	}

	/** Stop accepting new partners. Closes the listening socket only;
	 * sessions already accepted are unaffected. */
	close(): void {
		if (this.#listener !== null) {
			this.#listener.close();
			return;
		}
		void this.#pending.then((l) => l.close()).catch(() => {});
	}
}

/** Accept connections on `bindHost:port`, returning a `Server` you iterate for
 * each accepted `Session`. The bind completes asynchronously; `await
 * server.ready()` for the bound port. The server holds one host identity and
 * gift registry, read as `server.host` — a dialed sibling session shares it
 * with `connect(locator, reachability, server.host)` for a three-party
 * handoff. `codec` picks the wire grammar for a server built on a fresh host;
 * a supplied `host` already carries one, and a conflicting explicit codec is
 * refused rather than silently ignored. */
export function listen(
	bindHost: string,
	port: number,
	host: Host = new Host(),
	codec?: Codec,
): Server {
	if (codec !== undefined && codec !== host.codec) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`codec "${codec}" conflicts with the host's "${host.codec}"; mint the host with it instead`,
		);
	}
	const pending = net.listen(bindHost, port).then((listener) => {
		// This host also dials (the gifter side of a handoff), and its dials sign
		// the listener's own address so a partner's crossed-hellos table can
		// recognize it. Prefer the kernel-bound address (IPv6-safe brackets).
		const la = listener.localAddr();
		host.setSelfDesignator(socketAddrDesignator(la.hostname, la.port));
		return listener;
	});
	return new Server(pending, host);
}

/** A keyed-tcp listening server: TCP sockets under a durable key designator
 * (ADR-0075). The host's Ed25519 identity *is* the locator designator and the
 * session signing key — one seed, not a second minted identity. */
export class KeyedTcpServer {
	#pending: Promise<NetListener>;
	#listener: NetListener | null = null;
	readonly #host: Host;
	readonly #designator: string;

	constructor(pending: Promise<NetListener>, host: Host, designator: string) {
		this.#pending = pending;
		this.#host = host;
		this.#designator = designator;
	}

	get host(): Host {
		return this.#host;
	}

	get designator(): string {
		return this.#designator;
	}

	async ready(): Promise<number> {
		if (this.#listener === null) this.#listener = await this.#pending;
		return this.#listener.port;
	}

	get port(): number {
		if (this.#listener === null) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"server not bound yet; await server.ready() before reading port",
			);
		}
		return this.#listener.port;
	}

	async uri(): Promise<string> {
		const listener = this.#listener ?? await this.#pending;
		this.#listener = listener;
		const la = listener.localAddr();
		return keyedTcpLocator(this.#designator, la.hostname, la.port);
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<Session> {
		const listener = await this.#pending;
		this.#listener = listener;
		try {
			while (true) {
				let tcp: NetConn;
				try {
					tcp = await listener.accept();
				} catch {
					return;
				}
				try {
					const la = tcp.localAddr();
					yield await Session.establishAccepted(
						this.#host,
						TRANSPORT_KEYED_TCP,
						this.#designator,
						tcp,
						socketAddrDesignator(la.hostname, la.port),
					);
				} catch {
					continue;
				}
			}
		} finally {
			listener.close();
		}
	}

	close(): void {
		if (this.#listener !== null) {
			this.#listener.close();
			return;
		}
		void this.#pending.then((l) => l.close()).catch(() => {});
	}
}

/** Bind `bindHost`:`port` as a keyed-tcp listener whose designator is the public
 * half of `seed` (or a fresh random seed when omitted). Pass the same seed
 * after a restart to keep the designator stable (ADR-0075). */
export function listenKeyedTcp(
	bindHost: string,
	port: number,
	seed?: Uint8Array,
	codec?: Codec,
): KeyedTcpServer {
	if (seed !== undefined && seed.length !== 32) {
		throw new PancakeError(INVALID_ARGUMENT, "listenKeyedTcp: seed must be 32 bytes");
	}
	const host = new Host(seed, { codec });
	const designator = host.designator();
	const pending = net.listen(bindHost, port).then((listener) => {
		host.setSelfDesignator(designator);
		return listener;
	});
	return new KeyedTcpServer(pending, host, designator);
}
