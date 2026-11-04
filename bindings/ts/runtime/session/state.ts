// One state owner for the public Session. The pump, writer, vow waits, and
// hosting operations borrow this object directly; no per-operation adapters.

import { CLOSED, HANDSHAKE_TIMEOUT_MS, HOST_OUTBOUND_PREFIX_CAP, INVALID_ARGUMENT, OK, TIMEOUT } from "@glowcap/abi";
import { type AbortDetail, checkHost, GlowcapError, retainSecondaryFailure } from "../errors.ts";
import type { Host } from "../host.ts";
import { hostS } from "../internal/ffi/host.ts";
import { NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { ab } from "../internal/seam.ts";
import { L } from "../internal/layout.ts";
import { type CloseOptions, encodeCloseOptions, lifecycleClosed, monotonicNowMs } from "../lifecycle.ts";
import { type MintAwaitHandle, type PromiseFactoryHandle } from "../promise.ts";
import {
	flushOutbound as pumpFlushOutbound,
	lastAbort as pumpLastAbort,
	type PumpHandle,
	runHandshake,
	serveLoop,
} from "../pump.ts";
import type { Channel, LoopChannel } from "./channel.ts";
import { traceDrainHost } from "../trace.ts";
import { type BehaviorEntry, type HostingHandle, insideTurn } from "../trampoline.ts";
import type { Argument, SessionProfile } from "../value.ts";
import { readSessionProfile, readSessionTransportName } from "./metadata.ts";
import { Outbound, type WriterOwner } from "./writer.ts";

function isLoopChannel(transport: Channel): transport is LoopChannel {
	return (transport as { driverLoop?: unknown }).driverLoop != null;
}

// One object per Session replaces the pump and writer-owner objects. Consumers
// call prototype methods on this owner, so vow/hosting operations allocate no
// handle object or adapter closures. A pending vow retains this state until it
// settles; the Host registry keeps the public Session identity for callbacks.
export class SessionState implements PumpHandle, WriterOwner, MintAwaitHandle, PromiseFactoryHandle, HostingHandle {
	readonly #session: object;
	#ptr: Ptr;
	readonly #host: Host;
	readonly #transport: Channel;
	#serving: Promise<void> | null = null;
	// Set the moment teardown begins (an application close, or the transport
	// reporting EOF), so a read cancelled by our own close is clean and the
	// adapter reports transport loss to the core only once.
	#closing = false;
	#released = false;
	#releasePending = false;
	#transportClose: Promise<void> | null = null;
	#closePromise: Promise<void> | null = null;
	#closeResolve: (() => void) | null = null;
	#closeReject: ((error: unknown) => void) | null = null;
	// The action drain catches FLUSH/CLOSE write failures so one session's
	// terminal wire fault does not fail an unrelated Host drain. Retain the
	// exact first value here for both observable Session boundaries.
	#wireFailure: { readonly error: unknown } | null = null;
	// Once inbound EOF/read/protocol failure owns teardown, a failed attempt to
	// write cleanup onto that known-dead stream is secondary, not a new cause.
	#transportLost = false;
	// Fired synchronously at the transport-retirement boundary. Applications
	// that own connection-indexed state use this instead of discovering a dead
	// session through a later failed send.
	readonly #closeListeners = new Set<() => void>();
	// The writer task that owns every write to the transport.
	readonly #outbound: Outbound;
	readonly #outboundScratch = {
		managedFrame: new Uint8Array(L.MANAGED_FRAME_SIZE),
		prefix: new Uint8Array(HOST_OUTBOUND_PREFIX_CAP),
		prefixLen: new Uint8Array(8),
	};
	// Distributed GC (ADR-0025), opt-in and off by default (see `gc.ts`).
	gcEnabled = false;

	constructor(ptr: Ptr, host: Host, transport: Channel, session: object) {
		this.#ptr = ptr;
		this.#host = host;
		this.#transport = transport;
		this.#session = session;
		this.#outbound = new Outbound(this);
	}

	get ptr(): Ptr {
		return this.#ptr;
	}
	get hostOwner(): Host {
		return this.#host;
	}
	get hostRaw(): Ptr {
		return this.#host.raw;
	}
	get hosted(): Map<bigint, bigint> {
		return this.#host.hosted;
	}
	get deliverHost(): Host {
		return this.#host;
	}
	get released(): boolean {
		return this.#released;
	}
	get closingFlag(): boolean {
		return this.#closing;
	}
	set closingFlag(value: boolean) {
		this.#closing = value;
	}
	get wireFailure(): { readonly error: unknown } | null {
		return this.#wireFailure;
	}
	get closeDelivered(): boolean {
		return this.#outbound.closeDelivered;
	}
	get writerExited(): Promise<void> {
		return this.#outbound.exited;
	}
	get outboundScratch(): PumpHandle["outboundScratch"] {
		return this.#outboundScratch;
	}
	written(covering: number): Promise<void> {
		return this.#outbound.written(covering);
	}
	read(): Promise<Uint8Array | null> {
		return this.#transport.read();
	}
	write(data: Uint8Array): Promise<void> {
		return this.#transport.write(data);
	}
	drainParkedReleases(): void {
		this.#host.drainParkedReleases();
	}
	kickActions(): Promise<void> {
		return this.#host.kickActions();
	}
	settleActions(): Promise<void> {
		return this.#host.settleActions();
	}
	signalCloseActivity(): void {
		this.#host.signalCloseActivity();
	}
	drainGc(): void {
		this.#host.drainGc();
	}
	attend(): void {
		this.#attendInbound();
	}
	awaitVow(vow: bigint): Promise<Argument> {
		return this.#host.awaitVow(vow);
	}
	parkVowRelease(vow: bigint): void {
		this.#host.parkVowRelease(vow);
	}
	vowMinted(vow: bigint, trackGc = false): void {
		this.#host.vowMinted(vow, trackGc && this.gcEnabled);
	}
	trackVow(handle: object, vow: bigint): void {
		this.#host.trackVow(handle, vow);
	}
	scheduleProgress(): void {
		this.#host.scheduleKick();
	}
	recordBackgroundFailure(failure: unknown): void {
		this.#host.recordBackgroundFailure(failure);
	}
	registerBehavior(entry: BehaviorEntry): bigint {
		return this.#host.registerHostedBehavior(entry);
	}
	unregisterBehavior(id: bigint): void {
		this.#host.unregisterHostedBehavior(id);
	}
	scheduleKick(): void {
		this.#host.scheduleKick();
	}
	trackWriter(writer: Promise<void>): void {
		this.#host.trackSessionWriter(writer);
	}

	get closing(): boolean {
		return this.#closing || this.#released;
	}

	get sessionOpen(): boolean {
		return !this.#released &&
			hostS.glowcap_host_session_is_open(this.#ptr) === 1;
	}

	get profile(): SessionProfile {
		this.guardOpen();
		return readSessionProfile(this.#ptr);
	}

	get transportName(): string {
		this.guardOpen();
		return readSessionTransportName(this.#ptr);
	}

	// The construction boundary in Session retires the connection on failure.
	establish(handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS): Promise<void> {
		return runHandshake(this, handshakeTimeoutMs);
	}

	// ── The pump (choreography in pump.ts) ──────────────────────────────────────

	#attendInbound(): void {
		if (this.#serving === null) {
			const transport = this.#transport;
			if (isLoopChannel(transport)) {
				// Post-open setup is done: tell the loop to start delivering
				// this session's inbound, the same contract the byte-fed arm
				// states by resuming retained input before reading.
				transport.driverLoop.serveSession(this.#ptr);
				this.#serving = transport.waitClosed();
			} else {
				this.#serving = serveLoop(this);
			}
		}
	}

	serve(): Promise<void> {
		try {
			this.#attendInbound();
		} catch (error) {
			return Promise.reject(error);
		}
		return this.#serving!;
	}

	onClose(listener: () => void): () => void {
		if (this.#released || this.#transportClose !== null) {
			listener();
			return () => {};
		}
		this.#closeListeners.add(listener);
		return () => this.#closeListeners.delete(listener);
	}

	#notifyCloseListeners(): void {
		for (const listener of this.#closeListeners) {
			this.#closeListeners.delete(listener);
			try {
				listener();
			} catch (error) {
				this.#host.recordBackgroundFailure(error);
			}
		}
	}

	lastAbort(): AbortDetail | null {
		return pumpLastAbort(this);
	}

	requestFlush(): number {
		return this.#outbound.request();
	}

	closeAfterFlush(result: number): void {
		this.#outbound.closeAfterFlush(result);
	}

	async flushOutbound(): Promise<boolean> {
		try {
			const transport = this.#transport;
			if (isLoopChannel(transport)) {
				transport.driverLoop.stepNow();
				return false;
			}
			return await pumpFlushOutbound(this);
		} catch (error) {
			// The pump records before retiring a byte stream; this also owns a
			// loop-step refusal, where no byte pump exists. First-cause retention
			// makes the repeated byte-pump call idempotent.
			this.recordOutboundFailure(error);
			this.closeTransport();
			throw error;
		}
	}

	recordWireFailure(error: unknown): void {
		if (this.#wireFailure === null) this.#wireFailure = { error };
	}

	markTransportLost(): void {
		this.#transportLost = true;
	}

	recordOutboundFailure(error: unknown): void {
		// A pump records before retiring a damaged stream. If the wrapper is
		// already released here, local teardown caused this late write refusal;
		// the committed closed state remains authoritative.
		if (!this.#released && this.#transportClose === null && !this.#transportLost) {
			if (this.#wireFailure === null) this.recordWireFailure(error);
			else retainSecondaryFailure(this.#wireFailure.error, error);
		}
	}

	throwWireFailure(): void {
		if (this.#wireFailure !== null) throw this.#wireFailure.error;
	}

	/** Join a terminal result to physical retirement without letting a later
	 * close refusal replace the first cause. If no retirement is in flight,
	 * start it so every rejected close still leaves a committed state. */
	async #joinCloseBarrier(result: Promise<void> = Promise.resolve()): Promise<void> {
		let first: { readonly error: unknown } | null = this.#wireFailure;
		try {
			await result;
		} catch (error) {
			if (first === null) first = { error };
		}
		const retirement = this.#transportClose ?? (this.#released ? Promise.resolve() : this.closeTransport());
		try {
			await retirement;
		} catch (error) {
			if (first === null) first = { error };
		}
		if (first !== null) throw first.error;
	}

	// ── Teardown ────────────────────────────────────────────────────────────────

	async close(options: CloseOptions = {}): Promise<void> {
		const encoded = encodeCloseOptions(options);
		if (this.#closePromise !== null) {
			if (!this.#released && !this.#outbound.closeDelivered) {
				this.#beginClose(encoded);
				if (insideTurn()) {
					void Promise.resolve().then(() => this.#host.scheduleKick());
				} else {
					this.#host.scheduleKick();
				}
			}
			await this.#joinCloseBarrier(this.#closePromise);
			return;
		}
		if (this.#released) {
			await this.#joinCloseBarrier();
			return;
		}
		// The core already ended this session, and its writer is closing the
		// transport after the final frames. Join that instead of asking the
		// core to close a session it retired.
		if (this.#outbound.closeDelivered) {
			await this.#outbound.exited;
			await this.#joinCloseBarrier();
			return;
		}
		// Natural EOF or a transport fault already made the serve pump the one
		// teardown owner. A concurrent explicit close joins that retirement;
		// starting a second FFI close here can queue CLOSE after the pump's
		// action-barrier snapshot and strand its result behind wrapper release.
		if (this.#closing && this.#serving !== null) {
			await this.#joinCloseBarrier(this.#serving);
			return;
		}
		const transport = this.#transport;
		if (isLoopChannel(transport)) {
			await this.#joinCloseBarrier(transport.driverLoop.closeSession(this.#ptr, options));
			return;
		}
		let closeResolve: (() => void) | null = null;
		let closeReject: ((error: unknown) => void) | null = null;
		const closePromise = new Promise<void>((resolve, reject) => {
			closeResolve = resolve;
			closeReject = reject;
		});
		this.#beginClose(encoded);
		this.#closePromise = closePromise;
		this.#closeResolve = closeResolve;
		this.#closeReject = closeReject;
		const begin = () => this.#driveClose();
		void (insideTurn() ? Promise.resolve().then(begin) : begin());
		if (this.#serving !== null) {
			await Promise.race([
				closePromise.catch(() => {}),
				this.#serving.catch(() => {}),
			]);
			// A simultaneous peer EOF can let the serve pump physically retire
			// the wrapper before a previously popped CLOSE action publishes its status-allow: ownership and operation ordering
			// result. Release is authoritative terminal success for cleanup; do
			// not wait forever on an action that can no longer name this session. status-allow: lifecycle transition
			if (this.#released) {
				this.finishClose(OK);
				await this.#joinCloseBarrier(closePromise);
				return;
			}
		}
		await this.#joinCloseBarrier(closePromise);
	}

	#beginClose(encoded: Uint8Array): void {
		checkHost(hostS.glowcap_host_session_close(
			this.#ptr,
			ab(encoded),
			monotonicNowMs(),
		));
		this.#closing = true;
		// The close call escalates pending-work policy while a close driver may
		// already be parked; wake it so it re-reads progress.
		this.#host.signalCloseActivity();
	}

	async #driveClose(): Promise<void> {
		try {
			while (!this.#released) {
				// Arm the host-level waiter before reading progress (the
				// lost-wakeup discipline). Host-wide activity or another
				// session's deadline may wake this loop early; the re-check
				// makes that harmless.
				const activity = this.#host.armCloseActivity();
				const state = new Uint8Array(4);
				const rc = hostS.glowcap_host_session_close_progress(
					this.#ptr,
					monotonicNowMs(),
					ab(state),
				);
				if (rc !== 0 && rc !== TIMEOUT) checkHost(rc);
				lifecycleClosed(new DataView(state.buffer).getUint32(0, true));
				// Drain what the progress call queued (a spent grace escalates
				// into teardown actions). A drain that ran work signals the
				// armed waiter, so the wait below returns at once and the loop
				// re-checks instead of parking over undrained work.
				await this.#host.kickActions();
				if (!this.#released) await this.#host.waitCloseWake(activity);
			}
			// The close's terminal facts (its session-closed trace record among
			// them) enter the capture ring as the release commits, after this
			// loop's last drain. Flush them with the close, the same drain the
			// Host's own close runs before its ring dies: an idle host has no
			// next drain, and a trace consumer would otherwise hear this close
			// only when unrelated activity happened by.
			traceDrainHost(this.#host.raw);
		} catch (error) {
			this.#closeReject?.(error);
			this.#closeResolve = null;
			this.#closeReject = null;
		}
	}

	finishClose(result: number): void {
		const resolve = this.#closeResolve;
		const reject = this.#closeReject;
		this.#closeResolve = null;
		this.#closeReject = null;
		if (this.#wireFailure !== null) reject?.(this.#wireFailure.error);
		else if (result === TIMEOUT) reject?.(new GlowcapError(TIMEOUT, "finish close exhausted its grace period"));
		else if (result !== 0) reject?.(new GlowcapError(result));
		else resolve?.();
	}

	ffiOwnerDidRelease(): Promise<void> {
		if (this.#released) return this.#transportClose ?? Promise.resolve();
		this.#closing = true;
		this.#outbound.stop();
		this.#released = true;
		this.#releasePending = false;
		const ptr = this.#ptr;
		this.#ptr = NULL;
		this.#host.unregisterSession(ptr, this.#session);
		if (this.#transportClose == null) {
			try {
				this.#transportClose = Promise.resolve(this.#transport.close());
			} catch (error) {
				this.#transportClose = Promise.reject(error);
			}
			this.#host.trackSessionRetirement(this.#transportClose);
		}
		this.#notifyCloseListeners();
		return this.#transportClose;
	}

	ffiTransportDidClose(error: GlowcapError | null): Promise<void> {
		const transport = this.#transport;
		if (!isLoopChannel(transport)) {
			return Promise.reject(new GlowcapError(INVALID_ARGUMENT, "session is not loop-backed"));
		}
		transport.finishClosed(error);
		return this.closeTransport();
	}

	closeTransport(): Promise<void> {
		this.#closing = true;
		this.#outbound.stop();
		if (this.#transportClose == null) {
			try {
				this.#transportClose = Promise.resolve(this.#transport.close());
			} catch (error) {
				this.#transportClose = Promise.reject(error);
			}
			this.#host.trackSessionRetirement(this.#transportClose);
			void this.#transportClose.catch(() => {});
		}
		this.#notifyCloseListeners();
		const transportClose = this.#transportClose;
		if (this.#released || this.#releasePending) return transportClose;
		const ptr = this.#ptr;
		const transport = this.#transport;
		const commitRelease = () => {
			try {
				if (isLoopChannel(transport)) transport.driverLoop.ffiSessionRelease(ptr);
				else checkHost(hostS.glowcap_host_session_release(ptr));
			} catch (error) {
				this.#releasePending = false;
				throw error;
			}
			this.#released = true;
			this.#releasePending = false;
			this.#host.unregisterSession(ptr, this.#session);
			this.#ptr = NULL;
			// The released session is retired close-relevant state; wake any
			// parked close driver.
			this.#host.signalCloseActivity();
			this.#host.scheduleKick();
		};
		this.#releasePending = true;
		if (insideTurn()) {
			this.#host.parkRelease(commitRelease);
		} else {
			commitRelease();
		}
		return transportClose;
	}

	guardOpen(): void {
		if (this.#released) {
			throw new GlowcapError(CLOSED, "connection closed");
		}
	}
}
