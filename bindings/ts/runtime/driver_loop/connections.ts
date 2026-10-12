// The driver archive's TypeScript face (ADR-0112): `DriverLoop` parks the
// runtime on the loop's one readiness descriptor, steps with a zero timeout on
// the JavaScript thread when it signals or when a Host verb kicks, and drains
// the one event queue: dial outcomes into promises, accepted sessions into a
// queue, completions into the adopted wrapper Host's vow table.
//
// This tier owns generic dial/listen/event lifecycle. Transport archives
// contribute provider packages explicitly at the product edge that selects them.
//
// Parking: the readiness descriptor is a kernel readiness set (epoll/kqueue),
// which no runtime socket wrapper can read as a stream, so the park is one
// off-thread `poll(2)` on a dup of it through the runtime's nonblocking FFI.
// That is why this tier needs `ffi.offloadsBlockingCalls()`: a runtime whose
// FFI stays on the JavaScript thread (Bun's, the wasm adapter's) cannot park,
// and callers fail closed instead of selecting a second listener or dial path.
// Every step runs synchronously on the JavaScript thread because behavior
// trampolines fire inside it; provider starts are nonblocking, and readiness
// drives connect completion and CapTP handshakes through later steps.

import { BUFFER_TOO_SMALL, CLOSED, IO } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";
import { checkDriver, closeDriverListener } from "../internal/driver_failure.ts";
import { loopS } from "../internal/ffi/driver.ts";
import { type Ptr } from "../internal/ffi/runtime.ts";
import { L } from "../internal/layout.ts";
import { ab, outU64 } from "../internal/seam.ts";
import { type Locator, OwnedLocator, parseLocator, withOwnedLocator } from "../locator.ts";
import { Session } from "../session.ts";
import { encodeTransportOperationOptions } from "./options.ts";
import { LoopTransport } from "./transport.ts";

import { DriverLoopDrive } from "./drive.ts";
import { type ListenerWaiter, loopClosedError, utf8Encoder } from "./state.ts";

export abstract class DriverLoopConnections extends DriverLoopDrive {
	// ── Dial, accept, listen ───────────────────────────────────────────────────

	/** Begin a nonblocking dial and await its session handle. The handshake advances
	 * across steps (`driver.HostRuntime.startDial`), so loops on one
	 * thread can dial each other and a stalled partner costs its budget,
	 * never the loop. */
	dial(locator: Locator | string, transportOptions?: Uint8Array): Promise<Ptr> {
		this._guardHandle();
		const parsed = typeof locator === "string" ? parseLocator(locator) : locator;
		const out = new Uint8Array(8);
		const options = encodeTransportOperationOptions(transportOptions);
		withOwnedLocator(
			parsed,
			(owned) =>
				checkDriver(
					loopS.glowcap_driver_dial(this._h, owned.borrowView(), options, ab(out)),
				),
		);
		const operationId = outU64(out);
		const pending = new Promise<Ptr>((resolve, reject) => {
			this._pendingDials.set(operationId, { resolve, reject });
		});
		this.scheduleStep();
		return pending;
	}

	/** Await the next accepted session handle (bind a listener first), or null
	 * once the loop closes, so a server iteration ends rather than parking
	 * forever. */
	accept(listener: bigint): Promise<Ptr | null> {
		if (this._terminalFailure != null) return Promise.reject(this._terminalFailure);
		const queued = this._accepts.get(listener)?.shift();
		if (queued != null) return Promise.resolve(queued);
		if (this._released || this._closeRequested || !this._listeners.has(listener)) {
			return Promise.resolve(null);
		}
		return new Promise<Ptr | null>((resolve, reject) => {
			this._acceptWaiters.get(listener)?.push({ resolve, reject });
		});
	}

	/** Bind one listener on a statically composed transport; accepted sessions
	 * arrive through `accept`. One listener per transport. */
	listen(
		transport: string,
		designator: string,
		signal?: AbortSignal,
	): Promise<bigint> {
		this._guardHandle();
		if (signal?.aborted) {
			return Promise.reject(new GlowcapError(CLOSED, "listener setup was cancelled"));
		}
		const t = utf8Encoder.encode(transport);
		const d = utf8Encoder.encode(designator);
		const out = new Uint8Array(8);
		checkDriver(loopS.glowcap_driver_listen(
			this._h,
			ab(t),
			BigInt(t.length),
			ab(d),
			BigInt(d.length),
			null,
			ab(out),
		));
		const listener = outU64(out);
		this._listeners.add(listener);
		this._accepts.set(listener, []);
		this._acceptWaiters.set(listener, []);
		const pending = new Promise<bigint>((resolve, reject) => {
			const waiter: ListenerWaiter = { resolve, reject };
			this._pendingListeners.set(listener, waiter);
			if (signal != null) {
				const onAbort = (): void =>
					this._beginListenerClose(
						listener,
						new GlowcapError(
							CLOSED,
							"listener setup was cancelled",
						),
					);
				waiter.onAbort = () => signal.removeEventListener("abort", onAbort);
				signal.addEventListener("abort", onAbort, { once: true });
				if (signal.aborted) onAbort();
			}
			this.scheduleStep();
		});
		try {
			// Arm after admission: the readiness set must include an active listener
			// when a provider completes setup synchronously.
			this.start();
			this.scheduleStep();
		} catch (error) {
			this._beginListenerClose(
				listener,
				error instanceof GlowcapError ? error : new GlowcapError(IO, String(error)),
			);
		}
		return pending;
	}

	/** The listener's complete canonical OCapN locator. */
	listenerLocator(listener: bigint): Locator {
		this._guardHandle();
		const out = new Uint8Array(L.LOCATOR_VIEW_SIZE);
		checkDriver(loopS.glowcap_driver_listener_locator(this._h, listener, ab(out)));
		const owned = OwnedLocator.cloneView(out);
		try {
			return owned.value();
		} finally {
			owned.release();
		}
	}

	/** Copy opaque provider state that restores this listener's local address. */
	listenerRestorationState(listener: bigint): Uint8Array {
		this._guardHandle();
		let capacity = 0;
		while (true) {
			const out = new Uint8Array(capacity);
			const count = new Uint8Array(L.ptrSize);
			const code = loopS.glowcap_driver_listener_restoration_state(
				this._h,
				listener,
				ab(out),
				BigInt(out.length),
				ab(count),
			);
			const needed = Number(L.getUsize(new DataView(count.buffer), 0));
			if (code === BUFFER_TOO_SMALL) {
				capacity = needed;
				continue;
			}
			checkDriver(code);
			return out.subarray(0, needed);
		}
	}

	/** Replace this listener's advertised locator through its native owner. */
	advertiseListener(listener: bigint, locator: Locator | string): void {
		this._guardHandle();
		const parsed = typeof locator === "string" ? parseLocator(locator) : locator;
		withOwnedLocator(parsed, (owned) =>
			checkDriver(
				loopS.glowcap_driver_listener_advertise(this._h, listener, owned.borrowView()),
			));
	}

	/** Select this listener's locator as the Host's acceptable location. */
	selectListener(listener: bigint): void {
		this._guardHandle();
		checkDriver(loopS.glowcap_driver_listener_select(this._h, listener));
	}

	/** Stop one listener and join the native admission barrier. Events committed
	 * before close remain queued; after this resolves, no later accepted event
	 * can name the listener. */
	closeListener(listener: bigint, reason: GlowcapError = loopClosedError()): Promise<void> {
		if (this._terminalFailure != null) return Promise.reject(this._terminalFailure);
		if (!this._listeners.has(listener)) return Promise.resolve();
		let close = this._listenerCloses.get(listener);
		if (close == null) {
			let resolve!: () => void;
			let reject!: (error: GlowcapError) => void;
			const promise = new Promise<void>((resolvePromise, rejectPromise) => {
				resolve = resolvePromise;
				reject = rejectPromise;
			});
			close = { promise, resolve, reject };
			this._listenerCloses.set(listener, close);
		}
		try {
			this._beginListenerClose(listener, reason);
		} catch (error) {
			const failure = error instanceof GlowcapError
				? error
				: new GlowcapError(IO, `listener close: ${String(error)}`);
			this._listenerCloses.delete(listener);
			close.reject(failure);
		}
		return close.promise;
	}

	/** Commit listener shutdown without creating an application waiter. Used by
	 * setup cancellation, whose listen promise already owns the outcome. */
	protected _beginListenerClose(listener: bigint, reason: GlowcapError): void {
		if (!this._listeners.has(listener) || this._closingListeners.has(listener)) return;
		this._closingListeners.set(listener, reason);
		if (this._released) {
			this._finishListenerClose(listener, reason);
			return;
		}
		this._closeListener(listener, reason);
	}

	protected _closeListener(listener: bigint, reason: GlowcapError): void {
		try {
			if (!this._closeListenerNative(listener)) {
				this.scheduleStep();
				return;
			}
		} catch (error) {
			this._closingListeners.delete(listener);
			throw error;
		}
		let failure: unknown = null;
		try {
			this._dispatchCommittedEvents();
		} catch (error) {
			failure = error;
		}
		try {
			this._finishListenerClose(
				listener,
				failure instanceof GlowcapError ? failure : reason,
			);
		} catch (error) {
			failure ??= error;
		}
		if (failure != null) throw failure;
	}

	/** Dispatch only events committed by earlier steps. Listener close uses
	 * this after native admission is sealed, so it cannot create a new accept
	 * while preserving an old one. */
	protected _dispatchCommittedEvents(): void {
		const events = this._popEvents();
		if (events.length > 0) {
			this._dispatch(events);
			// A drain outside `stepNow` still advances close-relevant state
			// (session closes, releases); wake any parked close driver.
			this._wrapper.signalCloseActivity();
		}
	}

	protected _advanceClosingListeners(): void {
		for (const [listener, reason] of [...this._closingListeners]) {
			if (!this._listeners.has(listener)) continue;
			if (this._closeListenerNative(listener)) this._finishListenerClose(listener, reason);
		}
	}

	protected _closeListenerNative(listener: bigint): boolean {
		return closeDriverListener(this._h, listener);
	}

	protected _finishListenerClose(listener: bigint, reason?: GlowcapError, rejectAccepts = false): void {
		let failure: unknown = null;
		const close = this._listenerCloses.get(listener);
		const waiter = this._pendingListeners.get(listener);
		if (waiter != null) {
			this._settleListener(listener, waiter, { error: reason ?? loopClosedError() });
		}
		this._listeners.delete(listener);
		this._closingListeners.delete(listener);
		this._listenerCloses.delete(listener);
		for (const waiter of this._acceptWaiters.get(listener)?.splice(0) ?? []) {
			if (rejectAccepts && reason != null) waiter.reject(reason);
			else waiter.resolve(null);
		}
		for (const ptr of this._accepts.get(listener)?.splice(0) ?? []) {
			try {
				this.nativeSessionRelease(ptr);
			} catch (error) {
				failure ??= error;
			}
		}
		this._accepts.delete(listener);
		this._acceptWaiters.delete(listener);
		if (close != null) {
			if (failure instanceof GlowcapError) close.reject(failure);
			else if (failure != null) close.reject(new GlowcapError(IO, `listener close: ${String(failure)}`));
			else if (rejectAccepts && reason != null) close.reject(reason);
			else close.resolve();
		}
		if (failure != null) throw failure;
	}

	// ── Session adoption ───────────────────────────────────────────────────────

	/** Wrap a loop-minted session handle as the public `Session`, over the
	 * adopted wrapper Host: every session verb, promise, and trampoline works
	 * on it, with the native loop as the transport and the drain. Idempotent
	 * per handle: a handle already wrapped returns its wrapper. */
	adoptSession(ptr: Ptr): Session {
		const host = this.wrapperHost();
		const existing = host.getSession(ptr);
		if (existing != null) return existing;
		const state = this._unclaimedSessions.get(ptr) ?? { kind: "open" as const };
		const session = Session.adoptLoopSession(ptr, host, new LoopTransport(this));
		this._unclaimedSessions.delete(ptr);
		if (state.kind === "closed") void session.nativeTransportDidClose(state.error);
		return session;
	}

	/** Dial through the loop and wrap the opened session as the public
	 * `Session`. */
	async connectSession(
		locator: Locator | string,
		transportOptions?: Uint8Array,
	): Promise<Session> {
		return this.adoptSession(await this.dial(locator, transportOptions));
	}

	/** Await the next accepted session, wrapped as the public `Session`. It is the
	 * accept-side twin of `connectSession`. The handshake already ran inside
	 * the accepting step; the session arrives open. Null once the loop
	 * closes. */
	async acceptSession(listener: bigint): Promise<Session | null> {
		const ptr = await this.accept(listener);
		return ptr == null ? null : this.adoptSession(ptr);
	}
}
