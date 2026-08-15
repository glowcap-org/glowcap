// Idiomatic JavaScript/TypeScript API for libpancake_net_transport_iroh — pancake's optional
// encrypted-QUIC (iroh) transport, the `@pancake/iroh` package: a composable
// companion to the core `@pancake/runtime` package.
//
// The split mirrors the archives: `@pancake/runtime` rides `libpancake_ocapn` (the
// pure-Zig codec-neutral CapTP core) and this package rides
// `libpancake_net_transport_iroh` (a *companion* library that links a Rust iroh sidecar,
// ADR-0055; it exports only the `pancake_iroh_*` family and shares no core
// symbol, so it loads alongside `libpancake_ocapn`, not instead of it). A consumer
// that never speaks iroh installs only `@pancake/runtime`; one
// that hosts or explicitly dials over iroh adds this package. The transport-neutral
// dialer `connect` (in the core) bridges them: it reaches in here with a lazy
// `import("@pancake/iroh/internal")` only when it parses an `iroh` locator, so the
// core never hard-depends on the iroh artifact. Application code never imports
// that internal dial — it uses `connect(locator, { reachability, host })`.
//
//   const server = await listen({ reachability: Reachability.Direct });
//   console.log(server.uri);              // hand this to a partner
//   for await (const session of server) session.serve();
//
// The byte unit is identical to TCP's — the core's stream delimiter owns
// framing — so the same byte-fed `Session` serve loop drives a session over
// it; only the addressing differs (an endpoint id + direct-address hints, no
// host:port). The native listener and high-level dial paths use the generic
// driver archive's provider ABI. `IrohLoop` remains for explicit byte-channel
// helpers such as relay bridging.

import { Socket } from "node:net";
import {
	bareLocator,
	type Channel,
	Connector,
	HANDSHAKE_TIMEOUT_MS,
	HINT_DIRECT_ADDRESSES,
	Host,
	type Locator,
	PancakeError,
	parseLocator,
	Reachability,
	Session,
	stringHint,
	TRANSPORT_IROH,
} from "@pancake/runtime";
import { DriverListener, DriverLoop, DriverServer, retainCleanupFailures } from "@pancake/runtime/transport";

// The `Reachability` posture type is owned by the core `@pancake/runtime` (so its
// `connect` and `Host` name it without depending on this optional package); the
// iroh package re-exports it as the transport that gives it meaning.
export { Reachability } from "@pancake/runtime";
import {
	ab,
	CLOSED,
	ffi,
	INVALID_ARGUMENT,
	IO,
	IROH_CONFIG_CONNECT_TIMEOUT_MS_OFF,
	IROH_CONFIG_IDLE_TIMEOUT_MS_OFF,
	IROH_CONFIG_REACHABILITY_OFF,
	IROH_CONFIG_SIZE,
	IROH_CONFIG_WORKER_THREADS_OFF,
	IROH_EV_ACCEPT,
	IROH_EV_CLOSED,
	IROH_EV_CONNECT,
	IROH_EV_READABLE,
	IROH_EV_WRITABLE,
	IROH_READY_EVENT_SIZE,
	NativeDiagnostic,
	NULL,
	OK,
	outPointer,
	type Ptr,
	readErrorSlot,
	type Symbols,
	TRANSPORT_PROVIDER_SIZE,
	WOULD_BLOCK,
} from "@pancake/runtime/ffi";
import { DISCOVERY_DIAL_MAX_ATTEMPTS, DISCOVERY_DIAL_RETRY_MS } from "@pancake/abi";
import { irohS } from "./ffi.ts";

/** Build an iroh locator. Direct addresses are optional because discovery
 * resolves a bare node id; direct-only deployments publish the hint. */
export function locator(nodeId: string, directAddresses?: string): Locator {
	return {
		transport: TRANSPORT_IROH,
		designator: nodeId,
		hints: directAddresses == null ? new Map() : new Map([[HINT_DIRECT_ADDRESSES, directAddresses]]),
		hintWireForm: directAddresses == null ? "boolean-false" : "map",
	};
}

// The calling thread's last error from the iroh transport, or null when there
// is none. The transport keeps its own thread-local slot, so an iroh call's
// diagnostic is read here, never from the core's `pancake_last_error`.
function irohLastError(): string | null {
	return readErrorSlot(irohS().pancake_iroh_last_error);
}

// A failed iroh-transport call: read its diagnostic from the transport's own
// thread-local last-error and pass it explicitly, so `PancakeError` never
// scrapes the unrelated core-family `pancake_last_error`.
function irohCheck(code: number): void {
	if (code !== OK) {
		throw new PancakeError(
			code,
			irohLastError() ?? `iroh transport call failed (code ${code})`,
		);
	}
}

function readUsize(buf: Uint8Array): number {
	return Number(new DataView(buf.buffer).getBigUint64(0, true));
}

// Mirrors the core's read chunk; raw inbound bytes are framed by the host's
// stream delimiter above.
const READ_CHUNK = 64 * 1024;

/** One iroh endpoint's configuration, field-for-field with the header's
 * `PancakeIrohConfig`, which documents what each setting means. An omitted
 * timeout takes the transport's default.
 *
 * `reachability` is mandatory: enabling relays or a discovery service is always
 * the caller's visible choice. `connectTimeoutMs` bounds getting a connection
 * up, `idleTimeoutMs` bounds keeping one. Set `idleTimeoutMs` if you read a
 * live session as presence, because it is what ends a connection whose peer was
 * killed rather than closed. `workerThreads` sizes this endpoint's sidecar
 * runtime; omit it for pancake's default. */
export type IrohConfig = {
	reachability: Reachability;
	connectTimeoutMs?: number;
	idleTimeoutMs?: number;
	workerThreads?: number;
	/** Cancel generic driver listener construction before readiness. */
	signal?: AbortSignal;
};

export type ListenOptions =
	| {
		/** Reuse this 32-byte identity seed across restarts. */
		readonly seed?: Uint8Array;
		readonly host?: never;
	}
	| {
		/** Share an existing Host and its session directory. */
		readonly host: Host;
		readonly seed?: never;
	};

const adoptIrohConnection = Symbol("adoptIrohConnection");
const forgetIrohConnection = Symbol("forgetIrohConnection");

/** A bound iroh QUIC endpoint plus the sidecar runtime driving it, the iroh
 * sibling of the TCP `Netlayer`, but it is also its own listener (there is no
 * host:port to bind, so accepting lives here, on the readiness loop). Dial a
 * partner by endpoint id + direct-address hints. It owns every `IrohConnection` it
 * mints and releases remaining children before its native endpoint. */
export class IrohNetlayer {
	#raw: Ptr;
	#closePromise: Promise<void> | null = null;
	#releasePromise: Promise<void> | null = null;
	#children = new Set<IrohConnection>();
	#releaseRequested = false;

	/** Bind an endpoint. `config` carries the endpoint's settings, mandatory
	 * because `reachability` is (see `IrohConfig`). `secretSeed` is a 32-byte
	 * Ed25519 secret key for a stable id, or omitted for a fresh random key. */
	private constructor(raw: Ptr) {
		this.#raw = raw;
	}

	static async open(
		config: IrohConfig,
		secretSeed?: Uint8Array,
		signal?: AbortSignal,
	): Promise<IrohNetlayer> {
		if (signal?.aborted) {
			throw new PancakeError(CLOSED, "host released while opening iroh endpoint");
		}
		if (!ffi.offloadsBlockingCalls()) {
			throw new Error("iroh requires a runtime that offloads blocking FFI lifecycle calls");
		}
		// Construction runs off-thread and the sidecar borrows this pointer until
		// that call returns. Take ownership before dispatch so caller mutation cannot
		// change the endpoint identity while native code is reading it.
		const seed = secretSeed?.slice() ?? new Uint8Array(0);
		const out = new Uint8Array(8);
		// The size and every offset come from the generated layout mirror rather
		// than being counted here, so a field added to `PancakeIrohConfig`
		// cannot leave this buffer short of what the transport reads.
		// Zero-initialized, so an unset field stays 0 and means the built-in
		// default, which is the header's zero-init contract.
		const raw = new Uint8Array(IROH_CONFIG_SIZE);
		const view = new DataView(raw.buffer);
		view.setUint32(IROH_CONFIG_REACHABILITY_OFF, config.reachability, true);
		if (config.connectTimeoutMs != null) {
			view.setBigUint64(
				IROH_CONFIG_CONNECT_TIMEOUT_MS_OFF,
				BigInt(config.connectTimeoutMs),
				true,
			);
		}
		if (config.idleTimeoutMs != null) {
			view.setBigUint64(
				IROH_CONFIG_IDLE_TIMEOUT_MS_OFF,
				BigInt(config.idleTimeoutMs),
				true,
			);
		}
		if (config.workerThreads != null) {
			if (
				!Number.isInteger(config.workerThreads) ||
				config.workerThreads <= 0 ||
				config.workerThreads > 0xffffffff
			) {
				throw new PancakeError(
					INVALID_ARGUMENT,
					"iroh workerThreads must be an integer between 1 and 4294967295",
				);
			}
			view.setUint32(IROH_CONFIG_WORKER_THREADS_OFF, config.workerThreads, true);
		}
		await new NativeDiagnostic("iroh").check(
			"open endpoint",
			(error, cap, errorLen) =>
				irohS().pancake_iroh_netlayer_new_with_diagnostic(
					ab(seed),
					BigInt(seed.length),
					ab(raw),
					out,
					error,
					cap,
					errorLen,
				),
		);
		const netlayer = new IrohNetlayer(outPointer(out));
		if (signal?.aborted) {
			await netlayer.release();
			throw new PancakeError(CLOSED, "host released while opening iroh endpoint");
		}
		return netlayer;
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
	// frames the raw bytes `IrohConnection.tryReadInto` hands out, the same way the TCP
	// pump frames its socket bytes.

	/** This endpoint's single readiness fd, park on it (a `node:net` socket over
	 * a dup of it) and call `drainReady` when it signals. Owned by the netlayer;
	 * never close it. */
	readinessFd(): number {
		const fd = irohS().pancake_iroh_netlayer_readiness_fd(this.#raw);
		if (fd < 0) {
			throw new PancakeError(
				fd,
				irohLastError() ?? `iroh readiness_fd failed (code ${fd})`,
			);
		}
		return fd;
	}

	/** Drain the pending readiness records into `buf` (`cap` entries) without
	 * blocking. Returns the record count (0 when none); throws on fault. Call it
	 * when `readinessFd` signals, then again until it returns fewer than `cap`. */
	drainReady(buf: Uint8Array, cap: number): number {
		const out = new Uint8Array(8);
		const rc = irohS().pancake_iroh_netlayer_drain_ready(
			this.#raw,
			ab(buf),
			BigInt(cap),
			ab(out),
		);
		if (rc !== OK) {
			throw new PancakeError(rc, irohLastError() ?? `iroh drain_ready failed (code ${rc})`);
		}
		return Number(new DataView(out.buffer).getBigUint64(0, true));
	}

	/** Borrow this endpoint's archive-owned provider package. */
	#transportProvider(): Uint8Array {
		const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
		irohCheck(irohS().pancake_iroh_transport_provider(this.#raw, ab(packageBytes)));
		return packageBytes;
	}

	/** Drop the construction reference after a driver has retained the provider.
	 * The endpoint stays live under that native lease; this wrapper becomes dead
	 * and therefore cannot outlive the driver and dereference a retired endpoint. */
	async #relinquishProviderReference(): Promise<void> {
		if (this.#raw === NULL || this.#releaseRequested || this.#children.size !== 0) {
			throw new PancakeError(INVALID_ARGUMENT, "iroh endpoint is not transferable");
		}
		this.#releaseRequested = true;
		const raw = this.#raw;
		this.#raw = NULL;
		this.#releasePromise = Promise.resolve(irohS().pancake_iroh_netlayer_release(raw)).then(irohCheck);
		await this.#releasePromise;
	}

	/** Register this endpoint while its construction reference is live, then
	 * transfer callback lifetime to the driver's retained provider lease. */
	async installProvider(loop: DriverLoop): Promise<void> {
		const packageBytes = this.#transportProvider();
		loop.installProvider((register) => register(packageBytes));
		await this.#relinquishProviderReference();
	}

	/** Claim one accepted non-blocking connection, or null when none is pending. */
	tryAccept(): IrohConnection | null {
		const out = new Uint8Array(8);
		const code = irohS().pancake_iroh_netlayer_try_accept(this.#raw, out);
		if (code === WOULD_BLOCK) return null;
		irohCheck(code);
		return new IrohConnection(outPointer(out), this);
	}

	startConnect(requestId: bigint, nodeId: string, addrHints: string): void {
		const id = new TextEncoder().encode(nodeId);
		const hints = new TextEncoder().encode(addrHints);
		irohCheck(
			irohS().pancake_iroh_netlayer_start_connect(
				this.#raw,
				requestId,
				ab(id),
				BigInt(id.length),
				ab(hints),
				BigInt(hints.length),
			),
		);
	}

	finishConnect(requestId: bigint): IrohConnection {
		const out = new Uint8Array(8);
		irohCheck(
			irohS().pancake_iroh_netlayer_finish_connect(this.#raw, requestId, out),
		);
		return new IrohConnection(outPointer(out), this);
	}

	cancelConnect(requestId: bigint): void {
		irohCheck(irohS().pancake_iroh_netlayer_cancel_connect(this.#raw, requestId));
	}

	/** Close the endpoint without freeing the handle: later dials fail and the
	 * readiness loop winds down. Idempotent, the shutdown lever for a server or
	 * dialer. */
	close(): Promise<void> {
		if (this.#closePromise != null) return this.#closePromise;
		if (this.#raw === NULL) return Promise.resolve();
		this.#releaseRequested = true;
		for (const child of [...this.#children]) child.release();
		const raw = this.#raw;
		this.#closePromise = Promise.resolve(irohS().pancake_iroh_netlayer_close(raw));
		return this.#closePromise;
	}

	release(): Promise<void> {
		if (this.#releasePromise != null) return this.#releasePromise;
		if (this.#raw === NULL) return Promise.resolve();
		this.#releaseRequested = true;
		for (const child of [...this.#children]) child.release();
		const raw = this.#raw;
		const close = this.close();
		this.#raw = NULL;
		this.#releasePromise = (async () => {
			try {
				await close;
			} finally {
				irohCheck(await irohS().pancake_iroh_netlayer_release(raw));
			}
		})();
		return this.#releasePromise;
	}

	[adoptIrohConnection](conn: IrohConnection): boolean {
		if (this.#releaseRequested) return false;
		this.#children.add(conn);
		return true;
	}

	[forgetIrohConnection](conn: IrohConnection): void {
		this.#children.delete(conn);
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.release();
	}
}

/** One iroh QUIC connection carrying one OCapN session, the iroh sibling of the
 * TCP `Connection`. Driven by an `IrohLoop`: the raw bytes `tryReadInto` hands out
 * are framed above, and no call ever parks on the connection. */
export class IrohConnection {
	#raw: Ptr;
	readonly #netlayer: IrohNetlayer;
	constructor(raw: Ptr, netlayer: IrohNetlayer) {
		this.#raw = raw;
		this.#netlayer = netlayer;
		if (!netlayer[adoptIrohConnection](this)) {
			irohS().pancake_iroh_conn_release(raw);
			this.#raw = NULL;
			throw new Error("iroh netlayer is released");
		}
	}

	/** This connection's stable readiness identity. */
	key(): bigint {
		return irohS().pancake_iroh_conn_id(this.#raw);
	}

	/** The far end's node id, as QUIC proved it: this connection completed
	 * only because the peer held the secret for this key. Null when the
	 * connection is gone or the handshake proved nothing.
	 *
	 * This is the fact a session is otherwise missing. pancake cannot see it —
	 * it did not open this connection — so whoever did passes it on with
	 * `Session.bindVerifiedChannelKey`, which `_connectIroh`
	 * below do for every session this module establishes. */
	remoteNodeId(): string | null {
		const cap = 64;
		const out = new Uint8Array(cap);
		const len = new Uint8Array(8);
		const rc = irohS().pancake_iroh_conn_remote_node_id(
			this.#raw,
			ab(out),
			BigInt(cap),
			ab(len),
		);
		if (rc !== OK) return null;
		return new TextDecoder().decode(out.subarray(0, readUsize(len)));
	}

	/** Non-blocking read of raw inbound bytes into `buf`: the byte count (>0),
	 * `WOULD_BLOCK` when nothing is buffered yet, `CLOSED` on a clean end of
	 * stream, or throws on a fault. The caller frames these bytes itself. */
	tryReadInto(buf: Uint8Array): number {
		const out = new Uint8Array(8);
		const rc = irohS().pancake_iroh_conn_try_read(
			this.#raw,
			ab(buf),
			BigInt(buf.length),
			ab(out),
		);
		if (rc === WOULD_BLOCK || rc === CLOSED) return rc;
		if (rc !== OK) {
			throw new PancakeError(
				rc,
				irohLastError() ?? `iroh conn try_read failed (code ${rc})`,
			);
		}
		return Number(new DataView(out.buffer).getBigUint64(0, true));
	}

	/** Non-blocking write of `buf`'s raw bytes: the count written (possibly a
	 * prefix), or `WOULD_BLOCK` when the outbound buffer has no room. Throws on a
	 * fault. */
	tryWrite(buf: Uint8Array): number {
		const out = new Uint8Array(8);
		const rc = irohS().pancake_iroh_conn_try_write(
			this.#raw,
			ab(buf),
			BigInt(buf.length),
			ab(out),
		);
		if (rc === WOULD_BLOCK) return rc;
		if (rc !== OK) {
			throw new PancakeError(
				rc,
				irohLastError() ?? `iroh conn try_write failed (code ${rc})`,
			);
		}
		return Number(new DataView(out.buffer).getBigUint64(0, true));
	}

	release(): void {
		if (this.#raw === NULL) return;
		const raw = this.#raw;
		this.#raw = NULL;
		try {
			irohS().pancake_iroh_conn_release(raw);
		} finally {
			this.#netlayer[forgetIrohConnection](this);
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
	conn: IrohConnection;
	readable: (() => void) | null;
	writable: (() => void) | null;
	readablePending: boolean;
	writablePending: boolean;
	closed: boolean;
}

interface DialWaiter {
	resolve: (conn: IrohConnection) => void;
	reject: (error: unknown) => void;
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
 * binding's `_IrohLoop` and Zig's `completion.Loop(iroh.Backend)` +
 * `driver.Bridge` + `driver_core.Host`. */
class IrohLoop {
	#netlayer: IrohNetlayer;
	#conns = new Map<bigint, ConnWaiters>();
	#dials = new Map<bigint, DialWaiter>();
	#nextRequest = 1n;
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
		this.#socket.on("error", () => this.close()); // endpoint faulted
		// Drain anything already queued before the first wakeup.
		this.#onReady();
	}

	register(conn: IrohConnection): void {
		this.#conns.set(conn.key(), {
			conn,
			readable: null,
			writable: null,
			readablePending: false,
			writablePending: false,
			closed: false,
		});
	}

	dial(nodeId: string, addrHints: string): Promise<IrohConnection> {
		const requestId = this.#nextRequest++;
		return new Promise<IrohConnection>((resolve, reject) => {
			this.#dials.set(requestId, { resolve, reject });
			try {
				this.#netlayer.startConnect(requestId, nodeId, addrHints);
			} catch (error) {
				this.#dials.delete(requestId);
				reject(error);
			}
		});
	}

	unregister(conn: IrohConnection): void {
		const w = this.#conns.get(conn.key());
		if (w != null) this.#wakeClosed(w);
		this.#conns.delete(conn.key());
	}

	/** Resolve true when this connection is readable; false if it closed. */
	waitReadable(conn: IrohConnection): Promise<boolean> {
		const w = this.#conns.get(conn.key());
		if (w == null || w.closed) return Promise.resolve(false);
		if (w.readablePending) {
			w.readablePending = false;
			return Promise.resolve(true);
		}
		return new Promise<boolean>((res) => {
			w.readable = () => res(!w.closed);
		});
	}

	/** Resolve true when this connection is writable; false if it closed. */
	waitWritable(conn: IrohConnection): Promise<boolean> {
		const w = this.#conns.get(conn.key());
		if (w == null || w.closed) return Promise.resolve(false);
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
		for (const [requestId, waiter] of this.#dials) {
			try {
				this.#netlayer.cancelConnect(requestId);
			} catch {
				// Endpoint shutdown owns the terminal row.
			}
			waiter.reject(new PancakeError(CLOSED, "iroh loop closed"));
		}
		this.#dials.clear();
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
		while (true) {
			let n: number;
			try {
				n = this.#netlayer.drainReady(this.#buf, DRAIN_READY_CAP);
			} catch {
				this.close();
				return;
			}
			for (let i = 0; i < n; i++) {
				const off = i * IROH_READY_EVENT_SIZE;
				this.#dispatch(dv.getBigUint64(off, true), dv.getUint32(off + 8, true));
			}
			if (n < DRAIN_READY_CAP) return;
		}
	}

	#dispatch(subject: bigint, events: number): void {
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
		if ((events & IROH_EV_CONNECT) !== 0) {
			const waiter = this.#dials.get(subject);
			this.#dials.delete(subject);
			try {
				const conn = this.#netlayer.finishConnect(subject);
				if (waiter == null) conn.release();
				else waiter.resolve(conn);
			} catch (error) {
				waiter?.reject(error);
			}
			return;
		}
		const w = this.#conns.get(subject);
		if (w == null) return; // a record for an already-released connection
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

/** The iroh transport: a non-blocking `IrohConnection` driven by an `IrohLoop`
 * (ADR-0057), reshaped into the byte transport a `Session`'s serve loop
 * reads. `read` sources raw inbound bytes through the sidecar's non-blocking
 * `try_read` — the readiness loop, not a parked blocking read, decides when
 * bytes are available — and the host's stream delimiter frames them above.
 * `write` goes through the non-blocking `try_write`, re-arming on the next
 * writable record when the sidecar buffer is full (the serve loop's FLUSH
 * drain serializes the writes, so the retry never interleaves frames).
 *
 * Lifetime: a server-accepted transport borrows the server's loop and
 * netlayer; a dialing transport minted its own netlayer and loop (`ownsLoop`)
 * and tears both down on close. No call ever parks on this connection, so
 * `close` cannot race a parked read — the teardown hazard a blocking pump
 * would have. */
class IrohChannel implements Channel {
	#conn: IrohConnection;
	#loop: IrohLoop;
	#ownsLoop: boolean;
	#ownedNetlayer: IrohNetlayer | null;
	#readBuf = new Uint8Array(READ_CHUNK);
	#closePromise: Promise<void> | null = null;

	constructor(
		conn: IrohConnection,
		loop: IrohLoop,
		ownedNetlayer: IrohNetlayer | null = null,
		ownsLoop = false,
	) {
		this.#conn = conn;
		this.#loop = loop;
		this.#ownsLoop = ownsLoop;
		this.#ownedNetlayer = ownedNetlayer;
	}

	async read(): Promise<Uint8Array | null> {
		while (true) {
			// Drain every byte currently available (the readiness signal is
			// edge-ish, so leaving bytes buffered in the sidecar could stall until
			// fresh data); the chunks are copied out so the read buffer can be
			// reused by the next read.
			const chunks: Uint8Array[] = [];
			while (true) {
				const n = this.#conn.tryReadInto(this.#readBuf);
				if (n === WOULD_BLOCK) break;
				if (n === CLOSED) {
					// Drained, then a clean end of stream: hand back what arrived
					// first; the next read reports the close.
					return chunks.length > 0 ? join(chunks) : null;
				}
				chunks.push(this.#readBuf.slice(0, n));
			}
			if (chunks.length > 0) return join(chunks);
			// Nothing buffered yet: park on this connection's readiness, not a
			// wire read. A false here means it was released/closed under us.
			if (!(await this.#loop.waitReadable(this.#conn))) return null;
		}
	}

	async write(data: Uint8Array): Promise<void> {
		let offset = 0;
		while (offset < data.length) {
			const n = this.#conn.tryWrite(data.subarray(offset));
			if (n !== WOULD_BLOCK) {
				offset += n;
				continue;
			}
			if (!(await this.#loop.waitWritable(this.#conn))) {
				throw new Error("iroh connection closed while writing");
			}
		}
	}

	close(): Promise<void> {
		if (this.#closePromise != null) return this.#closePromise;
		// Drop the routing entry first so no further readiness record resolves a
		// waiter on this connection, then free the sidecar connection.
		this.#loop.unregister(this.#conn);
		this.#conn.release();
		if (this.#ownsLoop) {
			// The dialing transport owns the loop and netlayer: stop the loop
			// (destroying its readiness socket) before releasing the netlayer, so
			// no callback is still touching the endpoint when it is freed.
			this.#loop.close();
			this.#closePromise = this.#ownedNetlayer?.release() ?? Promise.resolve();
		} else {
			this.#closePromise = Promise.resolve();
		}
		return this.#closePromise;
	}
}

function join(chunks: Uint8Array[]): Uint8Array {
	if (chunks.length === 1) return chunks[0];
	let total = 0;
	for (const c of chunks) total += c.length;
	const grown = new Uint8Array(total);
	let off = 0;
	for (const c of chunks) {
		grown.set(c, off);
		off += c.length;
	}
	return grown;
}

// iroh discovery resolves a peer by node id alone, but the exporter's pkarr
// record takes seconds to propagate after it binds, so a dial-by-id can fail with
// "no addressing information" until it lands. Every posture that resolves by id
// through a propagating service — `Discovery` (n0 relays + DNS/pkarr) and
// `DiscoveryNoRelay` (DNS/pkarr, no relay) — therefore retries on the
// `PANCAKE_DISCOVERY_DIAL_*` budget (ADR-0082). `Direct` and `LocalDiscovery`
// dial once. Only transient dial faults (projected as IO) are retried.
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
	loop: IrohLoop,
	nodeId: string,
	directAddresses: string,
	reachability: Reachability,
): Promise<IrohConnection> {
	if (!settlesWhileResolving(reachability)) {
		return loop.dial(nodeId, directAddresses);
	}
	for (let attempt = 1;; attempt += 1) {
		try {
			return await loop.dial(nodeId, directAddresses);
		} catch (e) {
			// ADR-0082: only transient dial faults (iroh projects them as IO).
			// InvalidAddress / ConnectionRefused / OOM map to non-IO codes.
			if (!(e instanceof PancakeError) || e.code !== IO) throw e;
			if (attempt >= DISCOVERY_DIAL_MAX_ATTEMPTS) throw e;
			await new Promise<void>((r) => setTimeout(r, DISCOVERY_DIAL_RETRY_MS));
		}
	}
}

/** Attach this package's resident through the generic provider seam. The
 * provider decides configuration equivalence; the driver owns occupancy. */
export async function _ensureIrohProvider(
	loop: DriverLoop,
	config: IrohConfig,
): Promise<{ readonly nodeId: string }> {
	const retainedConfig = { ...config };
	const netlayer = await IrohNetlayer.open(
		retainedConfig,
		loop.wrapperHost().seed,
		config.signal,
	);
	try {
		const nodeId = netlayer.nodeId();
		await netlayer.installProvider(loop);
		return { nodeId };
	} catch (error) {
		await netlayer.release();
		throw error;
	}
}

/** Configure an iroh endpoint package for `connect`. Reachability is provider
 * configuration because it controls endpoint services established at open. */
export function provider(config: IrohConfig): import("@pancake/runtime").DriverProvider {
	return {
		async install(loop) {
			await _ensureIrohProvider(loop, config);
		},
	};
}

/** Configure an explicit byte-fed iroh connector. Native applications should
 * normally prefer `provider`; this form is for embedders that deliberately own
 * the channel pump. */
export function connector(config: IrohConfig): Connector {
	return new Connector([TRANSPORT_IROH], async (host, loc, request) => {
		const directAddresses = stringHint(loc, HINT_DIRECT_ADDRESSES) ?? "";
		const reachability = request.redeem && directAddresses.length > 0 ? Reachability.Direct : config.reachability;
		const signals = [config.signal, request.signal].filter(
			(value): value is AbortSignal => value != null,
		);
		const signal = signals.length > 1 ? AbortSignal.any(signals) : signals[0];
		return await _connectIroh(
			loc.designator,
			directAddresses,
			reachability,
			host,
			request.handshakeTimeoutMs,
			signal,
		);
	});
}

/** Binding-internal iroh dial behind the core's `connect(locator)`. Application
 * code dials through `connect(locator, { reachability, host })` only. The local
 * endpoint is ephemeral and released with the connection. `reachability` is
 * required. Needs the iroh ABI library (`zig build iroh-abi`).
 *
 * `handshakeTimeoutMs` bounds the OCapN handshake only. The dial-by-id budget
 * above it (a `Discovery` posture retries while the exporter's pkarr record
 * propagates, ADR-0082) is already spent by the time the channel exists, so a
 * slow discovery never eats the handshake's bound. */
export async function _connectIroh(
	nodeId: string,
	directAddresses: string,
	reachability: Reachability,
	host: Host = new Host(),
	handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS,
	signal?: AbortSignal,
): Promise<Session> {
	if (signal?.aborted) throw new PancakeError(CLOSED, "host released while dialing");
	const netlayer = await IrohNetlayer.open({ reachability }, undefined, signal);
	if (signal?.aborted) {
		await netlayer.release();
		throw new PancakeError(CLOSED, "host released while dialing");
	}
	const loop = new IrohLoop(netlayer);
	loop.start();
	let cancellation: Promise<void> | null = null;
	const cancelPending = (): void => {
		loop.close();
		cancellation ??= netlayer.release();
	};
	signal?.addEventListener("abort", cancelPending, { once: true });
	let conn: IrohConnection;
	try {
		conn = await dialResolving(loop, nodeId, directAddresses, reachability);
	} catch (e) {
		signal?.removeEventListener("abort", cancelPending);
		loop.close();
		await (cancellation ?? netlayer.release());
		throw e;
	}
	if (signal?.aborted) {
		signal.removeEventListener("abort", cancelPending);
		loop.close();
		await (cancellation ?? netlayer.release());
		throw new PancakeError(CLOSED, "host released while dialing");
	}
	loop.register(conn);
	signal?.removeEventListener("abort", cancelPending);
	// The transport owns the dialer-minted connection, loop, and ephemeral
	// netlayer (`ownsLoop`); on a handshake failure or an elapsed handshake
	// bound `establishDialedLocator` abandons
	// the half-built connection, and its transport close is what unregisters
	// and releases the sidecar connection, stops the readiness loop (closing
	// the dup'd fd), and releases the netlayer. The connection is minted
	// against `host`, so the session's identity (a give's `recipient_key`) and
	// the host's live-session directory agrees — what a three-party handoff requires
	// (ADR-0009/ADR-0056).
	const transport = new IrohChannel(conn, loop, netlayer, true);
	const cancelTransport = (): void => {
		void transport.close().catch((error) => host.recordCallerlessBindingFailure("iroh.abort.cleanup", error));
	};
	if (signal?.aborted) {
		cancelTransport();
		throw new PancakeError(CLOSED, "host released while dialing");
	}
	signal?.addEventListener("abort", cancelTransport, { once: true });
	// This module opened the connection, so it is the one place that can say
	// what QUIC proved about the far end. Passing it here is what makes the
	// session report `authenticated-transport` instead of resting on whatever
	// the partner claims about itself.
	try {
		return await Session.establishDialedLocator(
			host,
			bareLocator(TRANSPORT_IROH, nodeId),
			transport,
			handshakeTimeoutMs,
			conn.remoteNodeId(),
		);
	} finally {
		signal?.removeEventListener("abort", cancelTransport);
	}
}

/** Dial an iroh locator and return a byte channel for relay/bridge use.
 * Unlike `_connectIroh`, this returns just the channel, not a Session.
 * The channel owns the loop and netlayer; calling `close()` cleans up
 * both and terminates the connection. For transparent relay endpoints
 * (e.g., browser peer → relay → native iroh). */
export async function dialLocatorForRelay(
	locator: string,
	reachability: Reachability = Reachability.Discovery,
): Promise<Channel> {
	const parsed = parseLocator(locator);
	if (parsed.transport !== TRANSPORT_IROH) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			`expected iroh locator, got transport: ${parsed.transport}`,
		);
	}

	const nodeId = parsed.designator;
	const directAddresses = stringHint(parsed, HINT_DIRECT_ADDRESSES) ?? "";

	const netlayer = await IrohNetlayer.open({ reachability });
	const loop = new IrohLoop(netlayer);
	loop.start();
	let conn: IrohConnection;
	try {
		conn = await dialResolving(loop, nodeId, directAddresses, reachability);
	} catch (e) {
		loop.close();
		await netlayer.release();
		throw e;
	}
	loop.register(conn);

	// Return a channel that owns the connection, loop, and netlayer.
	// Calling close() terminates the connection and cleans up the loop/netlayer.
	const irohChannel = new IrohChannel(conn, loop, netlayer, true);
	return {
		read: () => irohChannel.read(),
		write: (data: Uint8Array) => irohChannel.write(data),
		close: () => irohChannel.close(),
	};
}

/** The iroh view over the binding's generic driver listener owner. The
 * resident owns endpoint I/O and this class projects only iroh metadata. */
export class IrohServer extends DriverServer {
	readonly #nodeId: string;

	constructor(listener: DriverListener, nodeId: string, ownedLoop?: DriverLoop) {
		super({ listener, ownedLoop });
		this.#nodeId = nodeId;
	}

	get nodeId(): string {
		return this.#nodeId;
	}

	get directAddresses(): string {
		return stringHint(this.locator, HINT_DIRECT_ADDRESSES) ?? "";
	}
}

/** Bind an iroh endpoint and return an `IrohServer` you iterate for each
 * accepted `Session`. `config` carries the endpoint's settings and is mandatory
 * because `reachability` is (see `IrohConfig`). `secretSeed` is a 32-byte
 * Ed25519 secret key for a stable endpoint id, or omitted for a fresh random
 * one shared with the `Host`. Pass `host` only when it was built from the same
 * seed — one identity for netlayer and session (ADR-0075). The no-Host path
 * registers the endpoint with the generic native loop. A supplied Host is
 * transferred to that loop transactionally. Needs the iroh ABI library
 * (`zig build iroh-abi`).
 *
 * A server that treats a live session as presence should set
 * `config.idleTimeoutMs`, because that is what ends a connection whose peer was
 * killed rather than closed and so lets `serve()` settle. */
export async function listen(
	config: IrohConfig,
	options: ListenOptions = {},
): Promise<IrohServer> {
	const { seed: suppliedSeed, host } = options;
	const seed = suppliedSeed ?? host?.seed ?? crypto.getRandomValues(new Uint8Array(32));
	if (suppliedSeed != null && suppliedSeed.length !== 32) {
		throw new PancakeError(INVALID_ARGUMENT, "listen: seed must be 32 bytes");
	}
	if (suppliedSeed != null && host != null) {
		throw new PancakeError(
			INVALID_ARGUMENT,
			"listen: seed and host are alternative identity sources",
		);
	}
	const existingLoop = host?.driverLoop;
	const loop = existingLoop == null
		? host == null ? DriverLoop.open({ seed }) : DriverLoop.takeHost(host)
		: existingLoop as DriverLoop;
	let listener: DriverListener | null = null;
	try {
		const endpoint = await _ensureIrohProvider(loop, config);
		const endpointNodeId = endpoint.nodeId;
		listener = await DriverListener.open(
			loop,
			TRANSPORT_IROH,
			endpointNodeId,
			config.signal,
		);
		listener.select();
		const server = new IrohServer(
			listener,
			endpointNodeId,
			host == null ? loop : undefined,
		);
		listener = null;
		return server;
	} catch (error) {
		const cleanups: Array<() => void | Promise<void>> = [];
		const failedListener = listener;
		if (failedListener != null) cleanups.push(() => failedListener.close());
		if (host == null) cleanups.push(() => loop.close());
		await retainCleanupFailures(error, cleanups);
		throw error;
	}
}
