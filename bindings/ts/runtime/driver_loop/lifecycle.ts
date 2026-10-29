// The driver archive's TypeScript face (ADR-0024): `DriverLoop` parks the
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

import { OK, TIMEOUT } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";
import { checkDriver, driverCall, driverLastError } from "../internal/driver_failure.ts";
import { loopS } from "../internal/ffi/driver.ts";
import { NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { ab, outPointer } from "../internal/seam.ts";
import { type CloseOptions, encodeCloseOptions, lifecycleClosed, releaseConsumed } from "../lifecycle.ts";
import { traceDrainHost } from "../trace.ts";
import { enterDeliver, exitDeliver, insideTurn } from "../trampoline.ts";
import { retireDriverLoopFinalizer } from "./finalizer.ts";
import { armProgressClock, clearProgressClock, driverStepWaitMs, waitForProgressClock } from "./progress_clock.ts";

import { DriverLoopState, loopClosedError } from "./state.ts";

export abstract class DriverLoopLifecycle extends DriverLoopState {
	close(options: CloseOptions = {}): Promise<void> {
		if (this._terminalFailure != null) {
			this._wrapper.drainParkedReleases();
			return Promise.reject(this._terminalFailure);
		}
		const encoded = encodeCloseOptions(options);
		if (this._closing == null) {
			this._beginClose(encoded);
			const begin = () => this._doClose();
			this._closing = insideTurn() ? Promise.resolve().then(begin) : begin();
			void this._closing.catch(() => {});
		} else if (!this._released) {
			this._beginClose(encoded);
			return this._closing;
		}
		return this._closing;
	}

	/** The server-shaped close (ADR-0024): stop accepting now, release the
	 * unclaimed queue, and close the loop once the last application-owned
	 * session is gone. Sessions already yielded (or dialed on this loop's
	 * Host) remain open until their owners close them, as the byte-fed
	 * server contract requires. Resolves at the eventual FFI release barrier. */
	requestClose(): Promise<void> {
		if (this._terminalFailure != null) {
			this._wrapper.drainParkedReleases();
			return Promise.reject(this._terminalFailure);
		}
		if (this._closing != null) return this._closing;
		this._closeRequested = true;
		checkDriver(loopS.glowcap_driver_retire(this._h));
		// Retire changes what a step can conclude while a close driver may
		// already be parked; wake it so it re-reads progress.
		this._wrapper.signalCloseActivity();
		const begin = () => this._doClose();
		this._closing = insideTurn() ? Promise.resolve().then(begin) : begin();
		void this._closing.catch(() => {});
		return this._closing;
	}

	protected _beginClose(encoded: Uint8Array): void {
		checkDriver(loopS.glowcap_driver_close(this._h, encoded));
		// Claim detached failures and channel retirements before any close step
		// can consume them or unregister a wrapper from the live-session snapshot.
		this._wrapper.prepareLoopTeardown();
		// The close call escalates pending-work policy and may install a new
		// finite deadline while a close driver is already parked without a
		// timer; wake it so it re-reads the wait budget.
		this._wrapper.signalCloseActivity();
	}

	protected _closeState(): { readonly closed: boolean; readonly timedOut: boolean } {
		const out = new Uint8Array(4);
		const rc = loopS.glowcap_driver_lifecycle_state(this._h, ab(out));
		if (rc !== OK && rc !== TIMEOUT) checkDriver(rc);
		return {
			closed: lifecycleClosed(new DataView(out.buffer).getUint32(0, true)),
			timedOut: rc === TIMEOUT,
		};
	}

	/** Re-arm the loop's one clock from glowcap's complete pending-work
	 * deadline. No operation kind is interpreted here: deadline policy and
	 * arbitration stay FFI, while JavaScript owns only `setTimeout`. */
	protected _rearmProgressClock(): void {
		this._progressTimer = clearProgressClock(this._progressTimer);
		if (this._released || this._terminalFailure != null) return;
		this._progressTimer = armProgressClock(driverStepWaitMs(this._h), () => {
			this._progressTimer = null;
			try {
				this.stepNow();
			} catch (error) {
				this._failBackground(error);
			}
		});
	}

	/** Park a close driver until loop activity or the nearest pending-work
	 * deadline; with no finite deadline pending it parks on `activity` alone,
	 * because readiness wakes the park task, whose step signals activity. A
	 * grace expiry takes effect only inside a step, so the deadline half of
	 * this wait is what turns an expired grace into the escalating step. */
	protected async _waitStepWake(activity: Promise<void>): Promise<void> {
		await waitForProgressClock(activity, this._released ? 0 : driverStepWaitMs(this._h));
	}

	protected async _doClose(): Promise<void> {
		try {
			this._closeRequested = true;
			this._dispatchCommittedEvents();
			let timedOut = false;
			while (true) {
				// Arm before stepping (the lost-wakeup discipline): progress landing
				// after this line resolves the wait below, and progress landing
				// before it is visible to the lifecycle read that follows. A step
				// that ran work signals the armed waiter, so the wait returns at
				// once and the loop re-checks instead of parking over undrained
				// work.
				const activity = this._wrapper.armCloseActivity();
				this.stepNow();
				const state = this._closeState();
				timedOut ||= state.timedOut;
				if (state.closed) break;
				await this._waitStepWake(activity);
			}
			this._progressTimer = clearProgressClock(this._progressTimer);
			const wrapper = this._wrapper;
			this._parkStop = true;
			let wakeFailure: unknown | null = null;
			try {
				await loopS.glowcap_driver_wake(this._h);
			} catch (error) {
				// The bounded park still exits and must be joined before release;
				// retain the wake refusal and report it after that ownership barrier.
				wakeFailure = error;
			}
			if (this._parkExited != null) await this._parkExited;
			// The wrapper half first: its trace drain still reads the live handle.
			// Driver release below then frees loop, sessions, and host together.
			wrapper.prepareLoopTeardown();
			const handle = this._h;
			const releaseOutcome = driverCall(
				"driver-loop.close.release",
				(out) => loopS.glowcap_driver_release(handle, out),
			);
			const releaseResult = releaseOutcome.code;
			if (!releaseConsumed(releaseResult)) {
				this._failBackgroundWithRelease(
					releaseOutcome.error ?? new GlowcapError(releaseResult, "driver loop release was refused"),
					releaseOutcome,
				);
				throw this._terminalFailure;
			}
			retireDriverLoopFinalizer(this, this._finalizerState);
			this._h = NULL;
			this._released = true;
			this._runTeardownReleases();
			for (const listener of [...this._listeners]) {
				this._closingListeners.set(listener, loopClosedError());
				this._finishListenerClose(listener, loopClosedError());
			}
			await wrapper.finishLoopTeardown();
			if (releaseOutcome.error !== null) throw releaseOutcome.error;
			if (wakeFailure !== null) throw wakeFailure;
			if (timedOut) {
				throw new GlowcapError(TIMEOUT, "finish close exhausted its grace period");
			}
		} catch (error) {
			// Once released, only this close promise owns the teardown outcome.
			// Preserve its exact cause instead of classifying it as a drive failure.
			if (!this._released) this._failBackground(error);
			throw this._terminalFailure ?? error;
		}
	}

	/** Announce the embedder is serving `ptr`: post-open setup is done, so the
	 * loop may deliver inbound application frames (bytes that arrived early
	 * replay in order). Idempotent; the loop tier's spelling of the byte-fed
	 * rule that `serve()` resumes frames held behind the handshake. */
	serveSession(ptr: Ptr): void {
		if (this._terminalFailure != null) throw this._terminalFailure;
		if (this._released || ptr === NULL) return;
		// Serving releases application frames parked behind the handshake, and
		// may therefore invoke a hosted behavior before this call returns.
		const prior = enterDeliver(this._wrapper);
		try {
			checkDriver(loopS.glowcap_driver_session_serve(this._h, ptr));
		} finally {
			exitDeliver(prior);
		}
		this.scheduleStep();
	}

	/** Release one loop-owned session through the loop's own verb, which also
	 * drops queued events naming it. A no-op once the loop is released: the
	 * loop's release freed its sessions itself. */
	ffiSessionRelease(ptr: Ptr): void {
		if (this._released || ptr === NULL) {
			this._unclaimedSessions.delete(ptr);
			return;
		}
		checkDriver(loopS.glowcap_driver_session_release(this._h, ptr));
		this._unclaimedSessions.delete(ptr);
		// The release just recorded the session's terminal trace facts, and an
		// idle loop runs no next step to flush them; drain here so a close is
		// heard when it happens.
		traceDrainHost(this._wrapper.raw);
		// The final application-owned release is what lets a retiring loop reach
		// CLOSED; wake any parked close driver to re-read progress.
		this._wrapper.signalCloseActivity();
	}

	/** Resolve and claim the exporter session named by one Host capability. */
	claimReferenceExporter(reference: Uint8Array): Ptr | null {
		const out = new Uint8Array(8);
		checkDriver(loopS.glowcap_driver_claim_reference_exporter(this._h, ab(reference), ab(out)));
		const ptr = outPointer(out);
		return ptr === NULL ? null : ptr;
	}

	/** Close one loop-owned session under the shared FFI barrier, observing
	 * timeout before the public Session releases its opaque handle. */
	closeSession(ptr: Ptr, options: CloseOptions = {}): Promise<void> {
		if (this._terminalFailure != null) return Promise.reject(this._terminalFailure);
		if (this._released) return Promise.reject(loopClosedError());
		const encoded = encodeCloseOptions(options);
		let waiter = this._sessionCloses.get(ptr);
		const created = waiter == null;
		if (waiter == null) {
			let resolve!: () => void;
			let reject!: (error: GlowcapError) => void;
			const promise = new Promise<void>((ok, fail) => {
				resolve = ok;
				reject = fail;
			});
			waiter = { promise, resolve, reject };
			this._sessionCloses.set(ptr, waiter);
		}
		try {
			checkDriver(loopS.glowcap_driver_session_close(this._h, ptr, encoded));
		} catch (error) {
			if (!created) return Promise.reject(error);
			this._sessionCloses.delete(ptr);
			waiter.reject(error as GlowcapError);
			return waiter.promise;
		}
		// The close call escalates pending-work policy and may install a new
		// finite deadline while a close driver (this session's or the loop's)
		// is already parked; wake it so it re-reads the wait budget.
		this._wrapper.signalCloseActivity();
		this._finishSessionCloseIfClosed(ptr);
		if (created && this._sessionCloses.get(ptr) === waiter) {
			void this._driveSessionClose(ptr, waiter);
		}
		return waiter.promise;
	}

	/** The deadline-stepper behind one session's FFI close barrier: a grace
	 * expiry takes effect only inside a step, so this driver steps on every
	 * loop-activity or deadline wake until the session's lifecycle turns
	 * terminal. Escalating repeats of `closeSession` share it. */
	protected async _driveSessionClose(
		ptr: Ptr,
		waiter: {
			readonly promise: Promise<void>;
			readonly resolve: () => void;
			readonly reject: (error: GlowcapError) => void;
		},
	): Promise<void> {
		try {
			while (!this._released && this._sessionCloses.get(ptr) === waiter) {
				// Arm before stepping (the lost-wakeup discipline); loop-wide
				// activity or another owner's deadline waking this driver early
				// is harmless because it re-checks.
				const activity = this._wrapper.armCloseActivity();
				this.stepNow();
				this._finishSessionCloseIfClosed(ptr);
				if (this._sessionCloses.get(ptr) !== waiter) break;
				await this._waitStepWake(activity);
			}
		} catch (error) {
			if (this._sessionCloses.get(ptr) === waiter) {
				this._sessionCloses.delete(ptr);
				waiter.reject(error as GlowcapError);
			}
		}
	}

	protected _finishSessionCloseIfClosed(ptr: Ptr): void {
		const waiter = this._sessionCloses.get(ptr);
		if (waiter == null) return;
		const out = new Uint8Array(4);
		const rc = loopS.glowcap_driver_session_lifecycle_state(this._h, ptr, ab(out));
		if (rc !== OK && rc !== TIMEOUT) {
			this._sessionCloses.delete(ptr);
			waiter.reject(new GlowcapError(rc, driverLastError() ?? undefined));
			return;
		}
		if (!lifecycleClosed(new DataView(out.buffer).getUint32(0, true))) return;
		this._sessionCloses.delete(ptr);
		if (rc === TIMEOUT) waiter.reject(new GlowcapError(TIMEOUT, "finish close exhausted its grace period"));
		else waiter.resolve();
	}
}
