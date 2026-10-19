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

import { CLOSED } from "@glowcap/abi";
import { parkActions, runAction } from "../action.ts";
import { GlowcapError, retainSecondaryFailure } from "../errors.ts";
import { drainFinalizerRetries } from "../finalizer_retry.ts";
import { NULL } from "../internal/ffi/runtime.ts";
import { traceDrainHost } from "../trace.ts";
import { enterDeliver, exitDeliver, insideTurn } from "../trampoline.ts";
import { type Argument, Ref } from "../value.ts";
import { HostApplication } from "./application.ts";
import { MAX_UNOBSERVED_OUTCOMES } from "./state.ts";

async function yieldToRuntime(): Promise<void> {
	const scheduler = (globalThis as {
		scheduler?: { yield?: () => Promise<void> };
	}).scheduler;
	if (scheduler?.yield != null) return scheduler.yield();

	await new Promise<void>((resolve) => {
		const channel = new MessageChannel();
		channel.port1.onmessage = () => {
			channel.port1.close();
			channel.port2.close();
			resolve();
		};
		channel.port2.postMessage(undefined);
	});
}

export abstract class HostDrive extends HostApplication {
	// ── The vow table ──────────────────────────────────────────────────────────

	/** Reject every pending vow with one loop failure before loop teardown
	 * clears the table. A later observation receives the same failure. */
	failPendingVows(error: GlowcapError): void {
		if (this._terminalVowFailure == null) this._terminalVowFailure = error;
		for (const row of this._vows.values()) {
			if (row.state.tag === "awaited") row.state.waiter.reject(error);
		}
		this.clearVowRows();
	}

	/** Record a freshly minted vow so the drain can route its completion. Must
	 * run in the same synchronous block as the minting FFI call, so no drain
	 * can pop the completion first. Binding-internal. */
	vowMinted(vow: bigint, trackGc = false): void {
		this._vows.set(vow, { state: { tag: "minted" }, trackGc });
	}

	/** The vow's eventual outcome: the fulfilled wire value, or a rejection:
	 * `VowBroken` for a partner break, the typed CLOSED `GlowcapError` when the
	 * settle was the disconnect's own break. Settles immediately from the
	 * recorded state when the outcome already landed. Binding-internal. */
	awaitVow(vow: bigint): Promise<Argument> {
		const row = this._vows.get(vow);
		if (row === undefined) {
			if (this._terminalVowFailure != null) {
				return Promise.reject(this._terminalVowFailure);
			}
			// Evicted (never awaited until past the cap) or never minted here.
			return Promise.reject(
				new GlowcapError(CLOSED, "the vow's outcome is gone (unobserved past the cap)"),
			);
		}
		if (row.state.tag !== "settled") {
			// Minted or re-awaited: (re)park a waiter. A prior awaited waiter is
			// replaced here.
			return new Promise<Argument>((resolve, reject) => {
				row.state = { tag: "awaited", waiter: { resolve, reject } };
			});
		}
		this._vows.delete(vow);
		const outcome = row.state.outcome;
		return "ok" in outcome ? Promise.resolve(outcome.ok) : Promise.reject(outcome.err);
	}

	/** The drain's settle arms: fire the waiter, or record the outcome for a
	 * late observation (bounded FIFO: an outcome nobody ever awaits is evicted
	 * at the cap). Binding-internal: `action.ts` calls it. */
	settleVow(vow: bigint, outcome: { ok: Argument } | { err: GlowcapError }): void {
		const row = this._vows.get(vow);
		if (row === undefined) return; // an outcome nobody registered for
		if (row.trackGc && "ok" in outcome) this._gc.trackArgument(outcome.ok);
		if (row.state.tag === "awaited") {
			const waiter = row.state.waiter;
			this._vows.delete(vow);
			if ("ok" in outcome) waiter.resolve(outcome.ok);
			else waiter.reject(outcome.err);
			return;
		}
		// Minted, or an already-settled row re-settled: hold for a late observation.
		row.state = { tag: "settled", outcome };
		this._unobserved.push(vow);
		while (this._unobserved.length - this._unobservedHead > MAX_UNOBSERVED_OUTCOMES) {
			const oldest = this._unobserved[this._unobservedHead++]!;
			const stale = this._vows.get(oldest);
			// Only evict a row still parked unobserved; an observed one is gone.
			if (stale !== undefined && stale.state.tag === "settled") {
				this._vows.delete(oldest);
			}
		}
		if (this._unobservedHead !== 0 && this._unobservedHead === this._unobserved.length) {
			this._unobserved.length = 0;
			this._unobservedHead = 0;
		} else if (this._unobservedHead >= MAX_UNOBSERVED_OUTCOMES) {
			this._unobserved.splice(0, this._unobservedHead);
			this._unobservedHead = 0;
		}
	}

	/** Drop completion state after the last public promise wrapper dies. */
	abandonVow(vow: bigint): void {
		this._vows.delete(vow);
	}

	// ── The action drain (the one loop rule) ──────────────────────────────────

	/** Park a C release the host refused inside a behavior callback; the next
	 * drain (the head of `kickActions`, or the feed's unwind) runs it where
	 * it is legal. Binding-internal. */
	parkRelease(release: () => void): void {
		this._parkedReleases.push(release);
	}

	/** Track every newly projected capability occurrence in an application
	 * value. Binding-internal; Session decides whether its opt-in applies. */
	trackGcArgument(value: Argument): Argument {
		return this._gc.trackArgument(value);
	}

	trackVow(handle: object, vow: bigint): void {
		this._gc.trackVow(handle, vow);
	}

	parkVowRelease(vow: bigint): void {
		this._gc.parkVow(vow);
	}

	drainGc(): void {
		if (this._backgroundFailure !== null) {
			const failure = this._backgroundFailure;
			this._backgroundFailure = null;
			throw failure;
		}
		this._gc.drainGc();
	}

	/** Retain the first failure from a callerless runtime task. Binding-internal. */
	recordBackgroundFailure(failure: unknown): void {
		if (this._backgroundFailure === null) this._backgroundFailure = failure;
		else this._backgroundFailure = retainSecondaryFailure(this._backgroundFailure, failure);
		this.signalCloseActivity();
	}

	disarmGc(ref: Ref): void {
		this._gc.disarm(ref);
	}

	/** Run every parked release, always outside a callback frame where the C
	 * tier accepts them. Called at the head of `kickActions` and right after a
	 * feed returns. Binding-internal. */
	drainParkedReleases(): void {
		if (insideTurn()) return;
		drainFinalizerRetries();
		const ranAny = this._parkedReleases.length > 0;
		while (this._parkedReleases.length > 0) {
			const pending = this._parkedReleases.splice(0);
			for (const release of pending) release();
		}
		// A parked release retires an FFI session or Host handle, which is
		// close-relevant state; wake any parked close driver to re-check.
		if (ranAny) this.signalCloseActivity();
	}

	/** How many releases are parked on this host. It is test observability for the
	 * mid-turn close park. Binding-internal. */
	pendingReleaseCount(): number {
		return this._parkedReleases.length;
	}

	/** Pop and honor every pending embedder action. Reentrant on purpose: DIAL
	 * starts its connection task without awaiting establishment, and that task's
	 * start-session FLUSH re-enters this drain independently. Actions are
	 * popped and decoded first (`parkActions` over `glowcap_host_next_action`,
	 * each copied out before the next pop frees its views) and awaited after
	 * the pops, so async I/O never runs while a borrowed view is live.
	 * Re-parks until empty: a NEED_GIFT_ID's `provide_gift_id` can queue FLUSH
	 * legs after a full pop round (same as Racket's `drain-host-actions!`). A
	 * no-op inside a hosted turn: the host refuses the driving verbs there,
	 * and everything the turn enqueued pumps when the enclosing feed unwinds
	 * into this same drain. Binding-internal. */
	kickActions(): Promise<void> {
		if (this._driverLoop != null) {
			// The driver loop is the one drain on an adopted Host (ADR-0024):
			// the kick becomes a scheduled loop step, which runs the parked
			// releases and the GC drain at its own head. Inside a turn it must
			// defer past the enclosing feed; outside one, join that deferred step
			// so verbs whose contract includes a flush do not return early.
			if (insideTurn()) {
				this._driverLoop.scheduleStep();
				return Promise.resolve();
			}
			this.drainParkedReleases();
			return this._driverLoop.settleStep();
		}
		if (insideTurn()) return Promise.resolve();
		// Parked releases run first, before the raw-handle check, because a
		// mid-turn Host.close cleared `_raw` while parking the actual free.
		this.drainParkedReleases();
		if (this._raw === NULL) return Promise.resolve();

		// Register before execution starts. A drain can synchronously cause Host
		// teardown through an action it runs; deferring its body to a microtask
		// closes the admission window before that body can make progress.
		const drain = Promise.resolve().then(() => this._drainActions());
		this._actionDrains.add(drain);
		const retire = () => {
			this._actionDrains.delete(drain);
		};
		void drain.then(retire, retire);
		return drain;
	}

	/** Schedule an unowned action drain and retain its first exact failure. */
	scheduleKick(): void {
		void this.kickActions().catch((error) => this.recordBackgroundFailure(error));
	}

	/** Drain newly queued effects and join every drain already admitted before
	 * returning. Session transport teardown uses this barrier before releasing
	 * its wrapper: another drain may have popped that session's CLOSE action
	 * and be awaiting its flush, so waiting only the caller's fresh drain would
	 * release the session underneath the real owner of the terminal effect. */
	async settleActions(): Promise<void> {
		await this.kickActions();
		await this._joinActionDrains();
	}

	protected async _drainActions(): Promise<void> {
		// A publication schedules this byte-fed drain as a microtask. Listener
		// adoption can transfer the still-quiescent Host before that microtask
		// starts; all unpopped work transfers with it, so the stale owner must
		// stand down instead of calling next_action on a driver-owned Host.
		if (this._raw === NULL || this._driverLoop != null) return;
		// The live trace's capture ring drains on the same unwind as the action
		// queue: both are host effects the embedder pops, and popping them
		// together is what keeps a queued fact from waiting on the next verb.
		traceDrainHost(this._raw);
		while (true) {
			if (this._raw === NULL || this._driverLoop != null) return;
			// The FFI drain resumes queued Host work before it pops the first
			// external action. That work may deliver to a hosted behavior, so the
			// synchronous drain call is a Host-carried delivery just like a loop step.
			const prior = enterDeliver(this);
			let parked: ReturnType<typeof parkActions>;
			try {
				parked = parkActions(this);
			} finally {
				exitDeliver(prior);
			}
			const { actions, yielded } = parked;
			if (actions.length === 0 && !yielded) return;
			let firstFailure: { error: unknown } | null = null;
			for (const action of actions) {
				if (this._raw === NULL) return;
				// One failing action must not strand the rest of the drain: a
				// FLUSH to a session whose socket just died throws here while
				// the actions behind it belong to other, live sessions. The
				// failed session tears itself down through its own serve loop
				// (a DIAL failure is reported to the core inside the arm).
				try {
					await runAction(this, action);
				} catch (error) {
					// Finish this already-popped batch, then report its first
					// refusal through the kick promise the caller observes.
					if (firstFailure === null) firstFailure = { error };
				}
			}
			// A drained batch may have advanced close-relevant state (FLUSH,
			// CLOSE, SETTLE, dial retirement); wake any parked close driver.
			// Signaling only when work ran keeps a close driver's own no-op
			// kicks from waking the waiter it just armed.
			if (actions.length > 0) this.signalCloseActivity();
			if (firstFailure !== null) throw firstFailure.error;
			if (yielded) {
				if (this._raw === NULL) return;
				await yieldToRuntime();
			}
		}
	}
}
