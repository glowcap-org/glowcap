// Internal state and lifecycle owner for the public Session facade. Cross-file
// `export` is module visibility; runtime/mod.ts does not expose this base.

import { CLOSED, HANDSHAKE_TIMEOUT_MS, HOST_OUTBOUND_PREFIX_CAP, INVALID_ARGUMENT, OK, TIMEOUT } from "@glowcap/abi";
import { type AbortDetail, checkHost, GlowcapError } from "../errors.ts";
import type { Host } from "../host.ts";
import { hostS } from "../internal/ffi/host.ts";
import { NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { ab } from "../internal/seam.ts";
import { L } from "../internal/layout.ts";
import { type CloseOptions, encodeCloseOptions, lifecycleClosed, monotonicNowMs } from "../lifecycle.ts";
import type { MintAwaitHandle, PromiseFactoryHandle } from "../promise.ts";
import {
	flushOutbound as pumpFlushOutbound,
	lastAbort as pumpLastAbort,
	type PumpHandle,
	runHandshake,
	serveLoop,
} from "../pump.ts";
import type { Channel, LoopChannel } from "../session.ts";
import { traceDrainHost } from "../trace.ts";
import { insideTurn } from "../trampoline.ts";
import type { SessionProfile } from "../value.ts";
import { readSessionProfile, readSessionTransportName } from "./metadata.ts";

function isLoopChannel(transport: Channel): transport is LoopChannel {
	return (transport as { driverLoop?: unknown }).driverLoop != null;
}

export abstract class SessionLifecycle {
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
	// Serializes transport writes. `flushOutbound` runs from the action drain,
	// the feed-failure choreography, and teardown; chaining each flush behind
	// the last keeps every frame whole and in submission order.
	#writing: Promise<void> = Promise.resolve();
	readonly #outboundScratch = {
		managedFrame: new Uint8Array(L.MANAGED_FRAME_SIZE),
		prefix: new Uint8Array(HOST_OUTBOUND_PREFIX_CAP),
		prefixLen: new Uint8Array(8),
	};
	// Live accessors into the private fields above. `pump.ts` drives them.
	readonly #pump: PumpHandle;
	// Opaque Host capability id -> trampoline ctx id for objects this session
	// hosts, so a `Forward` whose target this side hosts composes in process.
	readonly #hosted: Map<bigint, bigint>;
	// Distributed GC (ADR-0025), opt-in and off by default (see `gc.ts`).
	#gcEnabled = false;

	protected constructor(ptr: Ptr, host: Host, transport: Channel) {
		this.#ptr = ptr;
		this.#host = host;
		this.#hosted = host.hosted;
		this.#transport = transport;
		this.#pump = this.#makePump();
		// The host's registry join happens in the concrete `Session`
		// constructor, once `this` can be typed as the class it stores.
	}

	/** Bind `#pump` getters/setters onto this Session's private fields. */
	#makePump(): PumpHandle {
		// deno-lint-ignore no-this-alias -- object-literal getters cannot see Session `#` fields without a closed-over instance
		const s = this;
		return {
			deliverHost: s.#host,
			get ptr() {
				return s.#ptr;
			},
			get released() {
				return s.#released;
			},
			get sessionOpen() {
				return s.sessionOpen;
			},
			get closingFlag() {
				return s.#closing;
			},
			set closingFlag(v: boolean) {
				s.#closing = v;
			},
			get closing() {
				return s.closing;
			},
			get wireFailure() {
				return s.#wireFailure;
			},
			markTransportLost: () => s.markTransportLost(),
			recordWireFailure: (error) => s.recordWireFailure(error),
			recordOutboundFailure: (error) => s.recordOutboundFailure(error),
			get writing() {
				return s.#writing;
			},
			set writing(p: Promise<void>) {
				s.#writing = p;
			},
			outboundScratch: s.#outboundScratch,
			read: () => s.#transport.read(),
			write: (data) => s.#transport.write(data),
			drainParkedReleases: () => s.#host.drainParkedReleases(),
			kickActions: () => s.#host.kickActions(),
			settleActions: () => s.#host.settleActions(),
			signalCloseActivity: () => s.#host.signalCloseActivity(),
			closeTransport: () => s.closeTransport(),
		};
	}

	/** Bind the mint/await seam for `promise.fetchLike` without exporting
	 * private Session fields. */
	protected makeMintAwait(): MintAwaitHandle {
		// deno-lint-ignore no-this-alias -- object-literal methods close over Session `#` fields
		const s = this;
		return {
			guardOpen: () => s.guardOpen(),
			drainGc: () => s.#host.drainGc(),
			get ptr() {
				return s.#ptr;
			},
			vowMinted: (vow, trackGc = false) => s.#host.vowMinted(vow, trackGc && s.#gcEnabled),
			attend: () => s.#attendInbound(),
			awaitVow: (vow) => s.#host.awaitVow(vow),
			kickActions: () => s.#host.kickActions(),
			parkVowRelease: (vow) => s.#host.parkVowRelease(vow),
		};
	}

	/** Bind the far-send `promiseFor` factory without exporting private fields. */
	protected makePromiseFactory(): PromiseFactoryHandle {
		// deno-lint-ignore no-this-alias -- object-literal methods close over Session `#` fields
		const s = this;
		return {
			attend: () => s.#attendInbound(),
			awaitVow: (vow) => s.#host.awaitVow(vow),
			kickActions: () => s.#host.kickActions(),
			parkVowRelease: (vow) => s.#host.parkVowRelease(vow),
			vowMinted: (vow, trackGc = false) => s.#host.vowMinted(vow, trackGc && s.#gcEnabled),
			trackVow: (handle, vow) => s.#host.trackVow(handle, vow),
			scheduleProgress: () => s.#host.scheduleKick(),
			get hostRaw() {
				return s.#host.raw;
			},
			get hostOwner() {
				return s.#host;
			},
			get ptr() {
				return s.#ptr;
			},
		};
	}

	/** The raw GlowcapHostSession handle. Binding-internal: the host's DIAL arm
	 * reports it through `glowcap_host_dialed`. */
	get raw(): Ptr {
		return this.#ptr;
	}

	/** The session's shared host, its retained identity and handoff router.
	 * Shared by every session of one host, so the gifter half of a handoff
	 * can reach a sibling session's session keys. An application reads it to
	 * publish host-publications (`Host.publish`), share one identity
	 * across dials, or set the redeem posture. */
	get host(): Host {
		return this.#host;
	}

	/** Whether local transport teardown has begun. Binding-internal pump seam. */
	get closing(): boolean {
		return this.#closing || this.#released;
	}

	/** Nonzero once the keyed handshake has completed and the session is open. */
	get sessionOpen(): boolean {
		return !this.#released &&
			hostS.glowcap_host_session_is_open(this.#ptr) === 1;
	}

	/** The version, codec, and feature set this live session settled with its
	 * partner. No Host preference is inferred at this layer. */
	get profile(): SessionProfile {
		this.guardOpen();
		return readSessionProfile(this.#ptr);
	}

	/** The exact netlayer symbol this connection was opened through. */
	get transportName(): string {
		this.guardOpen();
		return readSessionTransportName(this.#ptr);
	}

	// Drive the freshly opened connection's keyed handshake to an open session,
	// abandoning the connection on any failure (release + transport close) so a
	// rude partner costs one dial or one accept, never the caller. The read/feed
	// loop lives in `pump.runHandshake`.
	//
	// The one place both halves bound that handshake. A peer that opens the byte
	// channel and then says nothing is the case no failure check can catch:
	// nothing fails, the handshake waits, so unbounded it parks the
	// dialer forever, and on the accepting side every later connection behind
	// that one client. An elapsed budget takes the same abandon path a failed
	// handshake does, and closing the transport is what unparks the abandoned
	// read.
	protected async establish(handshakeTimeoutMs: number | null = HANDSHAKE_TIMEOUT_MS): Promise<this> {
		try {
			await runHandshake(this.#pump, handshakeTimeoutMs);
			return this;
		} catch (err) {
			await this.closeTransport();
			throw err;
		}
	}

	// ── The pump (choreography in pump.ts) ──────────────────────────────────────

	/** Run the inbound loop: read transport packets, hand them to the Host
	 * transport seam (behaviors run and vow completions queue inside the feed),
	 * and drain the action queue. Resolves when the connection closes cleanly;
	 * rejects on a transport or protocol error. Started once; calling again
	 * returns the same promise.
	 *
	 * A loop-backed session (ADR-0024) has no byte pump of its own: the
	 * driver loop reads, feeds, and drains. Its serve promise only awaits
	 * the session's closure, keeping the resolves-on-close contract. */
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
				this.#serving = serveLoop(this.#pump);
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

	/** Run `listener` exactly once when this session's transport retires.
	 * Registration after retirement runs it immediately. The callback is a
	 * lifecycle signal only; `serve()` remains the typed failure channel. */
	onClose(listener: () => void): () => void {
		if (this.#released || this.#transportClose !== null) {
			listener();
			return () => {};
		}
		this.#closeListeners.add(listener);
		return () => this.#closeListeners.delete(listener);
	}

	/** The typed cause of this CapTP session's most recent local dispatch failure,
	 * or null when none has been recorded. The flat per-feed error code names
	 * the failure family; this names the member. */
	lastAbort(): AbortDetail | null {
		return pumpLastAbort(this.#pump);
	}

	/** Drain every transport-ready packet on this CapTP session and write it to
	 * the transport, how a FLUSH action lands. Writes are serialized, so
	 * packets stay whole and in submission order. On a loop-backed session one
	 * loop step is the flush. Binding-internal. */
	async flushOutbound(): Promise<void> {
		try {
			const transport = this.#transport;
			if (isLoopChannel(transport)) {
				transport.driverLoop.stepNow();
				return;
			}
			await pumpFlushOutbound(this.#pump);
		} catch (error) {
			// The pump records before retiring a byte stream; this also owns a
			// loop-step refusal, where no byte pump exists. First-cause retention
			// makes the repeated byte-pump call idempotent.
			this.recordOutboundFailure(error);
			this.closeTransport();
			throw error;
		}
	}

	/** Retain one terminal wire failure for `serve()` and `close()`.
	 * Binding-internal pump seam. */
	recordWireFailure(error: unknown): void {
		if (this.#wireFailure === null) this.#wireFailure = { error };
	}

	/** Mark physical/protocol loss as the teardown owner. Binding-internal. */
	markTransportLost(): void {
		this.#transportLost = true;
	}

	/** Retain a write failure only while outbound I/O can still be the first
	 * terminal fact. Binding-internal pump seam. */
	recordOutboundFailure(error: unknown): void {
		// A pump records before retiring a damaged stream. If the wrapper is
		// already released here, local teardown caused this late write refusal;
		// the committed closed state remains authoritative.
		if (!this.#released && this.#transportClose === null && !this.#transportLost) {
			this.recordWireFailure(error);
		}
	}

	protected throwWireFailure(): void {
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

	/** Close this session's connection and nothing else. A running `serve()`
	 * resolves cleanly; pending vows settle with the typed CLOSED.
	 *
	 * It does not reach a sibling session, and it does not reach the
	 * connections the host opened by itself to redeem a handoff: the `via`
	 * from `sendRedeeming()` is one of those. `Runtime.close()` ends the
	 * Runtime's Host and those sessions. */
	async close(options: CloseOptions = {}): Promise<void> {
		const encoded = encodeCloseOptions(options);
		if (this.#closePromise !== null) {
			if (!this.#released) {
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
			// the wrapper before a previously popped CLOSE action publishes its
			// result. Release is authoritative terminal success for cleanup; do
			// not wait forever on an action that can no longer name this session.
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

	/** Complete an explicit byte-fed close after its CLOSE action has flushed
	 * and released the transport. Natural transport loss has no waiter. */
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

	/** Commit wrapper retirement after the FFI owner released the whole Host
	 * or loop. No per-session FFI call is valid beyond this boundary. */
	ffiOwnerDidRelease(): Promise<void> {
		if (this.#released) return this.#transportClose ?? Promise.resolve();
		this.#closing = true;
		this.#released = true;
		this.#releasePending = false;
		const ptr = this.#ptr;
		this.#ptr = NULL;
		this.#host.unregisterSession(ptr, this);
		if (this.#transportClose == null) {
			try {
				this.#transportClose = Promise.resolve(this.#transport.close());
			} catch (error) {
				this.#transportClose = Promise.reject(error);
			}
			this.#host.trackSessionRetirement(this.#transportClose);
		}
		return this.#transportClose;
	}

	/** Project one FFI SESSION_CLOSED event onto this wrapper before release.
	 * Binding-internal: the loop owns classification; Session owns only promise
	 * and listener settlement. */
	ffiTransportDidClose(error: GlowcapError | null): Promise<void> {
		const transport = this.#transport;
		if (!isLoopChannel(transport)) {
			return Promise.reject(new GlowcapError(INVALID_ARGUMENT, "session is not loop-backed"));
		}
		transport.finishClosed(error);
		return this.closeTransport();
	}

	/** Close just this session, without touching the host's other sessions:
	 * stop the transport first, then retire the host's entry and
	 * free the host handle (the core settles any still-parked far vows during
	 * release), so no foreign call touches a freed session.
	 * A release refused inside a behavior callback is parked for the next
	 * drain, never dropped. Binding-internal. */
	closeTransport(): Promise<void> {
		this.#closing = true;
		if (this.#transportClose == null) {
			for (const listener of this.#closeListeners) listener();
			this.#closeListeners.clear();
		}
		if (this.#transportClose == null) {
			try {
				this.#transportClose = Promise.resolve(this.#transport.close());
			} catch (error) {
				this.#transportClose = Promise.reject(error);
			}
			this.#host.trackSessionRetirement(this.#transportClose);
			void this.#transportClose.catch(() => {});
		}
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
			this.#host.unregisterSession(ptr, this);
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

	async [Symbol.asyncDispose](): Promise<void> {
		await this.close();
	}

	protected guardOpen(): void {
		if (this.#released) {
			throw new GlowcapError(CLOSED, "connection closed");
		}
	}

	protected get ffiPtr(): Ptr {
		return this.#ptr;
	}

	protected get hostOwner(): Host {
		return this.#host;
	}

	protected get hostedActors(): Map<bigint, bigint> {
		return this.#hosted;
	}

	protected get distributedGcEnabled(): boolean {
		return this.#gcEnabled;
	}

	protected set distributedGcEnabled(enabled: boolean) {
		this.#gcEnabled = enabled;
	}
}
