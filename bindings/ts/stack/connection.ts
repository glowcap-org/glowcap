// The application surface over the byte-fed host (libpancake_driver,
// ADR-0072): `Connection` and its verbs (`fetch`/`send`/`tell`/`spawn`/
// `publish`/`enliven`/`serve`/`close`), the `RemotePromise` a send returns,
// `Server` and the top-level `connect`/`listen` dialers, and the two things
// the embedder contract leaves to the binding — the pump (read raw bytes off
// the transport, hand them to the core's stream delimiter
// `pancake_host_conn_feed_bytes`, which owns framing, drain the host's action
// queue, write what `take_outbound` drains) and the dial executor a DIAL
// action names (the recipient half of a three-party handoff opens its own
// socket to the exporter; the posture decision for a hint-less iroh give
// lives here). The host owns everything else: routing, redemption, gift
// origination, far vows. `mod.ts` re-exports the public members.

import { ocapnS as s } from "./internal/ffi/ocapn.ts";
import { driverS } from "./internal/ffi/driver.ts";
import { net, NULL, type Ptr } from "./internal/ffi/runtime.ts";
import {
	ab,
	type NetConn,
	type NetListener,
	readBytes,
	releaseManagedFrame,
} from "./internal/seam.ts";
import {
	type AbortDetail,
	abortDomainLabel,
	check,
	checkHost,
	FetchFailed,
	hostError,
	PancakeError,
	VowBroken,
} from "./errors.ts";
import {
	CLOSED,
	INVALID_ARGUMENT,
	LAST_ABORT_DOMAIN_OFF,
	LAST_ABORT_ERROR_NAME_OFF,
	LAST_ABORT_HAS_KIND_OFF,
	LAST_ABORT_KIND_NAME_OFF,
	LAST_ABORT_MESSAGE_OFF,
	LAST_ABORT_SIZE,
	MANAGED_FRAME_BYTES_OFF,
	MANAGED_FRAME_LEN_OFF,
	MANAGED_FRAME_SIZE,
	OK,
	REDEEMED_TOKEN_BASE,
	WOULD_BLOCK,
} from "./internal/abi.ts";
import {
	type AppValue,
	type Behavior,
	type Codec,
	Forward,
	isReference,
	liftArg,
	lowerArg,
	near,
	Reachability,
	Ref,
} from "./value.ts";
import { encodeArgs, refStruct } from "./codec.ts";
import { parseLocator, tcpLocator } from "./locator.ts";
import { Node } from "./host.ts";

// One encoder/decoder pair for the whole module: both are stateless here, and
// the send/tell spine encodes a verb on every call.
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();
import {
	type BehaviorEntry,
	currentTurnFor,
	entryFor,
	registerBehavior,
	runHosted,
	trampolinePointer,
	turnSpawn,
} from "./trampoline.ts";

/** How bytes move for one connection — the transport seam the byte-fed pump
 * reads and the FLUSH drain writes. The core supplies the TCP wrapper below
 * over the runtime's own sockets; the `@pancake/iroh` companion supplies the
 * iroh one, so the iroh artifact stays out of this core module entirely.
 * Framing is never the transport's job: the host's stream delimiter owns it. */
export interface Transport {
	/** The next chunk of inbound bytes, or `null` at a clean end of stream. */
	read(): Promise<Uint8Array | null>;
	/** Write every byte of `data`, awaiting the runtime's flush/backpressure. */
	write(data: Uint8Array): Promise<void>;
	close(): void;
}

/** Build the verbatim exporter location-record bytes to record on the node
 * when the exporter is reachable only by a dial hint (ADR-0009), for an
 * exporter whose own session record carries no hint. `transport`/`designator`
 * name the exporter; a non-empty `directAddresses` adds the exporter's
 * comma-separated socket addresses as a `direct-addresses` hint, so a
 * cross-process recipient dials it directly with no discovery service (an iroh
 * exporter reachable only by address). An empty `directAddresses` yields a
 * hint-less location identical to the exporter's own signed session record.
 * The bytes are in the handoff codec (Syrup, as a give is); the result feeds
 * `Connection.setExporterLocator`. */
export function encodePeerLocator(opts: {
	transport: string;
	designator: string;
	directAddresses?: string;
}): Uint8Array {
	const transport = utf8Encoder.encode(opts.transport);
	const designator = utf8Encoder.encode(opts.designator);
	const addrs = utf8Encoder.encode(opts.directAddresses ?? "");
	const outLoc = new Uint8Array(8), outLen = new Uint8Array(8);
	check(s.pancake_encode_peer_locator(
		ab(transport),
		BigInt(transport.length),
		ab(designator),
		BigInt(designator.length),
		ab(addrs),
		BigInt(addrs.length),
		ab(outLoc),
		ab(outLen),
	));
	const ptr = new DataView(outLoc.buffer).getBigUint64(0, true);
	const len = new DataView(outLen.buffer).getBigUint64(0, true);
	try {
		return readBytes(ptr, len);
	} finally {
		s.pancake_peer_locator_bytes_release(ptr, len);
	}
}

/** The handle `Connection.send` hands back: the eventual result of one
 * eventual-send, and — the point of promise pipelining (ADR-0007) — a target
 * you can `send` to before it resolves.
 *
 * It is a real `Promise<AppValue>` subclass, so `await conn.send(...)`,
 * `Promise.all([...])`, and `instanceof Promise` all work natively. Pass it
 * *unawaited* as the `target` of a later `send` to address the object the
 * answer will resolve to — the dependent call rides a `desc:answer` deliver
 * and the partner queues it until the answer settles, so a `create → use`
 * chain costs one round trip:
 *
 *     const task = conn.send(root, "create", ["x"]);  // not awaited
 *     conn.send(task, "assign", ["alice"]);            // pipelined at the answer
 *     const status = await conn.send(task, "status");  // settles the chain
 *
 * The send is issued (queued on the host) when this is created, but the bytes
 * leave the wire only when it — or any send pipelined behind it — is first
 * observed (awaited, `then`, `catch`, or `finally`). A handle that is never
 * observed is a fire-and-forget send; prefer `Connection.tell` for that.
 * Because the settle is drain-routed and no rejection is materialized until
 * the handle is observed, an unawaited anchor whose far answer *breaks* never
 * raises an unhandled rejection. `vow` is the host vow the answer settles.
 *
 * The projection verbs `index`/`untag` (ADR-0050/ADR-0052) pipeline an
 * element or untag access *at the answer*, before it resolves: each returns a
 * new `RemotePromise` for the projected value, addressed at this answer, so
 * `task.untag("cell").index(0)` costs no extra round trip. */
export class RemotePromise extends Promise<AppValue> {
	readonly #begin: () => Promise<AppValue>;
	#started = false;
	readonly #resolve: (value: AppValue | PromiseLike<AppValue>) => void;
	readonly #reject: (reason?: unknown) => void;
	// Issues a projection op (index/untag) at this vow and returns the new
	// RemotePromise.
	readonly #project: (op: "index" | "untag", key: string | bigint) => RemotePromise;

	constructor(
		/** The host vow this send's answer settles, or null for a local send
		 * (not pipelinable). Binding-internal. */
		readonly vow: bigint | null,
		begin: () => Promise<AppValue>,
		project: (op: "index" | "untag", key: string | bigint) => RemotePromise,
	) {
		// The executor only captures the settlement functions; it runs no flush,
		// so construction is side-effect-free and the send stays lazy.
		let resolve!: (value: AppValue | PromiseLike<AppValue>) => void;
		let reject!: (reason?: unknown) => void;
		super((res, rej) => {
			resolve = res;
			reject = rej;
		});
		this.#begin = begin;
		this.#resolve = resolve;
		this.#reject = reject;
		this.#project = project;
	}

	/** Pipeline an `op:index` for `i` at this answer (ADR-0050): a new
	 * `RemotePromise` for the List element of whatever this resolves to. */
	index(i: number | bigint): RemotePromise {
		return this.#project("index", BigInt(i));
	}

	/** Pipeline an `op:untag` for `tag` at this answer (ADR-0052): a new
	 * `RemotePromise` for the payload of whatever this resolves to, which must
	 * be a Tagged record whose tag equals `tag`. */
	untag(tag: string): RemotePromise {
		return this.#project("untag", tag);
	}

	// First observation issues the send's flush + reply wait, exactly once; the
	// native promise caches the settlement so repeated awaits share it. `catch`
	// and `finally` are inherited from `Promise` and delegate to this `then`, so
	// observing through any of them triggers the send.
	override then<R1 = AppValue, R2 = never>(
		onFulfilled?: ((value: AppValue) => R1 | PromiseLike<R1>) | null,
		onRejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
	): Promise<R1 | R2> {
		if (!this.#started) {
			this.#started = true;
			this.#begin().then(this.#resolve, this.#reject);
		}
		return super.then(onFulfilled, onRejected);
	}

	// Required, not decorative. `then`/`catch`/`finally` build their result
	// promise via `this.constructor[Symbol.species]`; without this, the platform
	// would call `new RemotePromise(executor)` against the `(vow, begin)`
	// constructor and every chained reaction would break. Returning `Promise`
	// also keeps derived promises plain (no per-hop subclass cost).
	static override get [Symbol.species](): PromiseConstructor {
		return Promise;
	}

	override get [Symbol.toStringTag](): string {
		return "RemotePromise";
	}
}

/** A live connection to one OCapN partner, the one object an application
 * holds, over one byte-fed `PancakeHostConn` the shared `Node` minted.
 *
 *   const conn = await connect(tcpLocator("127.0.0.1", 9099));
 *   conn.serve().catch((e) => console.error(e));
 *   const room = await conn.fetch("room");
 *   const inbox = conn.spawn((verb, args) => { ...; });
 *   await conn.send(room, "subscribe", ["alice", inbox]);
 */
export class Connection {
	#ptr: Ptr;
	readonly #node: Node;
	readonly #transport: Transport;
	// Inbound bytes read from the wire but not yet consumed by the core's
	// stream delimiter (the unconsumed tail of the last feed).
	#inbox: Uint8Array = new Uint8Array(0);
	#serving: Promise<void> | null = null;
	// Set the moment teardown begins (an application close, or the transport
	// reporting EOF), so the FAIL completions the break queues classify as the
	// typed CLOSED instead of partner breaks, and so a read cancelled by our
	// own close is a clean shutdown.
	#closing = false;
	#released = false;
	// Serializes transport writes. `flushOutbound` runs from the action drain,
	// the feed-failure choreography, and teardown; chaining each flush behind
	// the last keeps every frame whole and in submission order.
	#writing: Promise<void> = Promise.resolve();
	// Export position -> trampoline ctx id for the objects this connection
	// hosts, so a `Forward` whose target this side hosts composes in process.
	readonly #hosted = new Map<bigint, bigint>();

	/** True for an exporter connection the node's action drain dialed to redeem
	 * a handoff, so `close()` can sweep it. Binding-internal. */
	nodeDialed = false;

	// Distributed GC (ADR-0063), opt-in and off by default. When on, a `fetch`
	// result is registered so its import is released — one `op:gc-exports` —
	// once the runtime reclaims the last `Ref` to it. The cleanup callback only
	// parks the token; the release runs as its own event-loop task and at the
	// head of the connection's next verb, never from the finalizer callback.
	#gc = false;
	#gcRegistry: FinalizationRegistry<bigint> | null = null;
	readonly #gcPending: bigint[] = [];

	private constructor(ptr: Ptr, node: Node, transport: Transport) {
		this.#ptr = ptr;
		this.#node = node;
		this.#transport = transport;
		// Join the node's registry so a FLUSH action can find the transport and
		// a dialed exporter stays reachable for teardown.
		node.registerConnection(ptr, this);
	}

	/** The raw PancakeHostConn handle. Binding-internal: the node's DIAL arm
	 * reports it through `pancake_host_dialed`. */
	get raw(): Ptr {
		return this.#ptr;
	}

	/** The connection's shared node, its retained identity and gift registry.
	 * Shared by every connection of one node, so the gifter half of a handoff
	 * can reach a sibling connection's session keys. An application reads it to
	 * publish node-giftables (`Node.publishGiftable`), share one identity
	 * across dials, or set the redeem posture. */
	get node(): Node {
		return this.#node;
	}

	/** Whether teardown has begun. Binding-internal: the node's FAIL arm
	 * classifies a closing connection's breaks as the typed CLOSED. */
	get closing(): boolean {
		return this.#closing || this.#released;
	}

	/** Nonzero once the keyed handshake has completed and the session is open. */
	get sessionOpen(): boolean {
		return !this.#released &&
			driverS.pancake_host_conn_session_open(this.#ptr) === 1;
	}

	// ── Construction: establish, dial, accept ──────────────────────────────────

	/** Mint the dialing half of a connection to the peer `locatorUri` names
	 * over `transport` (already connected) and drive the keyed handshake open.
	 * The transport seam the companion packages build on: the iroh package
	 * calls this with its loop-driven transport. Binding-internal. */
	static establishDialed(
		node: Node,
		locatorUri: string,
		transport: Transport,
	): Promise<Connection> {
		const uri = utf8Encoder.encode(locatorUri);
		const out = new Uint8Array(8);
		checkHost(driverS.pancake_host_conn_open_dialed(
			node.raw,
			ab(uri),
			BigInt(uri.length),
			ab(out),
		));
		const conn = new Connection(
			new DataView(out.buffer).getBigUint64(0, true),
			node,
			transport,
		);
		return conn.#establish();
	}

	/** Mint the accepting half over a connection the caller's own listener
	 * produced: the keyed op:start-session signs the listener's own
	 * `transportName`/`designator` — the address a partner can actually dial,
	 * and the locator a give made on this node names as the exporter location.
	 * Binding-internal. */
	static establishAccepted(
		node: Node,
		transportName: string,
		designator: string,
		transport: Transport,
	): Promise<Connection> {
		const t = utf8Encoder.encode(transportName);
		const d = utf8Encoder.encode(designator);
		const out = new Uint8Array(8);
		checkHost(driverS.pancake_host_conn_open_accepted(
			node.raw,
			ab(t),
			BigInt(t.length),
			ab(d),
			BigInt(d.length),
			ab(out),
		));
		const conn = new Connection(
			new DataView(out.buffer).getBigUint64(0, true),
			node,
			transport,
		);
		return conn.#establish();
	}

	/** Dial `host:port`, complete the keyed OCapN handshake, and return a ready
	 * connection. The session is open (the `op:start-session` exchange has
	 * completed) before this resolves, so a `fetch`/`send` rides an established
	 * session, the same handshake a real Goblins peer requires. Prefer the
	 * transport-neutral `connect(tcpLocator(host, port))`; this stays for the
	 * tcp branch of `connect` and the exporter redeem to share one dial path. */
	static async connect(
		host: string,
		port: number,
		node: Node = new Node(),
	): Promise<Connection> {
		const tcp = await net.connect(host, port);
		try {
			return await Connection.establishDialed(node, tcpLocator(host, port), tcp);
		} catch (err) {
			// The socket opened but the open or handshake failed: `#establish`
			// abandons the half-built connection; a failed `open_dialed` leaves
			// only the socket to release.
			tcp.close();
			throw err;
		}
	}

	/** Wrap a socket a server already accepted and complete the keyed handshake
	 * from the responder side (used by `listen`). Resolves once the session is
	 * open. */
	static async accept(
		tcp: NetConn,
		node: Node = new Node(),
	): Promise<Connection> {
		const la = tcp.localAddr();
		try {
			return await Connection.establishAccepted(
				node,
				"tcp",
				`${la.hostname}:${la.port}`,
				tcp,
			);
		} catch (err) {
			tcp.close();
			throw err;
		}
	}

	/** Dial an exporter a DIAL action names, keyed with `node`'s retained
	 * identity, and bind the result to that same node so the redeemed
	 * capability and any further handoff it triggers share one identity and
	 * connection table. The action carries the locator's parsed pieces, so
	 * nothing re-parses the URI grammar here beyond the tcp host:port split.
	 * Binding-internal: the node's action drain calls this to redeem a give. */
	static async dialExporter(
		uri: string,
		transport: string,
		designator: string,
		directAddressesHint: string,
		node: Node,
	): Promise<Connection> {
		switch (transport) {
			case "iroh": {
				// The give either pins the exporter's `direct-addresses` (dial them
				// with no discovery service — the relay-less Direct posture) or names
				// the exporter by node id alone (resolve it by id under the node's
				// configured redeem posture: Discovery by default, lowerable to
				// DiscoveryNoRelay). One give shape thus covers an offline direct
				// dial and an internet dial-by-id alike. The iroh package is reached
				// lazily so the core never hard-depends on it.
				const iroh = await import("@pancake/iroh");
				return iroh.connectIroh(
					designator,
					directAddressesHint,
					directAddressesHint.length > 0 ? Reachability.Direct : node.redeemReachability,
					node,
				);
			}
			case "tcp": {
				// The host:port split is the core grammar's verdict, read off the
				// full locator rather than a re-derived string scan.
				const loc = parseLocator(uri);
				if (loc.hostPort === null) {
					throw new PancakeError(
						INVALID_ARGUMENT,
						`tcp locator designator is not host:port: ${designator}`,
					);
				}
				return Connection.connect(loc.hostPort.host, loc.hostPort.port, node);
			}
			default:
				throw new PancakeError(
					INVALID_ARGUMENT,
					`handoff redeem: unsupported exporter transport "${transport}" in ${uri}`,
				);
		}
	}

	// Drive the freshly opened connection's keyed handshake to an open session,
	// abandoning the connection on any failure (release + transport close) so a
	// rude partner costs one accept, never the listener.
	async #establish(): Promise<Connection> {
		try {
			// The signed op:start-session was encoded by the open; its FLUSH is on
			// the action queue, so the drain puts it on the wire now.
			await this.#node.kickActions();
			while (!this.sessionOpen) {
				const chunk = await this.#transport.read();
				if (chunk === null) {
					throw new PancakeError(
						CLOSED,
						"connection closed during the OCapN handshake",
					);
				}
				// The one feed body serves the handshake too: the core stops
				// consuming at the frame that opens the session, so a fast
				// partner's application frames arriving coalesced behind its
				// start-session stay buffered in the inbox until the application
				// has published and called `serve()` — otherwise a pipelined
				// fetch would be answered before the object it names exists.
				await this.#feed(chunk);
			}
			return this;
		} catch (err) {
			this.closeTransport();
			throw err;
		}
	}

	// ── The pump ────────────────────────────────────────────────────────────────

	/** Run the inbound loop: read raw bytes, hand them to the core's stream
	 * delimiter (behaviors run and vow completions queue inside the feed), and
	 * drain the action queue. Resolves when the connection closes cleanly;
	 * rejects on a transport or protocol error. Started once; calling again
	 * returns the same promise. */
	serve(): Promise<void> {
		if (this.#serving === null) this.#serving = this.#serveLoop();
		return this.#serving;
	}

	async #serveLoop(): Promise<void> {
		try {
			// Frames that arrived behind the handshake's tail are still buffered;
			// dispatch them before parking on the wire.
			if (this.#inbox.length > 0) await this.#feed(new Uint8Array(0));
			while (true) {
				if (this.#released) return;
				const chunk = await this.#transport.read();
				if (chunk === null) return; // clean EOF
				await this.#feed(chunk);
			}
		} catch (err) {
			// A read cancelled by our own close is a clean shutdown; any other
			// failure is a real fault a caller's `serve().catch(...)` should see.
			if (!this.closing) throw err;
		} finally {
			// The wire is gone: pending far vows can never settle, so break them
			// (classified as closure — `#closing` is set first) and release the
			// conn, freeing the fd. Idempotent with an application `close()`.
			if (!this.closing) {
				this.#closing = true;
				const msg = utf8Encoder.encode("connection closed");
				try {
					checkHost(driverS.pancake_host_conn_break_far_vows(
						this.#ptr,
						ab(msg),
						BigInt(msg.length),
					));
				} catch {
					// teardown is best-effort; release still reclaims the rows
				}
				this.closeTransport();
			}
		}
	}

	// Append freshly read bytes onto the inbox and feed the core's stream
	// delimiter: the session's codec splits each complete frame off the front —
	// both codecs, both frame shapes, the frame cap enforced during the scan —
	// and dispatches it (behavior trampolines fire and completions queue
	// inside), then the actions the dispatch queued drain. Only the unconsumed
	// tail stays in the inbox. The input buffer is borrowed for exactly one
	// call; the tail is JS-owned storage.
	async #feed(chunk: Uint8Array): Promise<void> {
		this.#appendInbox(chunk);
		// One call: the core delimits and dispatches every complete frame in
		// the buffer itself, stops at a partial tail, and during the handshake
		// stops at the frame that opens the session.
		if (this.#inbox.length === 0 || this.#released) return;
		const out = new Uint8Array(8);
		const rc = driverS.pancake_host_conn_feed_bytes(
			this.#ptr,
			ab(this.#inbox),
			BigInt(this.#inbox.length),
			ab(out),
		);
		if (rc !== OK) await this.#raiseFeedRefusal(rc);
		const consumed = Number(new DataView(out.buffer).getBigUint64(0, true));
		this.#inbox = this.#inbox.subarray(consumed);
		await this.#node.kickActions();
	}

	#appendInbox(bytes: Uint8Array): void {
		if (this.#inbox.length === 0) {
			// Copy out of the read buffer so the next read can reuse it.
			this.#inbox = bytes.slice();
			return;
		}
		const grown = new Uint8Array(this.#inbox.length + bytes.length);
		grown.set(this.#inbox, 0);
		grown.set(bytes, this.#inbox.length);
		this.#inbox = grown;
	}

	// The feed refusal choreography: capture the host's last error BEFORE the
	// abort reader can clobber it, read the typed cause, write the typed
	// op:abort the core already projected so the partner hears why, then throw.
	async #raiseFeedRefusal(rc: number): Promise<never> {
		const err = hostError(rc);
		err.abort = this.lastAbort();
		try {
			await this.flushOutbound();
		} catch {
			// the transport may already be gone; the local typed error stands
		}
		throw err;
	}

	/** The typed cause of this connection's most recent local dispatch failure,
	 * or null when none has been recorded. The flat per-feed error code names
	 * the failure family; this names the member. */
	lastAbort(): AbortDetail | null {
		if (this.#released) return null;
		const buf = new Uint8Array(LAST_ABORT_SIZE);
		const rc = driverS.pancake_host_conn_last_abort(this.#ptr, ab(buf));
		if (rc === WOULD_BLOCK) return null;
		checkHost(rc);
		const dv = new DataView(buf.buffer);
		const text = (off: number): string =>
			utf8Decoder.decode(
				readBytes(dv.getBigUint64(off, true), dv.getBigUint64(off + 8, true)),
			);
		const domainNum = dv.getUint32(LAST_ABORT_DOMAIN_OFF, true);
		return {
			domain: abortDomainLabel(domainNum),
			kind: dv.getUint32(LAST_ABORT_HAS_KIND_OFF, true) !== 0
				? text(LAST_ABORT_KIND_NAME_OFF)
				: null,
			message: text(LAST_ABORT_MESSAGE_OFF),
			errorName: text(LAST_ABORT_ERROR_NAME_OFF),
		};
	}

	/** Drain every encoded outbound frame on this connection and write it to
	 * the transport — how a FLUSH action lands. Writes are serialized, so
	 * frames stay whole and in submission order. Binding-internal. */
	async flushOutbound(): Promise<void> {
		const prior = this.#writing;
		let release!: () => void;
		this.#writing = new Promise<void>((r) => (release = r));
		try {
			await prior;
			while (true) {
				if (this.#released) return;
				const mf = new Uint8Array(MANAGED_FRAME_SIZE);
				const rc = driverS.pancake_host_conn_take_outbound(this.#ptr, ab(mf));
				if (rc === WOULD_BLOCK) return;
				checkHost(rc);
				const dv = new DataView(mf.buffer);
				const frame = readBytes(
					dv.getBigUint64(MANAGED_FRAME_BYTES_OFF, true),
					dv.getBigUint64(MANAGED_FRAME_LEN_OFF, true),
				);
				releaseManagedFrame(mf);
				await this.#transport.write(frame);
			}
		} finally {
			release();
		}
	}

	// ── Teardown ────────────────────────────────────────────────────────────────

	/** Close the connection and every exporter connection its node dialed for
	 * handoffs. A running `serve()` resolves cleanly; pending vows settle with
	 * the typed CLOSED. */
	close(): void {
		this.#closing = true;
		this.#node.closeExporters();
		this.closeTransport();
	}

	/** Close just this connection, without touching the node's other
	 * connections: stop the transport first, then retire the node's entry and
	 * free the host handle (its still-parked far vows break inside the release,
	 * classified as closure), so no foreign call touches a freed connection.
	 * Binding-internal. */
	closeTransport(): void {
		this.#closing = true;
		try {
			this.#transport.close();
		} catch {
			// already closed
		}
		if (this.#released) return;
		this.#released = true;
		this.#node.unregisterConnection(this.#ptr);
		driverS.pancake_host_conn_release(this.#ptr);
		this.#ptr = NULL;
		// The release queued FAIL completions (and sibling withdraws may have
		// failed closed): route them now.
		void this.#node.kickActions();
	}

	[Symbol.dispose](): void {
		this.close();
	}

	#guardOpen(): void {
		if (this.#released) {
			throw new PancakeError(CLOSED, "connection closed");
		}
	}

	// ── Hosting: spawn, publish, and the proxy verbs ───────────────────────────

	// Register `behavior` in the trampoline registry as an actor of this
	// connection, so a Forward whose target this side hosts composes in
	// process and a turn it runs can spawn turn-time.
	#registerActor(behavior: Behavior): bigint {
		const entry: BehaviorEntry = {
			run: behavior,
			conn: this,
			resolveLocal: (position: bigint): BehaviorEntry | undefined => {
				const id = this.#hosted.get(position);
				return id === undefined ? undefined : entryFor(id);
			},
		};
		return registerBehavior(entry);
	}

	/** Spawn a local actor and return a capability to it. The `Ref`
	 * auto-marshals when passed as a `send` argument, so handing a partner a
	 * callback is just `send(target, verb, [..., conn.spawn(behavior)])`. The
	 * position comes from the session's one export allocator, so it can never
	 * alias a bootstrap or resolver export. Callable from inside a served turn
	 * (a factory's `create` minting the task it replies with). */
	spawn(behavior: Behavior): Ref {
		this.#guardOpen();
		const ctx = this.#registerActor(behavior);
		const turn = currentTurnFor(this);
		let position: bigint;
		if (turn !== null) {
			// The turn-time spawn: the host refuses the top-level one inside a
			// behavior callback.
			position = turnSpawn(turn, ctx);
		} else {
			const out = new Uint8Array(8);
			checkHost(driverS.pancake_host_conn_spawn(
				this.#ptr,
				trampolinePointer(),
				ctx,
				NULL,
				ab(out),
			));
			position = new DataView(out.buffer).getBigUint64(0, true);
		}
		this.#hosted.set(position, ctx);
		return new Ref(near(position));
	}

	/** Publish an actor so a partner can `fetch` it by `name`. The name is a
	 * swiss-number: a readable string for a discoverable service, a
	 * cryptographic secret where the name itself is the authorization. */
	publish(name: string, behavior: Behavior): Ref {
		this.#guardOpen();
		const ctx = this.#registerActor(behavior);
		const swiss = utf8Encoder.encode(name);
		const out = new Uint8Array(8);
		checkHost(driverS.pancake_host_conn_publish(
			this.#ptr,
			ab(swiss),
			BigInt(swiss.length),
			trampolinePointer(),
			ctx,
			NULL,
			ab(out),
		));
		const position = new DataView(out.buffer).getBigUint64(0, true);
		this.#hosted.set(position, ctx);
		return new Ref(near(position));
	}

	/** Wrap `target` (local or far) in a revocable caretaker (ADR-0064).
	 * Returns the proxy capability to hand a partner and a `revoke` lever;
	 * every call through the proxy forwards to `target` until `revoke()`,
	 * after which each breaks with `Revoked`. `target` may be a capability
	 * imported over the wire — the proxy forwards transparently — so this
	 * hands out a revocable view of authority you do not own locally. */
	caretaker(target: Ref): { proxy: Ref; revoke: () => void } {
		let live = true;
		// An ordinary spawned actor whose behavior tail-forwards to the target —
		// so the proxy answers a local call exactly as a partner's delivery does.
		const proxy = this.spawn((verb, args) => {
			if (!live) throw new Error("Revoked");
			return new Forward(target, verb, args);
		});
		return {
			proxy,
			revoke: () => {
				live = false;
			},
		};
	}

	/** Wrap `target` (local or far) in an attenuator (ADR-0064): a proxy that
	 * forwards only the calls whose verb is in `verbs` and breaks every other
	 * with `Attenuated`. Returns the proxy capability to hand a partner. The
	 * proxy is a plain spawned actor. */
	attenuate(target: Ref, verbs: string[]): Ref {
		const allowed = new Set(verbs);
		return this.spawn((verb, args) => {
			if (!allowed.has(verb)) throw new Error("Attenuated");
			return new Forward(target, verb, args);
		});
	}

	// ── The application verbs ───────────────────────────────────────────────────

	/** Fetch a partner's published capability by `name`. Returns a `Ref` you
	 * can `send` to. The canonical fetch lives in the library: one call
	 * registers the bootstrap import, allocates the answer, and queues the
	 * deliver; the host enrolls the fulfilled capability under a node-unique
	 * token (ADR-0069) before the completion is queued, so a return re-gifts
	 * the right home. Drives the inbound loop itself, so a `fetch` straight
	 * after `connect` works without a separate `serve()` call. Rejects with
	 * `VowBroken` when the partner breaks the fetch, and with `FetchFailed`
	 * when it fulfills with something that is not a live capability. */
	async fetch(name: string): Promise<Ref> {
		const swiss = utf8Encoder.encode(name);
		const ref = await this.#fetchLike(swiss, name, driverS.pancake_host_conn_fetch);
		return this.#trackImport(ref);
	}

	// The one mint/await/classify body under `fetch` and `enliven`: mint the
	// host vow with `mint`, drive the inbound loop for its completion, and
	// classify the settled value — anything but a live capability rejects with
	// `FetchFailed(label)`.
	async #fetchLike(
		swiss: Uint8Array,
		label: string,
		mint: (
			conn: Ptr,
			swiss: BufferSource,
			len: bigint,
			out: BufferSource,
		) => number,
	): Promise<Ref> {
		this.#guardOpen();
		this.#drainGc();
		const out = new Uint8Array(8);
		checkHost(mint(this.#ptr, ab(swiss), BigInt(swiss.length), ab(out)));
		const vow = new DataView(out.buffer).getBigUint64(0, true);
		this.#node.vowMinted(vow, this);
		this.serve(); // the completion's bytes arrive on the inbound loop
		const settled = this.#node.awaitVow(vow);
		void this.#node.kickActions(); // the minting deliver leaves now
		const result = await settled;
		if (
			!isReference(result) ||
			(result.kind !== "near" && result.kind !== "far")
		) {
			throw new FetchFailed(label);
		}
		return new Ref(result);
	}

	/** Enliven a sturdyref against this connection (ADR-0012): bring the
	 * durable `(peer, swissnum)` to life as a live `Ref`. Parses `sturdyref`
	 * for its swissnum, then fetches it through the host's dedup cache — a
	 * repeat enliven of the same swissnum on this session short-circuits with
	 * no wire traffic (its completion is queued before the minting call
	 * returns). The connection must already be open to the sturdyref's peer;
	 * the sans-io core tracks no remote locator and never dials. Rejects with
	 * `VowBroken` when the partner breaks the enliven, and with `FetchFailed`
	 * when it fulfills with something that is not a capability. */
	enliven(sturdyref: string): Promise<Ref> {
		const swiss = utf8Encoder.encode(
			parseLocator(sturdyref, true).swissnum,
		);
		// Unlike `fetch`, the result is not GC-tracked: the host's dedup cache
		// owns an enlivened capability, outside the finalizer seam (ADR-0063).
		return this.#fetchLike(swiss, sturdyref, driverS.pancake_host_conn_enliven);
	}

	/** Eventual-send `verb(args)` to `target` and return a `RemotePromise` for
	 * the reply. `await` it for the value (a `Ref` if the partner returned a
	 * capability; rejects with `VowBroken` on a partner break).
	 *
	 * `target` is a capability `Ref` *or* a `RemotePromise` from an earlier
	 * send: passing the latter pipelines (ADR-0007) — the call is addressed at
	 * the answer that send will resolve, so a dependent chain costs one round
	 * trip instead of one per link. `args` may contain `Ref`s. A `Ref` this
	 * connection spawned runs in process; a partner's rides the wire, and a
	 * redeemed handoff token routes to the exporter connection that hosts it,
	 * transparently.
	 *
	 * The deliver is queued now; its bytes leave the wire when the returned
	 * handle — or any send pipelined behind it — is first awaited, so a
	 * pipelined batch travels together. */
	send(
		target: Ref | RemotePromise,
		verb: string,
		args: AppValue[] = [],
	): RemotePromise {
		this.#guardOpen();
		this.#drainGc();
		// A send to an object this side hosts runs its behavior in process — a
		// proxy over a *far* target then defers onto the wire reply, the same
		// forward semantics a partner's delivery gets (ADR-0064).
		if (target instanceof Ref && target.reference.kind === "near") {
			const ctx = this.#hosted.get(target.reference.id);
			if (ctx !== undefined) return this.#sendLocal(ctx, verb, args);
		}
		const verbBytes = utf8Encoder.encode(verb);
		const keep: Uint8Array[] = [];
		const argsBuf = encodeArgs(args.map(lowerArg), keep);
		const argsArg = args.length ? ab(argsBuf) : new Uint8Array(0);
		const out = new Uint8Array(8);
		if (target instanceof RemotePromise) {
			// Promise pipelining: eventual-send to the unresolved answer. A local
			// send's promise has no wire answer to pipeline against.
			if (target.vow === null) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					"cannot pipeline against a local-send promise; await it for a Ref",
				);
			}
			checkHost(driverS.pancake_host_vow_send(
				this.#node.raw,
				target.vow,
				ab(verbBytes),
				BigInt(verbBytes.length),
				argsArg,
				BigInt(args.length),
				ab(out),
			));
		} else {
			checkHost(driverS.pancake_host_conn_send(
				this.#ptr,
				ab(refStruct(target.reference)),
				ab(verbBytes),
				BigInt(verbBytes.length),
				argsArg,
				BigInt(args.length),
				ab(out),
			));
		}
		const vow = new DataView(out.buffer).getBigUint64(0, true);
		this.#node.vowMinted(vow, this);
		return this.#promiseFor(vow);
	}

	// The local arm of `send`: run the hosted behavior on first observation and
	// settle from its result. A `Forward` to another object this side hosts
	// composes in process; a `Forward` to a far target defers the answer onto
	// the forwarded send's reply (ADR-0064); a throw settles broken with the
	// behavior's own words.
	#sendLocal(ctx: bigint, verb: string, args: AppValue[]): RemotePromise {
		const begin = async (): Promise<AppValue> => {
			try {
				const hosted = runHosted(ctx, verb, args);
				// The registry never removes entries, so this arm is dead today;
				// it agrees with the wire semantics (a trampoline breaks) so the
				// two dispatch paths cannot drift apart.
				if (hosted === undefined) throw new VowBroken("no such hosted object");
				const result = hosted.result;
				if (result instanceof Forward) {
					// A far (or promise) target: the local answer settles on the
					// forwarded send's wire reply.
					return await this.send(result.target, result.verb, result.args);
				}
				return result === undefined ? null : result;
			} catch (err) {
				// A typed wire failure (the forwarded reply's break) passes through;
				// a behavior's own throw breaks with its words, as over the wire.
				if (err instanceof PancakeError) throw err;
				throw new VowBroken(err instanceof Error ? err.message : String(err));
			}
		};
		return new RemotePromise(null, begin, () => {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"cannot project a local-send promise; await it for a value",
			);
		});
	}

	// The RemotePromise over a freshly minted host vow: observation kicks the
	// drain (the flush that puts the queued batch on the wire) and awaits the
	// drain-routed completion; projections mint sibling vows at the answer.
	#promiseFor(vow: bigint): RemotePromise {
		const begin = async (): Promise<AppValue> => {
			this.serve(); // the settle's bytes arrive on the inbound loop
			const settled = this.#node.awaitVow(vow);
			void this.#node.kickActions();
			return liftArg(await settled);
		};
		const project = (op: "index" | "untag", key: string | bigint): RemotePromise => {
			const out = new Uint8Array(8);
			if (op === "index") {
				checkHost(driverS.pancake_host_vow_index(
					this.#node.raw,
					vow,
					key as bigint,
					ab(out),
				));
			} else {
				const tag = utf8Encoder.encode(key as string);
				checkHost(driverS.pancake_host_vow_untag(
					this.#node.raw,
					vow,
					ab(tag),
					BigInt(tag.length),
					ab(out),
				));
			}
			const projected = new DataView(out.buffer).getBigUint64(0, true);
			this.#node.vowMinted(projected, this);
			return this.#promiseFor(projected);
		};
		return new RemotePromise(vow, begin, project);
	}

	/** Send `verb(args)` to `target` without awaiting a reply, the
	 * fire-and-forget eventual-send (Goblins `<-np`). No answer is allocated
	 * and none comes back, so it is the right call for a notification or a
	 * broadcast: it costs one deliver, not a deliver plus a reply. Flushes
	 * immediately. */
	async tell(target: Ref, verb: string, args: AppValue[] = []): Promise<void> {
		this.#guardOpen();
		this.#drainGc();
		// A tell to an object this side hosts runs its behavior in process; the
		// result is discarded (no answer), a far forward continues as a far
		// tell, and a throw breaks nothing — there is no answer to break.
		if (target.reference.kind === "near") {
			const ctx = this.#hosted.get(target.reference.id);
			if (ctx !== undefined) {
				try {
					const result = runHosted(ctx, verb, args)?.result;
					if (result instanceof Forward) {
						return await this.tell(result.target, result.verb, result.args);
					}
				} catch {
					// no answer to break
				}
				return;
			}
		}
		const verbBytes = utf8Encoder.encode(verb);
		const keep: Uint8Array[] = [];
		const argsBuf = encodeArgs(args.map(lowerArg), keep);
		checkHost(driverS.pancake_host_conn_tell(
			this.#ptr,
			ab(refStruct(target.reference)),
			ab(verbBytes),
			BigInt(verbBytes.length),
			args.length ? ab(argsBuf) : new Uint8Array(0),
			BigInt(args.length),
		));
		await this.#node.kickActions();
	}

	/** Record the verbatim exporter-location bytes (from `encodePeerLocator`)
	 * the gifter embeds when *this* connection is the exporter side of a
	 * handoff this node originates. Needed when the partner's signed location
	 * is not dialable on its own — an iroh partner signs only its node id, so a
	 * gifter that learned the exporter's `direct-addresses` out of band sets
	 * the full locator here. Unset, origination falls back to the partner's
	 * signed location. */
	setExporterLocator(rawLocator: Uint8Array): void {
		this.#guardOpen();
		checkHost(driverS.pancake_host_conn_set_exporter_location(
			this.#ptr,
			ab(rawLocator),
			BigInt(rawLocator.length),
		));
	}

	// ── Distributed GC (ADR-0063), opt-in and off by default ───────────────────

	/** Opt this connection into distributed GC (ADR-0063), off by default. Once
	 * on, a far capability returned by {@link fetch} releases its import to the
	 * partner — a single `op:gc-exports` delta, routed through the host to the
	 * import's home connection — when the runtime reclaims the last `Ref` to
	 * it, so the partner can release the matching export. Collection is
	 * best-effort on the JS `FinalizationRegistry` schedule. Capabilities
	 * lifted elsewhere (a `send` reply, a delivered argument, an `enliven`
	 * result the dedup cache owns) are outside this seam. Returns `this` for
	 * chaining. */
	withGc(): this {
		this.#gc = true;
		return this;
	}

	// Register a fetched capability for GC when GC is on. The `Ref` holds a
	// node-unique token (ADR-0069) — only ids in the token range are tracked —
	// and the host resolves the token to its home connection and real wire
	// import when the release fires. The finalizer captures only the bare token
	// bigint, never the `Ref`, so it cannot resurrect the handle whose death it
	// waits on.
	#trackImport(ref: Ref): Ref {
		const wire = ref.reference;
		if (this.#gc && wire.kind === "far" && wire.id >= REDEEMED_TOKEN_BASE) {
			if (this.#gcRegistry === null) {
				this.#gcRegistry = new FinalizationRegistry<bigint>((token) => {
					// Park only: gc_release never runs from the finalizer callback.
					// The release rides out on the connection's next verb, or on the
					// scheduled drain below (its own event-loop task).
					this.#gcPending.push(token);
					setTimeout(() => this.#drainGc(), 0);
				});
			}
			this.#gcRegistry.register(ref, wire.id);
		}
		return ref;
	}

	// Drain the parked GC releases: one release delta per reclaimed token, then
	// a kick so the op:gc-exports flushes. Best-effort — a refused release
	// strands a partner export reclaimed at teardown, never a fault. Called at
	// the head of the connection's own verbs and as the finalizer's scheduled
	// task.
	#drainGc(): void {
		if (this.#gcPending.length === 0 || this.#released) return;
		for (const token of this.#gcPending.splice(0)) {
			try {
				checkHost(driverS.pancake_host_gc_release(this.#node.raw, token, 1n));
			} catch {
				// best-effort: a refused release strands a partner export only.
			}
		}
		void this.#node.kickActions();
	}
}

/** A listening server. Iterate it for an accepted `Connection` per partner —
 * `for await (const conn of listen(host, port)) { ... }`.
 *
 * Binding the socket is asynchronous on some runtimes, so `await
 * server.ready()` for the bound port (the value you need when you pass port 0
 * for an ephemeral one). The async iterator awaits the bind itself, so a
 * `for await` works without `ready()`; the `port` getter requires `ready()` to
 * have resolved. */
export class Server {
	#pending: Promise<NetListener>;
	#listener: NetListener | null = null;
	// One identity and one shared gift registry for the whole node: every
	// accepted connection keys its handshake with this node's seed and shares
	// its gift registry, so a gift deposited on one accepted connection is
	// withdrawable on another — the exporter-node shape a three-party handoff
	// recipient relies on (ADR-0009/ADR-0056).
	readonly #node: Node;

	constructor(pending: Promise<NetListener>, node: Node = new Node()) {
		this.#pending = pending;
		this.#node = node;
	}

	/** The server's shared node, its retained identity and gift registry. An
	 * exporter application reads it to originate gifts that recipients withdraw
	 * across the node's connections. */
	get node(): Node {
		return this.#node;
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

	async *[Symbol.asyncIterator](): AsyncGenerator<Connection> {
		const listener = await this.#pending;
		this.#listener = listener;
		// Closing the listener when iteration ends (a `break`, a `return`, or the
		// listener itself closing) frees the bound socket, so a one-client server
		// (`for await (const conn of server) { …; break; }`) leaves nothing
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
				let conn: Connection;
				try {
					conn = await Connection.accept(tcp, this.#node);
				} catch {
					continue;
				}
				yield conn;
			}
		} finally {
			listener.close();
		}
	}

	/** Stop accepting new connections. */
	close(): void {
		if (this.#listener !== null) {
			this.#listener.close();
			return;
		}
		void this.#pending.then((l) => l.close()).catch(() => {});
	}
}

/** Accept connections on `host:port`, returning a `Server` you iterate for
 * each accepted `Connection`. The bind completes asynchronously; `await
 * server.ready()` for the bound port. The server holds one node identity and
 * gift registry, read as `server.node` — a dialed sibling connection shares it
 * with `connect(locator, reachability, server.node)` for a three-party
 * handoff. `codec` picks the wire grammar for a server built on a fresh node;
 * a supplied `node` already carries one, and a conflicting explicit codec is
 * refused rather than silently ignored. */
export function listen(
	host: string,
	port: number,
	node: Node = new Node(),
	codec?: Codec,
): Server {
	if (codec !== undefined && codec !== node.codec) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`codec "${codec}" conflicts with the node's "${node.codec}"; mint the node with it instead`,
		);
	}
	const pending = net.listen(host, port).then((listener) => {
		// This node also dials (the gifter side of a handoff), and its dials sign
		// the listener's own address so a partner's crossed-hellos table can
		// recognize it.
		node.setSelfDesignator(`${host}:${listener.port}`);
		return listener;
	});
	return new Server(pending, node);
}

/** Dial a partner from its `ocapn://` locator — the one dialer, dispatching on
 * the locator's transport: `iroh` dials the endpoint id with its
 * `direct-addresses` hints, `tcp` dials the `host:port` designator. There is
 * no other dial: a literal address is a `tcp` locator, built with
 * `tcpLocator`. The binding parses the URI once and the core grammar decides
 * the netlayer.
 *
 * A `tcp` locator needs only this core module. An `iroh` locator reaches into
 * the `@pancake/iroh` package (the optional encrypted-QUIC artifact), loaded
 * lazily with `import()` so the core never hard-depends on it; `reachability`
 * (a `Reachability`) sets the iroh dialer's posture and is required only for
 * an `iroh` locator. A `tcp` locator ignores it, so a plain TCP dial needs
 * nothing but the locator. An iroh locator with no posture fails closed rather
 * than guessing one.
 *
 * `node` shares one identity and gift registry across a server and its dialed
 * sibling connections — the gifter half of a three-party handoff (read it as
 * `server.node`). Only the `tcp` branch threads it today; supplying it with an
 * `iroh` locator fails closed rather than silently dialing on a fresh
 * identity (use `connectIroh(nodeId, hints, reachability, node)` from
 * `@pancake/iroh` to key an iroh dial with a shared node). `codec` picks the
 * wire grammar for a dial on a fresh node; a supplied `node` already carries
 * one, and a conflicting explicit codec is refused. */
export async function connect(
	uri: string,
	reachability?: Reachability,
	node?: Node,
	codec?: Codec,
): Promise<Connection> {
	const loc = parseLocator(uri);
	// Fail closed on options a branch cannot honor: dropping a shared node
	// silently would dial on a different identity than `node`, so a capability
	// fetched here and re-gifted is not recognized against the shared gift
	// registry; and the codec is the node's, so a conflict is an error at the
	// call that caused it.
	if (node !== undefined && codec !== undefined && codec !== node.codec) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`codec "${codec}" conflicts with the shared node's "${node.codec}"`,
		);
	}
	switch (loc.transport) {
		case "iroh": {
			if (reachability === undefined) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					`connect: an iroh locator requires a reachability posture: ${uri}`,
				);
			}
			if (node !== undefined) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					"connect: a shared node is supported only for tcp locators today; use connectIroh from @pancake/iroh",
				);
			}
			if (codec !== undefined) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					"connect: a codec option is supported only for tcp locators today",
				);
			}
			const iroh = await import("@pancake/iroh");
			return iroh.connectIroh(
				loc.designator,
				loc.hints.get("direct-addresses") ?? "",
				reachability,
			);
		}
		case "tcp": {
			if (loc.hostPort === null) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					`tcp locator designator is not host:port: ${loc.designator}`,
				);
			}
			return Connection.connect(
				loc.hostPort.host,
				loc.hostPort.port,
				node ?? new Node(undefined, { codec }),
			);
		}
		default:
			throw new PancakeError(
				INVALID_ARGUMENT,
				`connect: unsupported transport "${loc.transport}"`,
			);
	}
}
