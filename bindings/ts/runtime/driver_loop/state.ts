// The driver archive's TypeScript face (ADR-0112): `DriverLoop` parks the
// runtime on the loop's one readiness descriptor, steps with a zero timeout on
// the JavaScript thread when it signals or when a Host verb kicks, and drains
// the one event queue — dial outcomes into promises, accepted sessions into a
// queue, completions into the adopted wrapper Host's vow table.
//
// This tier owns generic dial/listen/event lifecycle. Transport archives
// contribute provider packages explicitly at the product edge that selects them.
//
// Parking: the readiness descriptor is a kernel readiness set (epoll/kqueue),
// which no runtime socket wrapper can read as a stream, so the park is one
// off-thread `poll(2)` on a dup of it through the runtime's nonblocking FFI.
// That is why this tier needs `ffi.offloadsBlockingCalls()` — a runtime whose
// FFI stays on the JavaScript thread (Bun's, the wasm adapter's) cannot park,
// and callers fail closed instead of selecting a second listener or dial path.
// Every step runs synchronously on the JavaScript thread because behavior
// trampolines fire inside it; provider starts are nonblocking, and readiness
// drives connect completion and CapTP handshakes through later steps.

import { CLOSED, INTERNAL } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";
import { Host } from "../host.ts";
import type { HostFinalizerState } from "../host/finalizer.ts";
import { type LoopEvent } from "../internal/driver_event.ts";
import { driverCall } from "../internal/driver_failure.ts";
import { loopS } from "../internal/ffi/driver.ts";
import { NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { type CloseOptions } from "../lifecycle.ts";
import { type DriverLoopHandle, Session } from "../session.ts";
import { type DriverLoopFinalizerState, registerDriverLoopFinalizer, retireDriverLoopFinalizer } from "./finalizer.ts";
import { clearProgressClock, type DriverProgressTimer } from "./progress_clock.ts";
import { TerminalDriverRelease } from "./terminal_release.ts";

export const utf8Encoder = new TextEncoder();

export function loopClosedError(): GlowcapError {
	return new GlowcapError(CLOSED, "the loop is closed");
}

function asGlowcapError(error: unknown, operation: string): GlowcapError {
	if (error instanceof GlowcapError) return error;
	return new GlowcapError(INTERNAL, `${operation}: ${String(error)}`);
}

interface DialWaiter {
	resolve: (session: Ptr) => void;
	reject: (error: GlowcapError) => void;
}

export interface ListenerWaiter {
	resolve: (listener: bigint) => void;
	reject: (error: GlowcapError) => void;
	onAbort?: () => void;
}

/** One stepping native loop over one multi-session host (ADR-0112).
 *
 * Construct with `open` on the thread that will drive it, `start()` to park on
 * the readiness descriptor, and `close()` before dropping it. One thread
 * drives one loop; `glowcap_driver_wake` is the one cross-thread call, and the
 * park task is the only place it is needed here. */
export abstract class DriverLoopState implements DriverLoopHandle {
	abstract stepNow(): void;
	abstract scheduleStep(): void;
	abstract settleStep(): Promise<void>;
	abstract nativeSessionRelease(ptr: Ptr): void;
	abstract serveSession(ptr: Ptr): void;
	abstract claimReferenceExporter(reference: Uint8Array): Ptr | null;
	abstract closeSession(ptr: Ptr, options?: CloseOptions): Promise<void>;
	abstract close(options?: CloseOptions): Promise<void>;
	abstract adoptSession(ptr: Ptr): Session;
	abstract parkWantsExit(): boolean;
	abstract parkWake(): void;
	protected abstract _popEvents(): LoopEvent[];
	protected abstract _dispatch(events: LoopEvent[]): void;
	protected abstract _settleListener(
		listener: bigint,
		waiter: ListenerWaiter,
		result: { ready: true } | { error: GlowcapError },
	): void;
	protected abstract _dispatchCommittedEvents(): void;
	protected abstract _advanceClosingListeners(): void;
	protected abstract _finishListenerClose(
		listener: bigint,
		reason?: GlowcapError,
		rejectAccepts?: boolean,
	): void;
	protected _h: Ptr;
	protected _finalizerState: DriverLoopFinalizerState | null = null;
	protected readonly _wrapper: Host;
	protected _released = false;
	protected _terminalFailure: GlowcapError | null = null;
	protected _terminalRelease: TerminalDriverRelease | null = null;
	protected _stepping = false;
	protected _stepScheduled = false;
	protected _scheduledStep: Promise<void> | null = null;
	protected _parkExited: Promise<void> | null = null;
	protected _closing: Promise<void> | null = null;
	protected _progressTimer: DriverProgressTimer = null;
	protected _closeRequested = false;
	// Set only by `_doClose` once the lifecycle is terminal: the park task keeps
	// stepping on readiness through the whole close (it is the close driver's
	// readiness pump) and exits at this flag, before the native release.
	protected _parkStop = false;
	// OPENED/ACCEPTED handles cross one event-to-wrapper ownership window. A
	// true value records SESSION_CLOSED arriving before adoption; the pointer
	// remains valid until the wrapper claims or the binding releases it.
	protected readonly _unclaimedSessions = new Map<
		Ptr,
		| { readonly kind: "open" }
		| { readonly kind: "closed"; readonly error: GlowcapError | null }
	>();
	protected readonly _sessionCloses = new Map<Ptr, {
		readonly promise: Promise<void>;
		readonly resolve: () => void;
		readonly reject: (error: GlowcapError) => void;
	}>();
	protected readonly _pendingDials = new Map<bigint, DialWaiter>();
	protected readonly _pendingListeners = new Map<bigint, ListenerWaiter>();
	protected readonly _accepts = new Map<bigint, Ptr[]>();
	protected readonly _acceptWaiters = new Map<
		bigint,
		Array<{
			readonly resolve: (session: Ptr | null) => void;
			readonly reject: (error: GlowcapError) => void;
		}>
	>();
	protected readonly _listeners = new Set<bigint>();
	protected readonly _closingListeners = new Map<bigint, GlowcapError>();
	protected readonly _listenerCloses = new Map<bigint, {
		readonly promise: Promise<void>;
		readonly resolve: () => void;
		readonly reject: (error: GlowcapError) => void;
	}>();
	// A loop step may deliver for any session. The step carrier supplies the
	// wrapper Host; each callback turn supplies its actual ingress session.
	protected constructor(handle: Ptr, wrapper: Host) {
		this._h = handle;
		this._wrapper = wrapper;
	}

	protected _armFinalizer(host: HostFinalizerState): void {
		this._finalizerState = registerDriverLoopFinalizer(this, this._h, host);
	}

	protected _guardHandle(): void {
		if (this._terminalFailure != null) throw this._terminalFailure;
		if (this._released) throw loopClosedError();
	}

	/** Make one background drive failure terminal and observable to every
	 * binding waiter before releasing the loop-owned graph. */
	protected _failBackground(error: unknown): void {
		this._failBackgroundWithRelease(error);
	}

	protected _failBackgroundWithRelease(error: unknown, initialOutcome?: ReturnType<typeof driverCall>): void {
		if (this._terminalFailure != null) return;
		const failure = asGlowcapError(error, "driver loop failed");
		this._terminalFailure = failure;
		this._parkStop = true;
		this._progressTimer = clearProgressClock(this._progressTimer);
		for (const waiter of this._pendingDials.values()) waiter.reject(failure);
		this._pendingDials.clear();
		for (const waiter of this._pendingListeners.values()) {
			waiter.onAbort?.();
			waiter.reject(failure);
		}
		this._pendingListeners.clear();
		for (const waiter of this._sessionCloses.values()) waiter.reject(failure);
		this._sessionCloses.clear();
		for (const waiters of this._acceptWaiters.values()) {
			for (const waiter of waiters) waiter.reject(failure);
		}
		this._acceptWaiters.clear();
		this._accepts.clear();
		for (const waiter of this._listenerCloses.values()) waiter.reject(failure);
		this._listenerCloses.clear();
		this._listeners.clear();
		this._closingListeners.clear();
		this._unclaimedSessions.clear();
		this._wrapper.failPendingVows(failure);
		this._wrapper.signalCloseActivity();

		if (this._released) return;
		const wrapper = this._wrapper;
		wrapper.prepareLoopTeardown();
		const handle = this._h;
		this._terminalRelease = new TerminalDriverRelease(
			failure,
			() =>
				driverCall(
					"driver-loop.background.release",
					(out) => loopS.glowcap_driver_release(handle, out),
				),
			() => {
				retireDriverLoopFinalizer(this, this._finalizerState);
				this._h = NULL;
				this._released = true;
				return wrapper.finishLoopTeardown();
			},
			initialOutcome,
		);
	}

	/** The exact Host wrapper transferred into this loop. */
	wrapperHost(): Host {
		return this._wrapper;
	}

	/** Stop stepping and release the loop, its sessions, and its host.
	 * Idempotent; safe to start from inside a behavior turn (the native
	 * release runs after the enclosing step unwinds). */
}
