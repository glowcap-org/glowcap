/** Runtime-owned readiness and byte-channel projection for iroh. */

import { Socket } from "node:net";
import { type Channel, PancakeError, Reachability } from "@pancake/runtime";
import {
	CLOSED,
	ffi,
	IO,
	IROH_EV_ACCEPT,
	IROH_EV_CLOSED,
	IROH_EV_CONNECT,
	IROH_EV_READABLE,
	IROH_EV_WRITABLE,
	IROH_READY_EVENT_SIZE,
	type Symbols,
	WOULD_BLOCK,
} from "@pancake/runtime/ffi";
import { DISCOVERY_DIAL_MAX_ATTEMPTS, DISCOVERY_DIAL_RETRY_MS } from "@pancake/abi";
import { IrohConnection, IrohNetlayer } from "./native.ts";

// Mirrors the core's read chunk; the Host stream delimiter frames these bytes.
const READ_CHUNK = 64 * 1024;

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
export class IrohLoop {
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
export class IrohChannel implements Channel {
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
export async function dialResolving(
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
