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

import { HOST_ACTION_FAIL, HOST_ACTION_SETTLE, INTERNAL, INVALID_ARGUMENT, OK, WOULD_BLOCK } from "@glowcap/abi";
import { GlowcapError, vowFailure } from "../errors.ts";
import { decodeDriverEvent, type LoopEvent } from "../internal/driver_event.ts";
import { addDriverProvider, checkDriver, driverFailureError } from "../internal/driver_failure.ts";
import { loopS } from "../internal/ffi/driver.ts";
import { L } from "../internal/layout.ts";
import { ab } from "../internal/seam.ts";
import { traceDrainHost } from "../trace.ts";
import { enterDeliver, exitDeliver, insideTurn } from "../trampoline.ts";
import { duplicateReadinessDescriptor, joinParker } from "./parker.ts";

import { DriverLoopLifecycle } from "./lifecycle.ts";
import { type ListenerWaiter, loopClosedError, utf8Encoder } from "./state.ts";

export abstract class DriverLoopDrive extends DriverLoopLifecycle {
	// ── Extension transports ──────────────────────────────────────────────────

	/** Install one archive-owned provider inside the dynamic extent in which
	 * its construction owner is live. The registrar rejects capture and reuse. */
	installProvider(
		prepare: (register: (packageBytes: Uint8Array) => void) => void,
	): void {
		this._guardHandle();
		let active = true;
		let registered = false;
		const register = (packageBytes: Uint8Array): void => {
			if (!active || registered) {
				throw new GlowcapError(INVALID_ARGUMENT, "provider registrar is no longer active");
			}
			addDriverProvider(
				(provider, out) => loopS.glowcap_driver_add_provider(this._h, provider, out),
				packageBytes,
			);
			registered = true;
		};
		try {
			prepare(register);
			if (!registered) {
				throw new GlowcapError(
					INVALID_ARGUMENT,
					"provider installer registered no package",
				);
			}
		} finally {
			active = false;
		}
	}

	/** Ask the native provider registry whether `transport` is owned. */
	hasTransport(transport: string): boolean {
		this._guardHandle();
		const name = utf8Encoder.encode(transport);
		const present = new Uint8Array(1);
		checkDriver(loopS.glowcap_driver_has_transport(
			this._h,
			ab(name),
			BigInt(name.length),
			ab(present),
		));
		return present[0] !== 0;
	}

	// ── Parking and stepping ───────────────────────────────────────────────────

	/** Arm the readiness descriptor and park on it: from here the loop steps
	 * whenever native work is ready. Idempotent. */
	start(): void {
		this._guardHandle();
		if (this._parkExited != null) return;
		const out = new Uint8Array(4);
		checkDriver(loopS.glowcap_driver_readiness_fd(this._h, ab(out)));
		const fd = new DataView(out.buffer).getInt32(0, true);
		const dup = duplicateReadinessDescriptor(fd);
		this._parkExited = joinParker(this, dup, (error) => this._failBackground(error));
		// Drain anything already pending before the first signal.
		try {
			this.stepNow();
		} catch (error) {
			this._failBackground(error);
			throw this._terminalFailure ?? error;
		}
	}

	/** Whether the shared parker should retire this loop's row. */
	parkWantsExit(): boolean {
		return this._parkStop || this._released;
	}

	/** Make this loop's readiness descriptor fire, so the shared parker's
	 * current poll returns and its set rebuilds. Binding-internal. */
	parkWake(): void {
		if (this._released) return;
		void loopS.glowcap_driver_wake(this._h).catch((error: unknown) => {
			this._failBackground(error);
		});
	}

	/** Schedule one loop step soon: how a wrapper verb's kick reaches the
	 * drain. Deferred through a microtask, so a kick from inside a behavior
	 * turn steps only after the enclosing step (or feed) unwinds. */
	scheduleStep(): void {
		if (this._released || this._terminalFailure != null || this._stepScheduled) return;
		this._stepScheduled = true;
		const scheduled = Promise.resolve().then(() => {
			this._stepScheduled = false;
			this.stepNow();
		}).catch((error) => {
			this._failBackground(error);
			throw this._terminalFailure ?? error;
		}).finally(() => {
			if (this._scheduledStep === scheduled) this._scheduledStep = null;
		});
		this._scheduledStep = scheduled;
		// Most scheduling sites are background wakes. The explicit barrier below
		// observes the same promise when a caller owns the outcome.
		void scheduled.catch(() => {});
	}

	/** Join the deferred step, event dispatch, and trace drain scheduled by a
	 * caller-owned Host verb. */
	settleStep(): Promise<void> {
		if (this._terminalFailure != null) return Promise.reject(this._terminalFailure);
		if (this._released) return Promise.reject(loopClosedError());
		this.scheduleStep();
		return this._scheduledStep ?? Promise.resolve();
	}

	/** Drain zero-timeout steps and events through quiescence on the driving
	 * thread. Reaching WOULD_BLOCK permits the readiness edge to be cleared. */
	stepNow(): void {
		if (this._terminalFailure != null) throw this._terminalFailure;
		if (this._released || this._stepping || insideTurn()) return;
		this._stepping = true;
		// Whether any step observed work. This is the loop tier's one step/drain
		// funnel, the park task, `scheduleStep`, the progress clock, and the close
		// drivers all step through here, so signaling on progress here is what
		// wakes a close driver parked on loop activity. Signaling only when work
		// ran keeps a close driver's own quiescent steps from waking the waiter
		// it just armed.
		let progressed = false;
		try {
			const host = this._wrapper;
			while (true) {
				// The head of the byte-fed kick, one tier up: run parked releases and
				// reclaimed-import releases before every step, so a dropped `Ref`'s
				// op:gc-exports flushes before another wire turn can run.
				host?.drainParkedReleases();
				host?.drainGc();
				// The step is the deliver: behaviors fire inside it, and the bracket
				// latches their turns to this loop's wrapper Host.
				const prev = host != null ? enterDeliver(host) : null;
				let rc: number;
				try {
					rc = loopS.glowcap_driver_step(this._h, 0);
				} finally {
					if (host != null) exitDeliver(prev);
				}
				if (rc === WOULD_BLOCK) break;
				checkDriver(rc);
				progressed = true;
				const events = this._popEvents();
				host?.drainParkedReleases();
				if (events.length > 0) this._dispatch(events);
				this._advanceClosingListeners();
			}
		} finally {
			this._stepping = false;
			// Wrapper Host verbs can fill the trace ring before the native loop
			// reports any step progress. Drain on every legal unwind, like the
			// byte-fed action drain, so those facts do not wait for unrelated I/O.
			traceDrainHost(this._wrapper.raw);
			if (progressed) {
				this._wrapper.signalCloseActivity();
			}
		}
		this._rearmProgressClock();
		this._wrapper?.drainParkedReleases();
	}

	protected _popEvents(): LoopEvent[] {
		const out: LoopEvent[] = [];
		const buf = new Uint8Array(L.DRIVER_EVENT_SIZE);
		while (true) {
			const rc = loopS.glowcap_driver_next_event(this._h, ab(buf));
			if (rc === WOULD_BLOCK) return out;
			checkDriver(rc);
			out.push(decodeDriverEvent(buf));
		}
	}

	protected _dispatch(events: LoopEvent[]): void {
		const host = this._wrapper;
		for (const event of events) {
			switch (event.kind) {
				case "opened": {
					const waiter = this._pendingDials.get(event.operationId);
					this._pendingDials.delete(event.operationId);
					if (waiter == null) {
						this._unclaimedSessions.set(event.session, { kind: "open" });
						this.nativeSessionRelease(event.session);
					} else {
						this._unclaimedSessions.set(event.session, { kind: "open" });
						waiter.resolve(event.session);
					}
					break;
				}
				case "openFailed": {
					const waiter = this._pendingDials.get(event.operationId);
					this._pendingDials.delete(event.operationId);
					waiter?.reject(driverFailureError(event, "dial"));
					break;
				}
				case "listenerReady": {
					if (this._closingListeners.has(event.listener)) break;
					const waiter = this._pendingListeners.get(event.listener);
					if (waiter == null) break;
					this._settleListener(event.listener, waiter, { ready: true });
					break;
				}
				case "listenerFailed": {
					const failure = driverFailureError(event, "listener");
					if (this._closingListeners.has(event.listener)) {
						this._finishListenerClose(event.listener, failure, true);
						break;
					}
					const waiter = this._pendingListeners.get(event.listener);
					if (waiter != null) {
						this._settleListener(event.listener, waiter, {
							error: failure,
						});
					}
					this._finishListenerClose(event.listener, failure, true);
					break;
				}
				case "accepted": {
					const waiters = this._acceptWaiters.get(event.listener);
					const queue = this._accepts.get(event.listener);
					if (waiters == null || queue == null) {
						this._unclaimedSessions.set(event.session, { kind: "open" });
						this.nativeSessionRelease(event.session);
						throw new GlowcapError(
							INTERNAL,
							`accepted session names unknown listener ${event.listener}`,
						);
					}
					this._unclaimedSessions.set(event.session, { kind: "open" });
					const waiter = waiters?.shift();
					if (waiter != null) waiter.resolve(event.session);
					else queue.push(event.session);
					break;
				}
				case "sessionClosed": {
					this._finishSessionCloseIfClosed(event.session);
					const failure = event.primaryResult === OK ? null : driverFailureError(event, "session");
					// The pump's EOF choreography, one tier up: `closeTransport`
					// records local teardown and retires the shell so a later verb
					// refuses CLOSED. The native side already broke the far vows and
					// classified their FAIL completions. A session this
					// binding never wrapped (a loop-internal redeem dial) has no
					// shell to retire, so its handle is released here directly.
					const shell = host?.getSession(event.session);
					if (shell != null) void shell.nativeTransportDidClose(failure);
					else if (this._unclaimedSessions.has(event.session)) {
						this._unclaimedSessions.set(event.session, { kind: "closed", error: failure });
					} else {
						this._unclaimedSessions.set(event.session, { kind: "closed", error: failure });
						this.nativeSessionRelease(event.session);
					}
					break;
				}
				case "completion": {
					if (host == null) break;
					const action = event.action;
					if (action.kind === HOST_ACTION_SETTLE) {
						host.settleVow(action.ticket, { ok: action.value });
					} else if (action.kind === HOST_ACTION_FAIL) {
						host.settleVow(action.ticket, {
							err: vowFailure(action.result, action.message),
						});
					}
					// FLUSH/CLOSE/DIAL/NEED_GIFT_ID never surface: the loop
					// executes transport-shaped actions internally.
					break;
				}
			}
		}
		host?.drainParkedReleases();
	}

	protected _settleListener(
		listener: bigint,
		waiter: ListenerWaiter,
		result: { ready: true } | { error: GlowcapError },
	): void {
		if (this._pendingListeners.get(listener) !== waiter) return;
		this._pendingListeners.delete(listener);
		waiter.onAbort?.();
		if ("ready" in result) waiter.resolve(listener);
		else waiter.reject(result.error);
	}
}
