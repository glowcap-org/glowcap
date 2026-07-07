// Idiomatic JavaScript/TypeScript API for libpancake_net_transport_iroh — pancake's optional
// encrypted-QUIC (iroh) transport, the `@pancake/iroh` package: a composable
// companion to the core `@pancake/stack` package.
//
// The split mirrors the archives: `@pancake/stack` rides `libpancake_ocapn` (the
// pure-Zig codec-neutral CapTP core) and this package rides
// `libpancake_net_transport_iroh` (a *companion* library that links a Rust iroh sidecar,
// ADR-0055; it exports only the `pancake_iroh_*` family and shares no core
// symbol, so it loads alongside `libpancake_ocapn`, not instead of it). A consumer
// that never speaks iroh installs only `@pancake/stack`; one
// that hosts or explicitly dials over iroh adds this package. The transport-neutral
// dialer `connect` (in the core) bridges them: it reaches in here with a lazy
// `import("@pancake/iroh")` only when it parses an `iroh` locator, so the core never
// hard-depends on the iroh artifact.
//
//   const server = listenIroh(Reachability.Direct);
//   console.log(server.uri);              // hand this to a partner
//   for await (const conn of server) conn.serve();
//
// The frame unit is identical to TCP's — one codec-self-delimited CapTP message
// — so the same `AsyncConnection` pump drives a peer over it; only the addressing
// differs (an endpoint id + direct-address hints, no host:port). The sidecar's
// loop surface (ADR-0057) is the netlayer's one I/O model: `IrohLoop` parks the
// event loop on the endpoint's single readiness fd (a `node:net` socket over a
// dup of it) and drains the readiness records when it signals, so one loop serves
// many connections with no per-connection task.

import { Socket } from "node:net";
import {
	AsyncConnection,
	Connection,
	formatPeerUri,
	type FramePump,
	type KeyedLocator,
	Node,
	openKeyedSession,
	PancakeError,
	Peer,
	Reachability,
} from "@pancake/stack";

// The `Reachability` posture type is owned by the core `@pancake/stack` (so its
// `connect` and `Node` name it without depending on this optional package); the
// iroh package re-exports it as the transport that gives it meaning.
export { Reachability } from "@pancake/stack";
import {
	ab,
	CLOSED,
	ffi,
	INVALID_ARGUMENT,
	IROH_EV_ACCEPT,
	IROH_EV_CLOSED,
	IROH_EV_READABLE,
	IROH_EV_WRITABLE,
	IROH_READY_EVENT_SIZE,
	NULL,
	OK,
	outPointer,
	type Ptr,
	type Symbols,
	WOULD_BLOCK,
} from "@pancake/stack/ffi";
import { irohS } from "./ffi.ts";

// As the core's `check`, but for iroh ABI calls: the iroh library carries its
// own thread-local last-error, so pass an explicit detail rather than scraping
// libpancake_ocapn's unrelated one.
function irohCheck(code: number): void {
	if (code !== OK) {
		throw new PancakeError(code, `iroh transport call failed (code ${code})`);
	}
}

function readUsize(buf: Uint8Array): number {
	return Number(new DataView(buf.buffer).getBigUint64(0, true));
}

// Mirrors the core's read chunk; raw inbound bytes are framed by the peer above.
const READ_CHUNK = 64 * 1024;

/** A bound iroh QUIC endpoint plus the sidecar runtime driving it, the iroh
 * sibling of the TCP `Netlayer`, but it is also its own listener (there is no
 * host:port to bind, so accepting lives here, on the readiness loop). Dial a
 * partner by endpoint id + direct-address hints. Release every `IrohConn` it
 * mints before releasing it. */
export class IrohNetlayer {
	#raw: Ptr;

	/** Bind an endpoint. `reachability` is required, the caller owns the
	 * reach/privacy posture, with no default. `secretSeed` is a 32-byte
	 * Ed25519 secret key for a stable id, or omitted for a fresh random key. */
	constructor(reachability: Reachability, secretSeed?: Uint8Array) {
		if (secretSeed !== undefined && secretSeed.length !== 32) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"an iroh secret seed must be 32 bytes",
			);
		}
		const seed = secretSeed ?? new Uint8Array(0);
		const out = new Uint8Array(8);
		irohCheck(
			irohS().pancake_iroh_netlayer_new(
				ab(seed),
				BigInt(seed.length),
				reachability,
				out,
			),
		);
		this.#raw = outPointer(out);
	}

	/** This endpoint's id, its Ed25519 public key as lowercase hex, the dialable
	 * designator a keyed locator signs and a partner passes to `connect`. */
	nodeId(): string {
		const cap = 64;
		const out = new Uint8Array(cap);
		const len = new Uint8Array(8);
		irohCheck(
			irohS().pancake_iroh_netlayer_node_id(this.#raw, out, BigInt(cap), len),
		);
		return new TextDecoder().decode(out.subarray(0, readUsize(len)));
	}

	/** This endpoint's comma-separated direct socket addresses, the dialing hint
	 * a partner needs because the sidecar binds relay-less and lookup-less. Empty
	 * when the endpoint has no direct addresses yet. */
	directAddresses(): string {
		const cap = 1024;
		const out = new Uint8Array(cap);
		const len = new Uint8Array(8);
		irohCheck(
			irohS().pancake_iroh_netlayer_direct_addrs(
				this.#raw,
				out,
				BigInt(cap),
				len,
			),
		);
		return new TextDecoder().decode(out.subarray(0, readUsize(len)));
	}

	// ── The event-driven loop surface (ADR-0057) ───────────────────────────────
	// These back `IrohLoop`: the endpoint's one I/O model, serving many connections
	// from one readiness fd the event loop parks on. The loop is armed when the
	// netlayer is created, so these work immediately. The host (here `IrohLoop`)
	// frames the raw bytes `IrohConn.tryReadInto` hands out, the same way the TCP
	// pump frames its socket bytes.

	/** This endpoint's single readiness fd, park on it (a `node:net` socket over
	 * a dup of it) and call `drainReady` when it signals. Owned by the netlayer;
	 * never close it. */
	readinessFd(): number {
		const fd = irohS().pancake_iroh_netlayer_readiness_fd(this.#raw);
		if (fd < 0) {
			throw new PancakeError(fd, `iroh readiness_fd failed (code ${fd})`);
		}
		return fd;
	}

	/** Drain the pending readiness records into `buf` (`cap` entries) without
	 * blocking. Returns the record count (0 when none); throws on fault. Call it
	 * when `readinessFd` signals, then again until it returns fewer than `cap`. */
	drainReady(buf: Uint8Array, cap: number): number {
		const n = irohS().pancake_iroh_netlayer_drain_ready(
			this.#raw,
			ab(buf),
			BigInt(cap),
		);
		if (n < 0) throw new PancakeError(n, `iroh drain_ready failed (code ${n})`);
		return n;
	}

	/** Claim one accepted non-blocking connection, or null when none is pending. */
	tryAccept(): IrohConn | null {
		const out = new Uint8Array(8);
		const code = irohS().pancake_iroh_netlayer_try_accept(this.#raw, out);
		if (code === WOULD_BLOCK) return null;
		irohCheck(code);
		return new IrohConn(outPointer(out));
	}

	/** Dial a partner and return a non-blocking loop connection. The dial itself
	 * blocks (non-blocking FFI); subsequent frame I/O is non-blocking. */
	async tryConnect(nodeId: string, addrHints: string): Promise<IrohConn> {
		const id = new TextEncoder().encode(nodeId);
		const hints = new TextEncoder().encode(addrHints);
		const out = new Uint8Array(8);
		irohCheck(
			await irohS().pancake_iroh_netlayer_try_connect(
				this.#raw,
				ab(id),
				BigInt(id.length),
				ab(hints),
				BigInt(hints.length),
				out,
			),
		);
		return new IrohConn(outPointer(out));
	}

	/** Close the endpoint without freeing the handle: later dials fail and the
	 * readiness loop winds down. Idempotent, the shutdown lever for a server or
	 * dialer. */
	close(): void {
		if (this.#raw !== NULL) irohS().pancake_iroh_netlayer_close(this.#raw);
	}

	release(): void {
		if (this.#raw !== NULL) {
			irohS().pancake_iroh_netlayer_release(this.#raw);
			this.#raw = NULL;
		}
	}

	[Symbol.dispose](): void {
		this.release();
	}
}

/** One iroh QUIC connection carrying one OCapN session, the iroh sibling of the
 * TCP `Endpoint`. Driven by an `IrohLoop`: the raw bytes `tryReadInto` hands out
 * are framed above, and no call ever parks on the connection. */
export class IrohConn {
	#raw: Ptr;
	constructor(raw: Ptr) {
		this.#raw = raw;
	}

	/** This connection's routing key — its raw handle as a bigint, the value a
	 * `drain_ready` record carries — so `IrohLoop` can map a readiness record back
	 * to this connection. */
	key(): bigint {
		return this.#raw;
	}

	/** Non-blocking read of raw inbound bytes into `buf`: the byte count (>0),
	 * `WOULD_BLOCK` when nothing is buffered yet, `CLOSED` on a clean end of
	 * stream, or throws on a fault. The caller frames these bytes itself. */
	tryReadInto(buf: Uint8Array): number {
		const n = irohS().pancake_iroh_conn_try_read(
			this.#raw,
			ab(buf),
			BigInt(buf.length),
		);
		if (n === WOULD_BLOCK || n === CLOSED) return n;
		if (n < 0) {
			throw new PancakeError(n, `iroh conn try_read failed (code ${n})`);
		}
		return n;
	}

	/** Non-blocking write of `buf`'s raw bytes: the count written (the whole
	 * slice), or `WOULD_BLOCK` when the outbound buffer is at its bound (retry the
	 * same bytes after the next writable record). Throws on a fault. */
	tryWrite(buf: Uint8Array): number {
		const n = irohS().pancake_iroh_conn_try_write(
			this.#raw,
			ab(buf),
			BigInt(buf.length),
		);
		if (n === WOULD_BLOCK) return n;
		if (n < 0) {
			throw new PancakeError(n, `iroh conn try_write failed (code ${n})`);
		}
		return n;
	}

	release(): void {
		if (this.#raw !== NULL) {
			irohS().pancake_iroh_conn_release(this.#raw);
			this.#raw = NULL;
		}
	}

	[Symbol.dispose](): void {
		this.release();
	}
}

// ── The iroh readiness dispatcher (ADR-0057) ─────────────────────────────────

// How many readiness records one `drain_ready` call pulls. When the fd signals,
// the loop drains in a batch and re-drains until a short count, so a queue
// deeper than the cap is never stranded.
const DRAIN_READY_CAP = 64;

// `dup(2)` from libc, opened lazily. The readiness fd is owned by the netlayer;
// the loop's `node:net` socket owns and closes *its own* dup on teardown, so the
// netlayer's fd is never closed out from under it.
let libc: Symbols | null = null;
function dupFd(fd: number): number {
	if (libc === null) {
		const name = ffi.libSuffix() === "dylib" ? "libSystem.B.dylib" : "libc.so.6";
		libc = ffi.dlopen(name, { dup: { parameters: ["i32"], result: "i32" } });
	}
	const d = libc.dup(fd);
	if (d < 0) throw new Error("dup of the iroh readiness fd failed");
	return d;
}

/** Per-connection readiness state. A loop connection is single-owner (one task
 * drives it), so at most one task waits for readable and one for writable; a
 * `*Pending` flag holds an edge that arrived before its waiter so no wakeup is
 * lost. */
interface ConnWaiters {
	conn: IrohConn;
	readable: (() => void) | null;
	writable: (() => void) | null;
	readablePending: boolean;
	writablePending: boolean;
	closed: boolean;
}

/** The per-netlayer readiness dispatcher for the iroh loop surface (ADR-0057).
 *
 * It parks the event loop on the netlayer's single readiness fd — a `node:net`
 * socket over a dup of it — and, when the fd signals, drains the pending records
 * and fans each out to the connection (or accept) waiting on it. The drain
 * touches only the endpoint, never a per-connection buffer, so a connection can
 * be released at any time without racing a read. `close` destroys the socket
 * (closing its dup) and wakes every waiter, so the caller can then free the
 * netlayer with no callback still touching it. The Deno sibling of the Python
 * binding's `_IrohLoop` and the Zig resident's `LoopHost`. */
class IrohLoop {
	#netlayer: IrohNetlayer;
	#conns = new Map<bigint, ConnWaiters>();
	#acceptWaiter: (() => void) | null = null;
	#acceptPending = 0;
	#closed = false;
	#socket: Socket | null = null;
	// Reused across `drain_ready` calls; held by the dispatcher so it stays live
	// for the duration of the FFI call that borrows it.
	#buf = new Uint8Array(DRAIN_READY_CAP * IROH_READY_EVENT_SIZE);

	constructor(netlayer: IrohNetlayer) {
		this.#netlayer = netlayer;
	}

	/** Register the readiness fd with the event loop (idempotent). */
	start(): void {
		if (this.#socket !== null || this.#closed) return;
		const dup = dupFd(this.#netlayer.readinessFd());
		// A read-only socket over the dup: 'data' fires whenever the sidecar posts a
		// wakeup byte, which is our cue to drain the record queue.
		this.#socket = new Socket({ fd: dup, readable: true, writable: false });
		this.#socket.on("data", () => this.#onReady());
		this.#socket.on("error", () => this.#shutdownSocket()); // endpoint faulted
		// Drain anything already queued before the first wakeup.
		this.#onReady();
	}

	register(conn: IrohConn): void {
		this.#conns.set(conn.key(), {
			conn,
			readable: null,
			writable: null,
			readablePending: false,
			writablePending: false,
			closed: false,
		});
	}

	unregister(conn: IrohConn): void {
		const w = this.#conns.get(conn.key());
		if (w !== undefined) this.#wakeClosed(w);
		this.#conns.delete(conn.key());
	}

	/** Resolve true when this connection is readable; false if it closed. */
	waitReadable(conn: IrohConn): Promise<boolean> {
		const w = this.#conns.get(conn.key());
		if (w === undefined || w.closed) return Promise.resolve(false);
		if (w.readablePending) {
			w.readablePending = false;
			return Promise.resolve(true);
		}
		return new Promise<boolean>((res) => {
			w.readable = () => res(!w.closed);
		});
	}

	/** Resolve true when this connection is writable; false if it closed. */
	waitWritable(conn: IrohConn): Promise<boolean> {
		const w = this.#conns.get(conn.key());
		if (w === undefined || w.closed) return Promise.resolve(false);
		if (w.writablePending) {
			w.writablePending = false;
			return Promise.resolve(true);
		}
		return new Promise<boolean>((res) => {
			w.writable = () => res(!w.closed);
		});
	}

	/** Resolve true when an accepted connection may be claimed; false on close. */
	nextAccept(): Promise<boolean> {
		if (this.#closed) return Promise.resolve(false);
		if (this.#acceptPending > 0) {
			this.#acceptPending--;
			return Promise.resolve(true);
		}
		return new Promise<boolean>((res) => {
			this.#acceptWaiter = () => res(!this.#closed);
		});
	}

	/** Stop the loop (destroying its readiness socket, closing the dup), wake every
	 * waiter so parked pumps unwind, and release the sidecar handle of every
	 * connection still registered here. The caller releases the netlayer after this
	 * returns — and the C ABI requires every connection released before its
	 * netlayer (`destroyConn` dereferences the netlayer). A dialing pump
	 * unregisters and releases its one connection before it calls this, so the
	 * release below is a no-op for it; a server's shared loop still holds every
	 * accepted connection that no per-connection close reached, so releasing them
	 * here — while the netlayer is still alive — is what keeps the server's
	 * `netlayer.release()` from freeing memory those connections still point at.
	 * Each connection's own `close` is idempotent with this. */
	close(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.#shutdownSocket();
		for (const w of this.#conns.values()) {
			this.#wakeClosed(w);
			w.conn.release();
		}
		this.#conns.clear();
		if (this.#acceptWaiter !== null) {
			const a = this.#acceptWaiter;
			this.#acceptWaiter = null;
			a();
		}
	}

	#shutdownSocket(): void {
		if (this.#socket !== null) {
			this.#socket.destroy();
			this.#socket = null;
		}
	}

	#wakeClosed(w: ConnWaiters): void {
		w.closed = true;
		if (w.readable !== null) {
			const r = w.readable;
			w.readable = null;
			r();
		}
		if (w.writable !== null) {
			const r = w.writable;
			w.writable = null;
			r();
		}
	}

	// The event loop calls this whenever the readiness socket has data. Drain the
	// queue in batches until a short count (a deeper queue than one drain holds is
	// never stranded), dispatching each record. A fault means the endpoint was
	// closed under us, stop watching the fd.
	#onReady(): void {
		if (this.#closed) return;
		const dv = new DataView(this.#buf.buffer);
		for (;;) {
			let n: number;
			try {
				n = this.#netlayer.drainReady(this.#buf, DRAIN_READY_CAP);
			} catch {
				this.#shutdownSocket();
				return;
			}
			for (let i = 0; i < n; i++) {
				const off = i * IROH_READY_EVENT_SIZE;
				this.#dispatch(dv.getBigUint64(off, true), dv.getUint32(off + 8, true));
			}
			if (n < DRAIN_READY_CAP) return;
		}
	}

	#dispatch(connPtr: bigint, events: number): void {
		if ((events & IROH_EV_ACCEPT) !== 0) {
			if (this.#acceptWaiter !== null) {
				const a = this.#acceptWaiter;
				this.#acceptWaiter = null;
				a();
			} else {
				this.#acceptPending++;
			}
			return;
		}
		const w = this.#conns.get(connPtr);
		if (w === undefined) return; // a record for an already-released connection
		if ((events & IROH_EV_CLOSED) !== 0) w.closed = true;
		if ((events & (IROH_EV_READABLE | IROH_EV_CLOSED)) !== 0) {
			if (w.readable !== null) {
				const r = w.readable;
				w.readable = null;
				r();
			} else {
				w.readablePending = true;
			}
		}
		if ((events & (IROH_EV_WRITABLE | IROH_EV_CLOSED)) !== 0) {
			if (w.writable !== null) {
				const r = w.writable;
				w.writable = null;
				r();
			} else {
				w.writablePending = true;
			}
		}
	}
}

/** The iroh pump: a non-blocking `IrohConn` driven by an `IrohLoop` (ADR-0057).
 * It sources raw inbound bytes through the sidecar's non-blocking `try_read`,
 * buffers them, and lets the peer frame them — exactly like the core's `TcpPump`,
 * since the frame unit is identical; the readiness loop, not a parked blocking
 * read, decides when bytes are available. Outbound frames go through the
 * non-blocking `try_write`, re-arming on the next writable record if the sidecar
 * buffer is full. The keyed locator signs the `iroh` transport with the local
 * endpoint id as designator (empty for a dialer, matching the Zig driver).
 *
 * Lifetime: a server-accepted pump borrows the server's loop and netlayer; a
 * dialing pump minted its own netlayer and loop (`ownsLoop`) and tears both down
 * on close. No call ever parks on this connection, so `close` cannot race a
 * parked read — the teardown hazard the blocking pump had. */
class IrohPump implements FramePump {
	#conn: IrohConn;
	#designator: string;
	#loop: IrohLoop;
	#ownsLoop: boolean;
	#ownedNetlayer: IrohNetlayer | null;
	// Inbound bytes read from the wire but not yet framed into whole frames.
	#inbox: Uint8Array = new Uint8Array(0);
	#readBuf = new Uint8Array(READ_CHUNK);

	constructor(
		conn: IrohConn,
		designator: string,
		loop: IrohLoop,
		ownedNetlayer: IrohNetlayer | null = null,
		ownsLoop = false,
	) {
		this.#conn = conn;
		this.#designator = designator;
		this.#loop = loop;
		this.#ownsLoop = ownsLoop;
		this.#ownedNetlayer = ownedNetlayer;
	}

	locator(): KeyedLocator {
		return {
			transport: "iroh",
			designator: this.#designator,
			hintsEmptyFalse: true,
		};
	}

	dispatchBuffered(peer: Peer): boolean {
		if (this.#inbox.length === 0) return false;
		const consumed = peer.recvStream(this.#inbox);
		if (consumed === null) return false;
		this.#inbox = this.#inbox.subarray(consumed);
		return true;
	}

	async receive(_peer: Peer): Promise<boolean> {
		for (;;) {
			// Drain every byte currently available (the readiness signal is edge-ish,
			// so leaving bytes buffered in the sidecar could stall until fresh data),
			// then frame them above.
			let got = false;
			for (;;) {
				const n = this.#conn.tryReadInto(this.#readBuf);
				if (n === WOULD_BLOCK) break;
				if (n === CLOSED) return got; // drained, then a clean end of stream
				this.#appendInbox(this.#readBuf.subarray(0, n));
				got = true;
			}
			if (got) return true;
			// Nothing buffered yet: park on this connection's readiness, not a wire
			// read. A false here means the connection was released/closed under us.
			if (!(await this.#loop.waitReadable(this.#conn))) return false;
		}
	}

	async writeFrame(frame: Uint8Array): Promise<void> {
		for (;;) {
			const n = this.#conn.tryWrite(frame);
			if (n !== WOULD_BLOCK) return; // the whole frame went (all-or-nothing)
			if (!(await this.#loop.waitWritable(this.#conn))) {
				throw new Error("iroh connection closed while writing");
			}
		}
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

	close(): void {
		// Drop the routing entry first so no further readiness record resolves a
		// waiter on this connection, then free the sidecar connection.
		this.#loop.unregister(this.#conn);
		this.#conn.release();
		if (this.#ownsLoop) {
			// The dialing pump owns the loop and netlayer: stop the loop (destroying
			// its readiness socket) before releasing the netlayer, so no callback is
			// still touching the endpoint when it is freed.
			this.#loop.close();
			this.#ownedNetlayer?.release();
		}
	}
}

// iroh discovery resolves a peer by node id alone, but the exporter's pkarr
// record takes seconds to propagate after it binds, so a dial-by-id can fail with
// "no addressing information" until it lands. Every posture that resolves by id
// through a propagating service — `Discovery` (n0 relays + DNS/pkarr) and
// `DiscoveryNoRelay` (DNS/pkarr, no relay) — therefore retries the dial on a
// bounded budget; `Direct` dials once (its addresses are in hand) and
// `LocalDiscovery` dials once (its in-process address book resolves instantly).
// The C ABI flattens a not-yet-resolvable dial to the same code as a hard
// failure, so a genuinely unreachable peer simply exhausts the budget rather than
// failing fast. Mirrors the Zig `iroh-reachability` driver's settle/retry shape.
const DISCOVERY_DIAL_RETRY_MS = 3_000;
const DISCOVERY_DIAL_MAX_ATTEMPTS = 24; // ~72s, covers pkarr propagation

/** Whether a posture resolves the partner by id through a propagating discovery
 * service, so a dial-by-id should settle/retry while the record lands. */
function settlesWhileResolving(reachability: Reachability): boolean {
	return (
		reachability === Reachability.Discovery ||
		reachability === Reachability.DiscoveryNoRelay
	);
}

/** Dial, retrying only under a propagating-discovery posture while it resolves. */
async function dialResolving(
	netlayer: IrohNetlayer,
	nodeId: string,
	directAddresses: string,
	reachability: Reachability,
): Promise<IrohConn> {
	if (!settlesWhileResolving(reachability)) {
		return netlayer.tryConnect(nodeId, directAddresses);
	}
	for (let attempt = 1;; attempt += 1) {
		try {
			return await netlayer.tryConnect(nodeId, directAddresses);
		} catch (e) {
			if (attempt >= DISCOVERY_DIAL_MAX_ATTEMPTS) throw e;
			await new Promise<void>((r) => setTimeout(r, DISCOVERY_DIAL_RETRY_MS));
		}
	}
}

/** Dial an iroh partner and complete the keyed OCapN handshake over the
 * encrypted-QUIC transport, returning a ready `Connection` — the iroh sibling of
 * the core's `connect`. The local endpoint is ephemeral (a fresh key) and
 * released with the connection. `reachability` is required — the caller owns the
 * dialer's reach posture, with no default — and it decides how the partner is
 * reached: `Direct` dials the `directAddresses` hints with no discovery; the
 * discovery postures (`Discovery` via n0 relays + DNS/pkarr, `DiscoveryNoRelay`
 * via DNS/pkarr) resolve `nodeId` by itself, ignoring hints, and retry while that
 * resolution propagates. This is what the core's
 * `connect` calls for an `iroh` locator. Needs the iroh ABI library
 * (`zig build iroh-abi`). */
export async function connectIroh(
	nodeId: string,
	directAddresses: string,
	reachability: Reachability,
	node: Node = new Node(),
): Promise<Connection> {
	const netlayer = new IrohNetlayer(reachability);
	const loop = new IrohLoop(netlayer);
	let conn: IrohConn;
	try {
		conn = await dialResolving(netlayer, nodeId, directAddresses, reachability);
	} catch (e) {
		loop.close();
		netlayer.release();
		throw e;
	}
	loop.register(conn);
	loop.start();
	// A dialer signs an empty designator (its identity is the session key),
	// matching the Zig driver; the pump owns the ephemeral netlayer and loop. The
	// peer is node-owned (ADR-0066): registering the connection with the node's
	// node returns its `connId` and the peer to pump, so the session's public key
	// (a give's `recipient_key`) and the node's identity/gift registry agree —
	// what a three-party handoff requires (ADR-0009/ADR-0056).
	const { connId, peer } = node.registerConn();
	// The pump owns the dialer-minted connection, loop, and ephemeral netlayer
	// (`ownsLoop`); on a handshake failure its `close` is what unregisters and
	// releases the connection, stops the readiness loop (closing the dup'd fd),
	// and releases the netlayer. The node-owned peer is freed by `removeConn`, so
	// closing the pump and removing the connection frees every acquired resource,
	// the same symmetry the tcp dialer keeps.
	const pump = new IrohPump(conn, "", loop, netlayer, true);
	try {
		const ac = AsyncConnection.fromPump(peer, pump);
		await openKeyedSession(ac, node.seed);
		return Connection.fromAsync(ac, node, connId);
	} catch (e) {
		pump.close();
		node.removeConn(connId);
		throw e;
	}
}

/** Complete the responder handshake over an accepted iroh connection, signing
 * the server's endpoint id as the locator designator (used by `IrohServer`). The
 * accepted connection's loop and netlayer belong to the server, not this
 * connection. */
async function acceptIroh(
	conn: IrohConn,
	localNodeId: string,
	loop: IrohLoop,
	node: Node = new Node(),
): Promise<Connection> {
	// As `connectIroh`: the peer is node-owned (ADR-0066), so a node's accepted
	// connections share one identity and gift registry, what lets an exporter
	// match a gift's deposit (on the gifter session) and withdraw (on the recipient
	// session).
	const { connId, peer } = node.registerConn();
	try {
		const ac = AsyncConnection.fromPump(
			peer,
			new IrohPump(conn, localNodeId, loop),
		);
		await openKeyedSession(ac, node.seed);
		return Connection.fromAsync(ac, node, connId);
	} catch (e) {
		node.removeConn(connId);
		throw e;
	}
}

/** A listening iroh endpoint. Iterate it for an accepted `Connection` per
 * partner — `for await (const conn of listenIroh()) { ... }` — and read `uri`
 * for the dialable address (endpoint id + direct-address hints) to hand a
 * client. The iroh sibling of the core's `Server`. */
export class IrohServer {
	#netlayer: IrohNetlayer;
	#loop: IrohLoop;
	#closed = false;
	#nodeId: string;
	// One identity and one shared gift registry for the whole node: every accepted
	// connection keys its handshake with this node's seed and binds its peer to
	// this node's gift registry, so a gift deposited on one accepted connection
	// is withdrawable on another — the exporter-node shape a three-party handoff
	// recipient relies on (ADR-0009/ADR-0056). The TCP `Server`'s iroh sibling.
	readonly #node: Node;

	constructor(netlayer: IrohNetlayer, node: Node = new Node()) {
		this.#netlayer = netlayer;
		this.#nodeId = netlayer.nodeId();
		this.#node = node;
		// Serve every accepted connection from one readiness loop instead of a
		// blocking accept and a blocking read parked per connection (ADR-0057).
		this.#loop = new IrohLoop(netlayer);
	}

	/** This endpoint's id, the keyed locator designator and the URI host. */
	get nodeId(): string {
		return this.#nodeId;
	}

	/** The server's shared node, its retained identity and gift registry. An
	 * exporter application reads it to originate gifts that recipients withdraw
	 * across the node's connections; the TCP `Server.node` sibling. */
	get node(): Node {
		return this.#node;
	}

	/** This endpoint's comma-separated direct-address hints. */
	get directAddresses(): string {
		return this.#netlayer.directAddresses();
	}

	/** The `ocapn://<nodeid>.iroh?direct-addresses=…` URI a partner dials. */
	get uri(): string {
		const hints = new Map<string, string>();
		if (this.directAddresses.length > 0) {
			hints.set("direct-addresses", this.directAddresses);
		}
		return formatPeerUri("iroh", this.#nodeId, hints);
	}

	async *[Symbol.asyncIterator](): AsyncGenerator<Connection> {
		this.#loop.start();
		while (!this.#closed) {
			// Wait for an accept record, then claim every connection now pending — a
			// single wake may cover several near-simultaneous dials.
			if (!(await this.#loop.nextAccept())) return;
			for (;;) {
				const conn = this.#netlayer.tryAccept();
				if (conn === null) break; // nothing more pending right now
				this.#loop.register(conn);
				// A handshake failure belongs to that one connection (a partner that
				// dialed and died), never the server — release it and keep accepting.
				let connection: Connection;
				try {
					connection = await acceptIroh(
						conn,
						this.#nodeId,
						this.#loop,
						this.#node,
					);
				} catch {
					this.#loop.unregister(conn);
					conn.release();
					continue;
				}
				yield connection;
			}
		}
	}

	/** Stop accepting and release the endpoint. Closes the endpoint, then stops the
	 * readiness loop — which releases every accepted connection still borrowing
	 * this netlayer — and only then frees the netlayer, so no connection the C ABI
	 * would route through it outlives it. */
	close(): void {
		if (this.#closed) return;
		this.#closed = true;
		this.#netlayer.close();
		this.#loop.close();
		this.#netlayer.release();
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.close();
	}
}

/** Bind an iroh endpoint and return an `IrohServer` you iterate for each
 * accepted `Connection`. `reachability` is required, the caller owns the reach
 * posture, with no default. `secretSeed` is a 32-byte Ed25519 secret key
 * for a stable endpoint id, or omitted for a fresh random one. Needs the iroh
 * ABI library (`zig build iroh-abi`). */
export function listenIroh(
	reachability: Reachability,
	secretSeed?: Uint8Array,
	node?: Node,
): IrohServer {
	return new IrohServer(new IrohNetlayer(reachability, secretSeed), node);
}
