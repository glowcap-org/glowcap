/** Native iroh endpoint, connection, and provider-package ownership. */

import { GlowcapError, HINT_DIRECT_ADDRESSES, type Locator, Reachability, TRANSPORT_IROH } from "@glowcap/runtime";
import type { DriverLoop } from "@glowcap/runtime/transport";
import {
	ab,
	BUFFER_TOO_SMALL,
	CLOSED,
	ffi,
	INVALID_ARGUMENT,
	IROH_CONFIG_CONNECT_TIMEOUT_MS_OFF,
	IROH_CONFIG_IDLE_TIMEOUT_MS_OFF,
	IROH_CONFIG_REACHABILITY_OFF,
	IROH_CONFIG_SIZE,
	IROH_CONFIG_WORKER_THREADS_OFF,
	IROH_NODE_ID_BYTES,
	NativeDiagnostic,
	NULL,
	OK,
	outPointer,
	type Ptr,
	readErrorSlot,
	TRANSPORT_PROVIDER_SIZE,
	WOULD_BLOCK,
} from "@glowcap/runtime/ffi";
import { irohS } from "./ffi.ts";

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
// diagnostic is read here, never from the core's `glowcap_last_error`.
function irohLastError(): string | null {
	return readErrorSlot(irohS().glowcap_iroh_last_error);
}

// A failed iroh-transport call: read its diagnostic from the transport's own
// thread-local last-error and pass it explicitly, so `GlowcapError` never
// scrapes the unrelated core-family `glowcap_last_error`.
function irohCheck(code: number): void {
	if (code !== OK) {
		throw new GlowcapError(
			code,
			irohLastError() ?? `iroh transport call failed (code ${code})`,
		);
	}
}

function readUsize(buf: Uint8Array): number {
	return Number(new DataView(buf.buffer).getBigUint64(0, true));
}

function readUsizeView(view: DataView): number {
	return Number(view.getBigUint64(0, true));
}

/** One iroh endpoint's configuration, field-for-field with the header's
 * `GlowcapIrohConfig`, which documents what each setting means. An omitted
 * timeout takes the transport's default.
 *
 * `reachability` is mandatory: enabling relays or a discovery service is always
 * the caller's visible choice. `connectTimeoutMs` bounds getting a connection
 * up, `idleTimeoutMs` bounds keeping one. Set `idleTimeoutMs` if you read a
 * live session as presence, because it is what ends a connection whose peer was
 * killed rather than closed. `workerThreads` sizes this endpoint's sidecar
 * runtime; omit it for glowcap's default. */
export type IrohConfig = {
	reachability: Reachability;
	connectTimeoutMs?: number;
	idleTimeoutMs?: number;
	workerThreads?: number;
	/** Cancel generic driver listener construction before readiness. */
	signal?: AbortSignal;
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
	readonly #countOut = new Uint8Array(8);
	readonly #countView = new DataView(this.#countOut.buffer);
	readonly #connOut = new Uint8Array(8);
	readonly #releaseDiagnostic = new NativeDiagnostic("iroh");

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
			throw new GlowcapError(CLOSED, "host released while opening iroh endpoint");
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
		// than being counted here, so a field added to `GlowcapIrohConfig`
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
				throw new GlowcapError(
					INVALID_ARGUMENT,
					"iroh workerThreads must be an integer between 1 and 4294967295",
				);
			}
			view.setUint32(IROH_CONFIG_WORKER_THREADS_OFF, config.workerThreads, true);
		}
		await new NativeDiagnostic("iroh").check(
			"open endpoint",
			(error, cap, errorLen) =>
				irohS().glowcap_iroh_netlayer_new(
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
			throw new GlowcapError(CLOSED, "host released while opening iroh endpoint");
		}
		return netlayer;
	}

	/** This endpoint's id, its Ed25519 public key as lowercase hex, the dialable
	 * designator a keyed locator signs and a partner passes to `connect`. */
	nodeId(): string {
		const cap = IROH_NODE_ID_BYTES;
		const out = new Uint8Array(cap);
		const len = new Uint8Array(8);
		irohCheck(
			irohS().glowcap_iroh_netlayer_node_id(this.#raw, out, BigInt(cap), len),
		);
		return new TextDecoder().decode(out.subarray(0, readUsize(len)));
	}

	/** This endpoint's comma-separated direct socket addresses, the dialing hint
	 * a partner needs because the sidecar binds relay-less and lookup-less. Empty
	 * when the endpoint has no direct addresses yet. */
	directAddresses(): string {
		const probeLen = new Uint8Array(8);
		const probeRc = irohS().glowcap_iroh_netlayer_direct_addrs(
			this.#raw,
			null,
			0n,
			probeLen,
		);
		let cap = readUsize(probeLen);
		if (probeRc !== BUFFER_TOO_SMALL) {
			irohCheck(probeRc);
			if (cap === 0) return "";
		}
		for (;;) {
			const out = new Uint8Array(cap);
			const len = new Uint8Array(8);
			const rc = irohS().glowcap_iroh_netlayer_direct_addrs(
				this.#raw,
				out,
				BigInt(cap),
				len,
			);
			const required = readUsize(len);
			if (rc === BUFFER_TOO_SMALL && required > cap) {
				cap = required;
				continue;
			}
			irohCheck(rc);
			return new TextDecoder().decode(out.subarray(0, required));
		}
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
		const fd = irohS().glowcap_iroh_netlayer_readiness_fd(this.#raw);
		if (fd < 0) {
			throw new GlowcapError(
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
		const rc = irohS().glowcap_iroh_netlayer_drain_ready(
			this.#raw,
			ab(buf),
			BigInt(cap),
			ab(this.#countOut),
		);
		if (rc !== OK) {
			throw new GlowcapError(rc, irohLastError() ?? `iroh drain_ready failed (code ${rc})`);
		}
		return readUsizeView(this.#countView);
	}

	/** Borrow this endpoint's archive-owned provider package. */
	#transportProvider(): Uint8Array {
		const packageBytes = new Uint8Array(TRANSPORT_PROVIDER_SIZE);
		irohCheck(irohS().glowcap_iroh_transport_provider(this.#raw, ab(packageBytes)));
		return packageBytes;
	}

	/** Drop the construction reference after a driver has retained the provider.
	 * The endpoint stays live under that native lease; this wrapper becomes dead
	 * and therefore cannot outlive the driver and dereference a retired endpoint. */
	async #relinquishProviderReference(): Promise<void> {
		if (this.#raw === NULL || this.#releaseRequested || this.#children.size !== 0) {
			throw new GlowcapError(INVALID_ARGUMENT, "iroh endpoint is not transferable");
		}
		this.#releaseRequested = true;
		const raw = this.#raw;
		this.#raw = NULL;
		this.#releasePromise = this.#releaseDiagnostic.check(
			"release endpoint",
			(error, cap, errorLen) => irohS().glowcap_iroh_netlayer_release(raw, error, cap, errorLen),
		);
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
		const code = irohS().glowcap_iroh_netlayer_try_accept(this.#raw, this.#connOut);
		if (code === WOULD_BLOCK) return null;
		irohCheck(code);
		return new IrohConnection(outPointer(this.#connOut), this);
	}

	startConnect(requestId: bigint, nodeId: string, addrHints: string): void {
		const id = new TextEncoder().encode(nodeId);
		const hints = new TextEncoder().encode(addrHints);
		irohCheck(
			irohS().glowcap_iroh_netlayer_start_connect(
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
		irohCheck(
			irohS().glowcap_iroh_netlayer_finish_connect(this.#raw, requestId, this.#connOut),
		);
		return new IrohConnection(outPointer(this.#connOut), this);
	}

	cancelConnect(requestId: bigint): void {
		irohCheck(irohS().glowcap_iroh_netlayer_cancel_connect(this.#raw, requestId));
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
		this.#closePromise = Promise.resolve(irohS().glowcap_iroh_netlayer_close(raw));
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
				await this.#releaseDiagnostic.check(
					"release endpoint",
					(error, cap, errorLen) => irohS().glowcap_iroh_netlayer_release(raw, error, cap, errorLen),
				);
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
	readonly #countOut = new Uint8Array(8);
	readonly #countView = new DataView(this.#countOut.buffer);

	constructor(raw: Ptr, netlayer: IrohNetlayer) {
		this.#raw = raw;
		this.#netlayer = netlayer;
		if (!netlayer[adoptIrohConnection](this)) {
			irohS().glowcap_iroh_conn_release(raw);
			this.#raw = NULL;
			throw new Error("iroh netlayer is released");
		}
	}

	/** This connection's stable readiness identity. */
	key(): bigint {
		return irohS().glowcap_iroh_conn_id(this.#raw);
	}

	/** The far end's node id, as QUIC proved it: this connection completed
	 * only because the peer held the secret for this key. Null when the
	 * connection is gone or the handshake proved nothing.
	 *
	 * This is the fact a session is otherwise missing. glowcap cannot see it —
	 * it did not open this connection — so whoever did passes it on with
	 * `Session.bindVerifiedChannelKey`, which `_connectIroh`
	 * below do for every session this module establishes. */
	remoteNodeId(): string | null {
		const cap = IROH_NODE_ID_BYTES;
		const out = new Uint8Array(cap);
		const len = new Uint8Array(8);
		const rc = irohS().glowcap_iroh_conn_remote_node_id(
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
		const rc = irohS().glowcap_iroh_conn_try_read(
			this.#raw,
			ab(buf),
			BigInt(buf.length),
			ab(this.#countOut),
		);
		if (rc === WOULD_BLOCK || rc === CLOSED) return rc;
		if (rc !== OK) {
			throw new GlowcapError(
				rc,
				irohLastError() ?? `iroh conn try_read failed (code ${rc})`,
			);
		}
		return readUsizeView(this.#countView);
	}

	/** Non-blocking write of `buf`'s raw bytes: the count written (possibly a
	 * prefix), or `WOULD_BLOCK` when the outbound buffer has no room. Throws on a
	 * fault. */
	tryWrite(buf: Uint8Array): number {
		const rc = irohS().glowcap_iroh_conn_try_write(
			this.#raw,
			ab(buf),
			BigInt(buf.length),
			ab(this.#countOut),
		);
		if (rc === WOULD_BLOCK) return rc;
		if (rc !== OK) {
			throw new GlowcapError(
				rc,
				irohLastError() ?? `iroh conn try_write failed (code ${rc})`,
			);
		}
		return readUsizeView(this.#countView);
	}

	release(): void {
		if (this.#raw === NULL) return;
		const raw = this.#raw;
		this.#raw = NULL;
		try {
			irohS().glowcap_iroh_conn_release(raw);
		} finally {
			this.#netlayer[forgetIrohConnection](this);
		}
	}

	[Symbol.dispose](): void {
		this.release();
	}
}
