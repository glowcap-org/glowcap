// The CapTP host: multi-session CapTP product over the byte-fed host archive
// (libglowcap_host, ADR-0022). Goblins' `mycapn` is two roles: the product maps
// to this `Host`, the router tables map to `engine.Node` that the host owns, and never
// a single-type equation. The `GlowcapHost` owns every decision: the retained
// identity, live-session directory, routing, transparent three-party
// redemption, and the gifter half's origination. What lives here is only what
// the embedder contract leaves to the binding: the host handle, the
// session-pointer → `Session` registry the action drain routes by, the vow table
// the drain's SETTLE/FAIL arms settle, the serialized action drain itself,
// gift-id entropy, and explicitly installed byte-channel connectors. The
// action decode+execute switch lives in `action.ts`; the pump lives in
// `pump.ts`; the dial executor lives in `dial.ts`. `session.ts` owns the
// `Session` they act on. `mod.ts` re-exports the public `Host`.

import { OK, TIMEOUT } from "@glowcap/abi";
import { checkHost, FirstFailure, GlowcapError } from "../errors.ts";
import { hostS } from "../internal/ffi/host.ts";
import { NULL } from "../internal/ffi/runtime.ts";
import { ab } from "../internal/seam.ts";
import { type CloseOptions, encodeCloseOptions, lifecycleClosed, monotonicNowMs } from "../lifecycle.ts";
import { Session } from "../session.ts";
import { traceDetachHost, traceDrainHost } from "../trace.ts";
import { insideTurn } from "../trampoline.ts";
import { releaseHostState, retireHostFinalizerState, unregisterHostFinalizer } from "./finalizer.ts";
import { HostState } from "./state.ts";

// One encoder/decoder pair for the whole module: both are stateless here.

export abstract class HostLifecycle extends HostState {
	protected _closeWaitMs(): number {
		if (this._raw === NULL) return 0;
		const out = new Uint8Array(8);
		checkHost(hostS.glowcap_host_close_wait_ms(this._raw, monotonicNowMs(), ab(out)));
		const wait = new DataView(out.buffer).getBigInt64(0, true);
		if (wait < 0n) return -1;
		// setTimeout treats a delay past 2^31-1 as roughly one millisecond, so
		// cap it; the cap is safe because the driver re-checks progress on wake.
		return wait > 2_147_483_647n ? 2_147_483_647 : Number(wait);
	}

	/** Park a close driver until host activity or the nearest FFI FINISH
	 * grace deadline; with no finite deadline pending the driver parks on
	 * `activity` alone. Binding-internal: `_doClose` and the byte-fed session
	 * close drive wait through it. */
	async waitCloseWake(activity: Promise<void>): Promise<void> {
		const waitMs = this._closeWaitMs();
		if (waitMs < 0) {
			await activity;
			return;
		}
		let timer: ReturnType<typeof setTimeout> | undefined;
		const deadline = new Promise<void>((resolve) => {
			timer = setTimeout(resolve, waitMs);
		});
		try {
			await Promise.race([activity, deadline]);
		} finally {
			clearTimeout(timer);
		}
	}

	protected async _doClose(): Promise<void> {
		const raw = this._raw;
		if (raw === NULL) return;
		let timedOut = false;
		while (true) {
			// Arm before anything else in the iteration (the lost-wakeup
			// discipline): an advance landing after this line wakes the wait
			// below, and one landing before it is visible to the progress read.
			const activity = this.armCloseActivity();
			await this.kickActions();
			const state = new Uint8Array(4);
			const rc = hostS.glowcap_host_close_progress(raw, monotonicNowMs(), ab(state));
			if (rc !== OK && rc !== TIMEOUT) checkHost(rc);
			timedOut ||= rc === TIMEOUT;
			if (lifecycleClosed(new DataView(state.buffer).getUint32(0, true))) break;
			// A spent grace escalates inside the progress call and queues
			// teardown actions; drain them before parking. A drain that ran
			// work signals the armed waiter, so the wait below returns at once
			// and the loop re-checks instead of parking over undrained work.
			await this.kickActions();
			await this.waitCloseWake(activity);
		}
		// Writers finish the CLOSE passes the loop above queued, and a pass
		// that wrote schedules another drain.
		while (this._actionDrains.size !== 0 || this._sessionWriters.size !== 0) {
			await Promise.allSettled([...this._actionDrains, ...this._sessionWriters]);
		}
		// Whatever the ring still holds reaches the sink before the ring dies
		// with the host.
		traceDrainHost(raw);
		this.drainParkedReleases();
		const failures = new FirstFailure();
		if (timedOut) failures.add(new GlowcapError(TIMEOUT, "finish close exhausted its grace period"));
		if (this._finalizerState.raw === raw) {
			try {
				releaseHostState(this._finalizerState, true);
			} catch (error) {
				// A refusal preserves the live wrapper for an explicit retry.
				if (this._finalizerState.raw === raw) throw error;
				failures.add(error);
			}
		}
		const sessions = [...this._sessions.values()];
		this._sessions.clear();
		unregisterHostFinalizer(this);
		traceDetachHost(raw);
		this._gc.retire();
		this._raw = NULL;
		this._connectors.clear();
		this._behaviorEntries.clear();
		this._publications.clear();
		this.hosted.clear();
		this.clearVowRows();
		try {
			// Publish the consumed owner before session retirement calls user code.
			await this._joinSessionRetirements(sessions);
		} catch (error) {
			failures.add(error);
		}
		failures.throwIfAny();
	}

	/** Retire every channel the consumed FFI owner made unreachable. The
	 * existing retained failure stays primary; collect retirement and task
	 * failures without short-circuiting wrapper retirement. */
	protected async _joinSessionRetirements(sessions: readonly Session[]): Promise<void> {
		const failures = new FirstFailure();
		const retained = this._takeBackgroundFailure();
		if (retained !== null) failures.add(retained.error);
		// Claim the return directly as well as the Host registry. The registry is
		// what preserves a session that unregistered before this snapshot; the
		// return is the local authority for every session still present in it.
		for (const session of sessions) {
			this._sessionRetirements.add(session.ffiOwnerDidRelease());
		}
		while (this._sessionRetirements.size !== 0) {
			const batch = [...this._sessionRetirements];
			const outcomes = await Promise.allSettled(batch);
			for (const retirement of batch) this._sessionRetirements.delete(retirement);
			failures.addRejections(outcomes);
		}
		// Retirement notifications and task completions can retain another
		// failure after the final live drain. Close is their surviving caller.
		const background = this._takeBackgroundFailure();
		if (background !== null) failures.add(background.error);
		failures.throwIfAny();
	}

	protected async _joinActionDrains(): Promise<void> {
		while (this._actionDrains.size !== 0) {
			await Promise.allSettled([...this._actionDrains]);
		}
	}

	/** Request terminal teardown and wait until every action drain, dial, and
	 * admission worker has stopped before the FFI Host is released. */
	close(options: CloseOptions = {}): Promise<void> {
		const encoded = encodeCloseOptions(options);
		if (this._driverLoop != null) {
			return this._driverLoop.close(options);
		}
		if (this._releasePromise == null && this._raw !== NULL) {
			this._releaseStarted = true;
			checkHost(hostS.glowcap_host_close(this._raw, ab(encoded), monotonicNowMs()));
			this.signalCloseActivity();
			const begin = () => this._doClose();
			this._releasePromise = insideTurn() ? Promise.resolve().then(begin) : begin();
			void this._releasePromise.catch(() => {});
		} else if (this._raw !== NULL) {
			// A repeated close escalates the pending-work policy while the close
			// driver may already be parked; wake it so it re-reads progress.
			checkHost(hostS.glowcap_host_close(this._raw, ab(encoded), monotonicNowMs()));
			this.signalCloseActivity();
			return this._releasePromise ?? Promise.resolve();
		}
		return this._releasePromise ?? Promise.resolve();
	}

	/** Claim terminal-close outcomes and drain tracing while the FFI Host is
	 * readable. Repeat before driver release to flush later trace entries.
	 * Irreversible cleanup waits for `finishLoopTeardown` after release. */
	prepareLoopTeardown(): void {
		if (this._raw === NULL) return;
		this._releaseStarted = true;
		traceDrainHost(this._raw);
	}

	/** Commit wrapper teardown after the driver released its Host, joining every
	 * loop channel's terminal promise before the driver's close barrier settles. */
	async finishLoopTeardown(): Promise<void> {
		if (this._raw === NULL) return;
		const raw = this._raw;
		traceDetachHost(raw);
		const sessions = [...this._sessions.values()];
		this._sessions.clear();
		retireHostFinalizerState(this._finalizerState);
		this.clearVowRows();
		this._gc.retire();
		this._raw = NULL;
		this._behaviorEntries.clear();
		this._publications.clear();
		this._connectors.clear();
		this.hosted.clear();
		await this._joinSessionRetirements(sessions);
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.close();
	}
}
