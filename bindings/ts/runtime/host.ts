// The CapTP host — multi-session CapTP product over the byte-fed host archive
// (libpancake_host, ADR-0072). Goblins' `mycapn` is two roles: the product maps
// to this `Host`, the router tables map to `engine.Node` that the host owns — never
// a single-type equation. The `PancakeHost` owns every decision: the retained
// identity, live-session directory, routing, transparent three-party
// redemption, and the gifter half's origination. What lives here is only what
// the embedder contract leaves to the binding: the host handle, the
// session-pointer → `Session` registry the action drain routes by, the vow table
// the drain's SETTLE/FAIL arms settle, the serialized action drain itself,
// gift-id entropy, and explicitly installed byte-channel connectors. The
// action decode+execute switch lives in `action.ts`; the pump lives in
// `pump.ts`; the dial executor lives in `dial.ts`. `session.ts` owns the
// `Session` they act on. `mod.ts` re-exports the public `Host`.

import { hostS } from "./internal/ffi/host.ts";
import { NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outPointer, outU64 } from "./internal/seam.ts";
import {
	CLOSED,
	DEFAULT_FRAME_CAP,
	HOST_DURABLE_ENTROPY_LEN,
	HOST_DURABLE_SWISS_LEN,
	INTERNAL,
	INVALID_ARGUMENT,
	NOT_FOUND,
	OK,
	TIMEOUT,
} from "@pancake/abi";
import { checkHost, hostLastError, PancakeError, retainSecondaryFailure } from "./errors.ts";
import { traceAttachHost, traceDetachHost, traceDrainHost } from "./trace.ts";
import {
	type Argument,
	type Behavior,
	type CaptpVersion,
	captpVersionId,
	type Codec,
	codecId,
	featureMask,
	type FeatureSet,
	Ref,
} from "./value.ts";
import { encodeArgs, refStruct } from "./abi_value.ts";
import {
	type BehaviorEntry,
	insideTurn,
	registerBehavior,
	trampolinePointer,
	unregisterBehavior,
} from "./trampoline.ts";
import { Context, type FailureEvent, recordCallerlessFailure, releaseContext, retainContext } from "./context.ts";
import { type DriverLoopHandle, Session } from "./session.ts";
import { asLiveRef } from "./promise.ts";
import { parkActions, runAction } from "./action.ts";
import { HostGc } from "./gc.ts";
import { type Locator, withOwnedLocator } from "./locator.ts";
import type { Connector } from "./transport.ts";
import {
	type CloseOptions,
	encodeCloseOptions,
	lifecycleClosed,
	monotonicNowMs,
	releaseConsumed,
} from "./lifecycle.ts";

// One encoder/decoder pair for the whole module: both are stateless here.
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

export const DURABLE_SWISS_ENTROPY_BYTES = HOST_DURABLE_ENTROPY_LEN;

export interface HostFinalizerState {
	raw: Ptr;
	/** Stable identity in the retained Context's diagnostic namespace. */
	diagnosticId: bigint;
	/** Every process-global trampoline row owned by this Host. Bigints only:
	 * the held state must never retain the Host wrapper or a behavior closure. */
	behaviorIds: Set<bigint>;
	/** Keep a caller-supplied allocation scope alive until native Host release.
	 * The Context does not retain this Host, so this cannot create a cycle. */
	context: Context | null;
}

// A refused finalizer release has no caller, so report it through the retained
// Context. Keep the native allocation policy alive rather than freeing it
// under the still-live Host.
const refusedHostFinalizers = new Set<HostFinalizerState>();

function releaseHostState(state: HostFinalizerState, checked = false): void {
	if (state.raw === NULL) return;
	const raw = state.raw;
	const rc = hostS.pancake_host_release(raw);
	if (rc !== OK) {
		// Capture the archive-local diagnostic before reporting can overwrite it.
		const failure = new PancakeError(rc, hostLastError() ?? `native Host release failed (code ${rc})`);
		const consumed = releaseConsumed(rc);
		if (!checked && state.context != null) {
			recordCallerlessFailure(state.context, {
				layer: "binding",
				scope: "host",
				scopeId: state.diagnosticId,
				operation: "host.finalizer.release",
				primaryName: consumed ? "HostReleaseFailed" : "HostReleaseRefused",
				primaryResult: rc,
				primaryMessage: failure.detail ?? failure.message,
			});
		}
		// INVALID_ARGUMENT is the only pre-consumption refusal. Every other
		// result is the outcome of a completed native teardown, so retaining its
		// raw pointer would turn an exact cleanup failure into a dangling handle.
		if (consumed) retireHostFinalizerState(state);
		else refusedHostFinalizers.add(state);
		if (checked) throw failure;
		return;
	}
	retireHostFinalizerState(state);
}

/** Retire wrapper-owned state after a driver has already released the native Host. */
export function retireHostFinalizerState(state: HostFinalizerState): void {
	state.raw = NULL;
	for (const ctx of state.behaviorIds) unregisterBehavior(ctx);
	state.behaviorIds.clear();
	const context = state.context;
	state.context = null;
	if (context != null) releaseContext(context);
}

class HostedBehaviorMap extends Map<bigint, bigint> {
	constructor(readonly behaviorIds: Set<bigint>) {
		super();
	}

	override set(refId: bigint, ctx: bigint): this {
		this.behaviorIds.add(ctx);
		return super.set(refId, ctx);
	}
}

// Release everything whose authority survives the wrapper. Mid-turn releases
// park on the live Host instead; this path runs only after the wrapper is gone.
const hostFinalizer = new FinalizationRegistry<HostFinalizerState>((state) => {
	traceDrainHost(state.raw);
	traceDetachHost(state.raw);
	releaseHostState(state);
});

// A host vow's pending state: exactly three shapes, so the illegal "settled AND
// a live waiter" combination cannot be represented. Minted the instant the vow
// is registered (the mint IS the registration); an outcome that lands before
// anyone awaits is held as `settled` for a late observation instead of hanging;
// a waiter lives only in `awaited`, so an unobserved broken answer never raises
// an unhandled rejection.
type VowState =
	| { tag: "minted" }
	| {
		tag: "awaited";
		waiter: { resolve: (v: Argument) => void; reject: (e: PancakeError) => void };
	}
	| { tag: "settled"; outcome: { ok: Argument } | { err: PancakeError } };

interface VowRow {
	state: VowState;
	trackGc: boolean;
}

/** Cap on stored outcomes whose vow is never awaited, so the store cannot grow
 * without bound; the oldest un-awaited outcome is evicted at the cap. */
const MAX_UNOBSERVED_OUTCOMES = 1024;

export interface HostOptions {
	codec?: Codec;
	captpVersion?: CaptpVersion;
	features?: FeatureSet;
	context?: Context;
	frameCap?: number;
	localTurnBudget?: number;
}

/** The CapTP host: one identity, one session directory, one routing and redeem
 * authority, shared by every session minted against it. Owns `engine.Node`
 * (the sans-io handoff router). The cross-host machinery lives in the Zig
 * core behind `libpancake_host` (ADR-0072); this is the host-idiom residue
 * over it — the `Session` registry, the vow table, the serialized action
 * drain that performs the I/O the host asks for (dial, flush, settle,
 * entropy), and explicitly installed byte-channel connectors. */

export class Host {
	readonly #context: Context;
	readonly #diagnosticId: bigint;
	/** The host's retained durable identity seed. Each read returns a copy. */
	readonly #seed: Uint8Array;
	/** The wire grammar every session this host mints negotiates in. */
	readonly codec: Codec;
	readonly captpVersion: CaptpVersion;
	readonly features: FeatureSet;
	#raw: Ptr;
	// Set before trace draining because a sink may recursively release this Host.
	#releaseStarted = false;
	#releasePromise: Promise<void> | null = null;
	readonly #finalizerState: HostFinalizerState;
	/** Host-owned finalizer registry and release queue. */
	readonly #gc: HostGc;
	// Every live session by its PancakeHostSession address, so a FLUSH action
	// routes to the transport that owns the bytes, a dialed exporter stays
	// reachable for teardown, and `exporterFor` maps a redeemed reply's route
	// (a PancakeHostSession pointer) back to its `Session` wrapper.
	readonly #sessions = new Map<Ptr, Session>();
	// Physical channel closes can outlive the native Session pointer that
	// initiated them. Keep their promises at the Host barrier after the wrapper
	// unregisters, so Host close cannot lose a late transport refusal.
	readonly #sessionRetirements = new Set<Promise<void>>();
	// The vow table the drain's SETTLE/FAIL arms settle.
	readonly #vows = new Map<bigint, VowRow>();
	// A loop drive failure outlives table teardown so promises observed after
	// the loop failed receive the original cause rather than a generic close.
	#terminalVowFailure: PancakeError | null = null;
	// The first failure from work deliberately detached from its immediate
	// caller. The next verb head consumes the exact cause before doing more work.
	#backgroundFailure: unknown | null = null;
	// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	readonly #unobserved: bigint[] = [];
	// DIAL actions are asynchronous after the C queue has consumed them. Retain
	// their executors until they report a terminal result; otherwise a detached
	// promise can disappear while its ticket and half-open channel remain live.
	readonly #dialTasks = new Map<bigint, {
		readonly controller: AbortController;
		readonly promise: Promise<void>;
	}>();
	// Action drains may await transport I/O after popping native actions. Keep
	// every admitted drain under Host teardown so none can resume after native
	// Host storage is released.
	readonly #actionDrains = new Set<Promise<void>>();
	// Explicit embedder-owned byte-channel authority, retained by transport so
	// a later handoff redeem uses the same application-selected integration.
	readonly #connectors = new Map<string, Connector>();
	// Releases the C tier refused inside a behavior callback park here
	// (`pancake_host_session_release` / `pancake_host_release` are refused
	// mid-turn); the drain runs them once the enclosing feed unwinds, so a
	// mid-turn close never leaks its C handle. Mirrors Python/Rust.
	readonly #parkedReleases: Array<() => void> = [];
	// Trampoline ctx ids of this host's giftables, by published name. The registry
	// is process-global, not host-scoped, so nothing drops these when the host dies
	// — `release()` frees them, or they leak one row per giftable per Host
	// generation. Keyed by name so `Session.publishedRef` can find the ctx.
	readonly #giftables = new Map<string, bigint>();
	// Every Session.spawn/publish trampoline on this Host. Actors live in the
	// Host Vat and remain callable through sibling Ports after the Port that
	// first projected them closes.
	readonly hosted: Map<bigint, bigint>;
	// Strong ownership behind the weak process-global trampoline lookup. This
	// may contain a behavior that captures this Host; that cycle is local and
	// therefore collectable.
	readonly #behaviorEntries = new Map<bigint, BehaviorEntry>();
	// Ctx ids a re-publish displaced. Existing capabilities and gifts still reach
	// the old Host-Vat actor, so its behavior stays registered until `release()`.
	readonly #displacedGiftables: bigint[] = [];
	// The native loop that owns this Host's handle, when this wrapper was
	// adopted over a loop's host (ADR-0112). In that mode the C loop is the
	// action drain — the kick verbs nudge a loop step instead of running the
	// binding drain — and release belongs to `DriverLoop.close`.
	#driverLoop: DriverLoopHandle | null = null;
	// The shared close-activity notifier (wake-all): a close driver arms it
	// before reading native close progress, and every native verb that can
	// advance close-relevant state resolves it after the verb returns. Null
	// while no arm is outstanding.
	#closeActivity: { promise: Promise<void>; resolve: () => void } | null = null;

	/** A host with identity `seed` (32 bytes; omitted draws a fresh random one —
	 * entropy at the binding boundary, never inside the sans-io host). `codec`,
	 * `captpVersion`, and `features` are this Host's signed profile offer;
	 * each session settles version and codec with its partner, falling back to
	 * v1.0/Syrup when needed, and runs only the intersection of the two offered
	 * feature sets. Omitted `features` means the full feature set. `context`
	 * routes every byte the host owns through a caller-supplied allocation scope;
	 * `localTurnBudget` is `0` for unbounded (the default) or a nonzero cap on
	 * local-turn amplification per drive (ADR-0076). */
	constructor(
		seed?: Uint8Array,
		opts: HostOptions = {},
	) {
		if (seed != null && seed.length !== 32) {
			throw new PancakeError(INVALID_ARGUMENT, "Host: seed must be 32 bytes");
		}
		const durableSeed = seed ?? crypto.getRandomValues(new Uint8Array(32));
		// Keep the binding's own copy: callers can reuse or mutate their input
		// without changing the identity native Host already retained.
		this.#seed = new Uint8Array(durableSeed);
		this.codec = opts.codec ?? "syrup";
		this.captpVersion = opts.captpVersion ?? "v1_0";
		this.features = opts.features ?? "full";
		const frameCap = opts.frameCap ?? DEFAULT_FRAME_CAP;
		if (!Number.isSafeInteger(frameCap) || frameCap <= 0) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				"Host: frameCap must be a positive safe integer",
			);
		}
		// The durable identity followed by a session-key root drawn here, at
		// this binding's entropy boundary, because the library draws none
		// (ADR-0097). The root is fresh per process, so every CapTP session
		// signs with its own key and a restart cannot recreate a prior
		// session's handoff names; the durable half stays exactly `seed`,
		// since a keyed locator's designator derives from it.
		const seedWithRoot = new Uint8Array(64);
		seedWithRoot.set(this.#seed, 0);
		crypto.getRandomValues(seedWithRoot.subarray(32));
		const out = new Uint8Array(8);
		const localTurnBudget = opts.localTurnBudget ?? 0;
		const context = opts.context ?? Context.create();
		this.#context = context;
		const contextRaw = retainContext(context);
		try {
			checkHost(hostS.pancake_host_new_in(
				contextRaw,
				ab(seedWithRoot),
				64n,
				BigInt(frameCap),
				1,
				codecId(this.codec),
				captpVersionId(this.captpVersion),
				featureMask(this.features),
				localTurnBudget,
				ab(out),
			));
		} catch (err) {
			releaseContext(context);
			throw err;
		}
		this.#raw = outPointer(out);
		const diagnosticOut = new Uint8Array(8);
		try {
			checkHost(hostS.pancake_host_diagnostic_id(this.#raw, ab(diagnosticOut)));
		} catch (err) {
			const cleanupState: HostFinalizerState = {
				raw: this.#raw,
				diagnosticId: 0n,
				behaviorIds: new Set(),
				context,
			};
			try {
				releaseHostState(cleanupState, true);
			} catch (cleanup) {
				this.#raw = NULL;
				throw retainSecondaryFailure(err, cleanup);
			}
			this.#raw = NULL;
			throw err;
		}
		this.#diagnosticId = outU64(diagnosticOut);
		this.#finalizerState = {
			raw: this.#raw,
			diagnosticId: this.#diagnosticId,
			behaviorIds: new Set(),
			context,
		};
		this.hosted = new HostedBehaviorMap(this.#finalizerState.behaviorIds);
		hostFinalizer.register(this, this.#finalizerState, this);
		try {
			// The host's own key designator, which is what a partner names it by:
			// the live trace reports it as this host's endpoint so one peer stays
			// one node in a feed several producers share.
			traceAttachHost(this.#raw, this.designator(), this.#context, this.#diagnosticId);
			this.#gc = new HostGc();
			// deno-lint-ignore no-this-alias -- GcHandle object closes over Host fields
			const host = this;
			this.#gc.bind({
				get released() {
					return host.#raw === NULL;
				},
				get hostRaw() {
					return host.#raw;
				},
				kick: () => {
					host.scheduleKick();
				},
				recordFailure: (failure) => host.recordBackgroundFailure(failure),
				scheduleDrain: (run) => setTimeout(run, 0),
			});
		} catch (err) {
			hostFinalizer.unregister(this);
			traceDetachHost(this.#raw);
			try {
				releaseHostState(this.#finalizerState, true);
			} catch (cleanup) {
				this.#raw = NULL;
				throw retainSecondaryFailure(err, cleanup);
			}
			this.#raw = NULL;
			throw err;
		}
	}

	/** Return a defensive copy of the durable identity seed. */
	get seed(): Uint8Array {
		return new Uint8Array(this.#seed);
	}

	/** The raw PancakeHost handle. Binding-internal: `Session` mints and
	 * drives sessions against it. */
	get raw(): Ptr {
		if (this.#raw === NULL) throw new PancakeError(CLOSED, "host released");
		return this.#raw;
	}

	/** Whether terminal Host teardown has invalidated the native handle. */
	get released(): boolean {
		return this.#raw === NULL;
	}

	/** Claim callerless failures retained by this Host's Context. */
	takeFailures(): FailureEvent[] {
		return this.#context.takeFailures();
	}

	/** Retain an application callback failure that has no return recipient.
	 * Binding-internal: returned failures must stay on their ordinary path. */
	recordCallerlessFailure(operation: string, error: unknown): void {
		recordCallerlessFailure(this.#context, {
			layer: "application-observer",
			scope: "host",
			scopeId: this.#diagnosticId,
			operation,
			primaryName: error instanceof Error ? error.name : "ThrownValue",
			primaryResult: INTERNAL,
			primaryMessage: error instanceof Error ? error.message : String(error),
		});
	}

	/** Retain a binding-owned rollback failure after its initiating call already
	 * returned another primary. Binding-internal. */
	recordCallerlessBindingFailure(operation: string, error: unknown): void {
		recordCallerlessFailure(this.#context, {
			layer: "binding",
			scope: "host",
			scopeId: this.#diagnosticId,
			operation,
			primaryName: error instanceof Error ? error.name : "ThrownValue",
			primaryResult: INTERNAL,
			primaryMessage: error instanceof Error ? error.message : String(error),
		});
	}

	/** The native loop that owns this Host, or null for a byte-fed Host.
	 * Binding-internal: the dial executor routes a dial on a loop-owned Host
	 * onto that same loop (ADR-0112). */
	get driverLoop(): DriverLoopHandle | null {
		return this.#driverLoop;
	}

	/** Refuse operations only after the native handle has been invalidated. */
	assertHandle(): void {
		if (this.#raw === NULL) {
			throw new PancakeError(CLOSED, "Host is closed");
		}
	}

	/** Transfer native ownership to a DriverLoop after its ABI claim succeeds.
	 * The wrapper remains the sole JavaScript Host authority; only the loop may
	 * release the native handle after this point. Binding-internal. */
	attachDriverLoop(driverLoop: DriverLoopHandle): HostFinalizerState {
		if (this.#raw === NULL || this.#releaseStarted || this.#driverLoop != null) {
			throw new PancakeError(INVALID_ARGUMENT, "host is not transferable");
		}
		hostFinalizer.unregister(this);
		this.#driverLoop = driverLoop;
		return this.#finalizerState;
	}

	/** Run one popped DIAL executor under this Host's terminal lifetime. The
	 * signal owns transport cancellation; retention alone is not ownership. */
	startDialTask(ticket: bigint, run: (signal: AbortSignal) => Promise<void>): void {
		if (this.#raw === NULL) return;
		const controller = new AbortController();
		// Defer invocation until after the task is registered. A callback that
		// synchronously releases this Host can therefore never create untracked
		// work between `run` entering and the map insertion below.
		const retained = Promise.resolve().then(() => {
			if (controller.signal.aborted) return;
			return run(controller.signal);
		}).catch((error) => this.recordBackgroundFailure(error))
			.finally(() => {
				if (this.#dialTasks.get(ticket)?.promise === retained) this.#dialTasks.delete(ticket);
			});
		this.#dialTasks.set(ticket, { controller, promise: retained });
	}

	/** Execute one core-issued dial cancellation and acknowledge physical
	 * retirement only after its task can no longer touch the Host. */
	async cancelDialTask(ticket: bigint): Promise<void> {
		const task = this.#dialTasks.get(ticket);
		if (task != null) {
			task.controller.abort();
			await task.promise;
		}
		if (this.#raw !== NULL) {
			checkHost(hostS.pancake_host_dial_cancelled(this.#raw, ticket));
			// Retiring a pending dial is close-relevant pending work.
			this.signalCloseActivity();
		}
	}

	/** Binding-internal (the trampoline's async-behavior arm): defer `turn`'s
	 * answer onto a fresh resolver vow and settle it when `pending` does
	 * (ADR-0102). The settle re-enters on the runtime's microtask queue — the
	 * top-level re-entry the host requires — and carries plain data only: a
	 * value the settle refuses (a capability, per the off-turn contract)
	 * breaks the answer with the refusal's reason instead of stranding it.
	 * False when the deferral itself refused; the caller breaks the turn. */
	deferTurnToPromise(turn: Ptr, pending: PromiseLike<Argument | void>): boolean {
		const resolverOut = new Uint8Array(8);
		if (hostS.pancake_host_turn_defer(turn, ab(resolverOut)) !== OK) return false;
		const resolver = outU64(resolverOut);
		void Promise.resolve(pending).then(
			(value) => this.#settleResolver(resolver, value === undefined ? null : value),
			(err) => this.#breakResolver(resolver, err instanceof Error ? err.message : String(err)),
		);
		return true;
	}

	#settleResolver(resolver: bigint, value: Argument): void {
		if (this.#raw === NULL) return; // released hosts freed their rows
		const keep: Uint8Array[] = [];
		let buf: Uint8Array;
		try {
			buf = encodeArgs([value], keep);
		} catch (error) {
			this.#breakResolver(resolver, error instanceof Error ? error.message : String(error));
			return;
		}
		if (hostS.pancake_host_resolver_fulfill(this.#raw, resolver, ab(buf)) !== OK) {
			this.#breakResolver(resolver, hostLastError() ?? "deferred settle refused");
			return;
		}
		this.signalCloseActivity();
		this.scheduleKick();
	}

	#breakResolver(resolver: bigint, message: string): void {
		if (this.#raw === NULL) return;
		const msg = new TextEncoder().encode(message);
		try {
			checkHost(hostS.pancake_host_resolver_break(this.#raw, resolver, ab(msg), BigInt(msg.length)));
		} catch (error) {
			this.recordBackgroundFailure(error);
		}
		this.signalCloseActivity();
		this.scheduleKick();
	}

	/** Arm the shared close-activity waiter. A close driver arms before it
	 * reads native progress (the lost-wakeup discipline): a state advance
	 * landing after the arm resolves the returned promise, and one landing
	 * before it is visible to the progress read that follows. Wake-all: every
	 * armed driver shares the one promise. Binding-internal. */
	armCloseActivity(): Promise<void> {
		if (this.#closeActivity == null) {
			let resolve!: () => void;
			const promise = new Promise<void>((r) => (resolve = r));
			this.#closeActivity = { promise, resolve };
		}
		return this.#closeActivity.promise;
	}

	/** Wake every parked close driver. Called after a native verb that can
	 * advance close-relevant state returns: a byte feed, a drained action
	 * batch, a resolver settle, a close call (escalation), a session release,
	 * or a loop step that ran work (`DriverLoop` parks its close drivers on
	 * this same notifier). Over-signaling is harmless because the drivers
	 * re-check progress; a missed source is a hang. Binding-internal. */
	signalCloseActivity(): void {
		const armed = this.#closeActivity;
		if (armed == null) return;
		this.#closeActivity = null;
		armed.resolve();
	}

	/** The longest a close driver may wait before re-polling progress:
	 * milliseconds to the nearest native FINISH grace deadline (the Host's own
	 * or any session's), or -1 when none is pending and only activity can
	 * advance terminal progress. */
	#closeWaitMs(): number {
		if (this.#raw === NULL) return 0;
		const out = new Uint8Array(8);
		checkHost(hostS.pancake_host_close_wait_ms(this.#raw, monotonicNowMs(), ab(out)));
		const wait = new DataView(out.buffer).getBigInt64(0, true);
		if (wait < 0n) return -1;
		// setTimeout treats a delay past 2^31-1 as roughly one millisecond, so
		// cap it; the cap is safe because the driver re-checks progress on wake.
		return wait > 2_147_483_647n ? 2_147_483_647 : Number(wait);
	}

	/** Park a close driver until host activity or the nearest native FINISH
	 * grace deadline; with no finite deadline pending the driver parks on
	 * `activity` alone. Binding-internal: `#doClose` and the byte-fed session
	 * close drive wait through it. */
	async waitCloseWake(activity: Promise<void>): Promise<void> {
		const waitMs = this.#closeWaitMs();
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

	async #doClose(): Promise<void> {
		const raw = this.#raw;
		if (raw === NULL) return;
		let timedOut = false;
		while (true) {
			// Arm before anything else in the iteration (the lost-wakeup
			// discipline): an advance landing after this line wakes the wait
			// below, and one landing before it is visible to the progress read.
			const activity = this.armCloseActivity();
			await this.kickActions();
			const state = new Uint8Array(4);
			const rc = hostS.pancake_host_close_progress(raw, monotonicNowMs(), ab(state));
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
		await this.#joinActionDrains();
		// Whatever the ring still holds reaches the sink before the ring dies
		// with the host.
		traceDrainHost(raw);
		this.drainParkedReleases();
		let failure: unknown | null = timedOut
			? new PancakeError(TIMEOUT, "finish close exhausted its grace period")
			: null;
		if (this.#finalizerState.raw === raw) {
			try {
				releaseHostState(this.#finalizerState, true);
			} catch (error) {
				// A still-live state means native release refused before consuming
				// the Host. Preserve every wrapper and session for an explicit retry.
				if (this.#finalizerState.raw === raw) throw error;
				failure = failure === null ? error : retainSecondaryFailure(failure, error);
			}
		}
		const sessionRetirements = this.#joinSessionRetirements([...this.#sessions.values()]);
		this.#sessions.clear();
		hostFinalizer.unregister(this);
		traceDetachHost(raw);
		this.#raw = NULL;
		this.#connectors.clear();
		this.#behaviorEntries.clear();
		this.#giftables.clear();
		this.#displacedGiftables.length = 0;
		this.hosted.clear();
		this.#vows.clear();
		try {
			await sessionRetirements;
		} catch (error) {
			failure = failure === null ? error : retainSecondaryFailure(failure, error);
		}
		if (failure !== null) throw failure;
	}

	/** Retire every channel the consumed native owner made unreachable. The
	 * first physical-close failure stays primary and every later one is attached
	 * in observation order; wrapper retirement itself never short-circuits. */
	async #joinSessionRetirements(sessions: readonly Session[]): Promise<void> {
		let failure: unknown | null = null;
		// Claim the return directly as well as the Host registry. The registry is
		// what preserves a session that unregistered before this snapshot; the
		// return is the local authority for every session still present in it.
		for (const session of sessions) {
			this.#sessionRetirements.add(session.nativeOwnerDidRelease());
		}
		while (this.#sessionRetirements.size !== 0) {
			const batch = [...this.#sessionRetirements];
			const outcomes = await Promise.allSettled(batch);
			for (const retirement of batch) this.#sessionRetirements.delete(retirement);
			for (const outcome of outcomes) {
				if (outcome.status !== "rejected") continue;
				failure = failure === null ? outcome.reason : retainSecondaryFailure(failure, outcome.reason);
			}
		}
		if (failure !== null) throw failure;
	}

	async #joinActionDrains(): Promise<void> {
		while (this.#actionDrains.size !== 0) {
			await Promise.allSettled([...this.#actionDrains]);
		}
	}

	/** Request terminal teardown and wait until every action drain, dial, and
	 * admission worker has stopped before the native Host is released. */
	close(options: CloseOptions = {}): Promise<void> {
		const encoded = encodeCloseOptions(options);
		if (this.#driverLoop != null) {
			return this.#driverLoop.close(options);
		}
		if (this.#releasePromise == null && this.#raw !== NULL) {
			this.#releaseStarted = true;
			checkHost(hostS.pancake_host_close(this.#raw, ab(encoded), monotonicNowMs()));
			this.signalCloseActivity();
			const begin = () => this.#doClose();
			this.#releasePromise = insideTurn() ? Promise.resolve().then(begin) : begin();
			void this.#releasePromise.catch(() => {});
		} else if (this.#raw !== NULL) {
			// A repeated close escalates the pending-work policy while the close
			// driver may already be parked; wake it so it re-reads progress.
			checkHost(hostS.pancake_host_close(this.#raw, ab(encoded), monotonicNowMs()));
			this.signalCloseActivity();
			return this.#releasePromise ?? Promise.resolve();
		}
		return this.#releasePromise ?? Promise.resolve();
	}

	/** Drain tracing while the native Host is still readable. Irreversible
	 * wrapper cleanup waits for `finishLoopTeardown` after driver release. */
	prepareLoopTeardown(): void {
		if (this.#raw === NULL) return;
		this.#releaseStarted = true;
		traceDrainHost(this.#raw);
	}

	/** Commit wrapper teardown after the driver released its Host, joining every
	 * loop channel's terminal promise before the driver's close barrier settles. */
	async finishLoopTeardown(): Promise<void> {
		if (this.#raw === NULL) return;
		const raw = this.#raw;
		traceDetachHost(raw);
		const sessionRetirements = this.#joinSessionRetirements([...this.#sessions.values()]);
		this.#sessions.clear();
		retireHostFinalizerState(this.#finalizerState);
		this.#vows.clear();
		this.#unobserved.length = 0;
		this.#raw = NULL;
		this.#behaviorEntries.clear();
		this.#giftables.clear();
		this.#connectors.clear();
		this.#displacedGiftables.length = 0;
		this.hosted.clear();
		await sessionRetirements;
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.close();
	}

	/** Atomically retain explicit byte-fed connectors under their transports. */
	installConnectors(connectors: readonly Connector[]): void {
		const pending = new Map<string, Connector>();
		for (const connector of connectors) {
			for (const transport of connector.transports) {
				if (transport.length === 0) {
					throw new PancakeError(
						INVALID_ARGUMENT,
						"connector transport symbols must not be empty",
					);
				}
				const installed = pending.get(transport) ?? this.#connectors.get(transport);
				if (installed != null && installed !== connector) {
					throw new PancakeError(
						INVALID_ARGUMENT,
						`host already has a different connector for transport ${JSON.stringify(transport)}`,
					);
				}
				pending.set(transport, connector);
			}
		}
		for (const [transport, connector] of pending) {
			this.#connectors.set(transport, connector);
		}
	}

	/** The explicitly installed byte-fed connector for `transport`, if any. */
	connectorFor(transport: string): Connector | null {
		return this.#connectors.get(transport) ?? null;
	}

	/** Enliven a complete sturdyref without naming a session (ADR-0098): the
	 * host enlivens it over a live session it already dialed to that peer, or
	 * dials one itself through this host's own DIAL action and finishes when
	 * the dial reports. The session-scoped `Session.enliven` is the narrower
	 * verb — it never dials, and refuses a sturdyref for another peer. */
	async enliven(sturdyref: string): Promise<Ref> {
		const swiss = utf8Encoder.encode(sturdyref);
		const out = new Uint8Array(8);
		checkHost(hostS.pancake_host_enliven(
			this.#raw,
			ab(swiss),
			BigInt(swiss.length),
			ab(out),
		));
		const vow = new DataView(out.buffer).getBigUint64(0, true);
		this.vowMinted(vow);
		await this.kickActions();
		const result = await this.awaitVow(vow);
		return asLiveRef(result, sturdyref);
	}

	/** Retain and select this Host's complete acceptable location. Later
	 * sessions advertise it regardless of their transport; existing sessions
	 * retain the locator their hello signed. */
	setAdvertisedLocator(locator: Locator): void {
		withOwnedLocator(
			locator,
			(owned) => checkHost(hostS.pancake_host_set_advertised_locator(this.#raw, owned.borrowView())),
		);
	}

	/** Remove this Host's retained locator for `transport`. */
	removeAdvertisedLocator(transport: string): void {
		const bytes = utf8Encoder.encode(transport);
		checkHost(hostS.pancake_host_remove_advertised_locator(
			this.#raw,
			ab(bytes),
			BigInt(bytes.length),
		));
	}

	/** Selective session-limit knobs (ADR-0082). Pass `0n` / `0` to leave a
	 * field unchanged. Affects peers minted after this call. */
	setSessionLimits(
		maxFrameBytes: bigint | number = 0,
		queueCap: bigint | number = 0,
		outboundHighWaterBytes: bigint | number = 0,
	): void {
		checkHost(hostS.pancake_host_set_session_limits(
			this.#raw,
			BigInt(maxFrameBytes),
			BigInt(queueCap),
			BigInt(outboundHighWaterBytes),
		));
	}

	/** The canonical key designator (64 lowercase hex digits) for this host's
	 * identity seed — what a keyed-tcp locator names as its designator
	 * (ADR-0075). */
	designator(): string {
		const out = new Uint8Array(64);
		checkHost(hostS.pancake_host_designator_from_seed(
			ab(this.#seed),
			32n,
			ab(out),
			BigInt(out.length),
		));
		return utf8Decoder.decode(out);
	}

	/** Host `behavior` once and bind `name` as a Host-wide alias. Fetch lazily
	 * projects the actor onto a session; a deposited gift keeps that exact actor
	 * when a recipient withdraws over its own exporter session (ADR-0009).
	 * Returns nothing; the gift's `Ref` is what the gifter passes on. */
	publishGiftable(name: string, behavior: Behavior): void {
		// A giftable is bound to no single session: its forwards always go
		// through the host, and a turn it runs belongs to whichever session
		// the deliver arrived on.
		const ctx = this.registerHostedBehavior({ run: behavior, resolveLocal: null });
		const bytes = utf8Encoder.encode(name);
		try {
			checkHost(hostS.pancake_host_publish(
				this.#raw,
				ab(bytes),
				BigInt(bytes.length),
				trampolinePointer(),
				ctx,
				NULL,
			));
		} catch (err) {
			// Nothing else drops a trampoline row, so a refused publish has to
			// take its own back or it pins the behavior for the process's life.
			this.unregisterHostedBehavior(ctx);
			throw err;
		}
		// Replacement moves discovery only. Existing capabilities and deposited
		// gifts can still call the old actor.
		const prior = this.#giftables.get(name);
		if (prior !== undefined) this.#displacedGiftables.push(prior);
		this.#giftables.set(name, ctx);
		this.scheduleKick();
	}

	/** Publish `behavior` under a freshly minted durable swiss name and return
	 * that name — the swiss to place in a sturdyref beside this host's own
	 * locator (ADR-0098). Unpredictable, never reassigned, structurally
	 * disjoint from every mutable alias, removable only through
	 * {@link unpublishDurable}. When supplied, `entropy` lets an embedder retain
	 * and reproduce the same durable name; otherwise this method draws it. */
	publishDurable(behavior: Behavior, entropy?: Uint8Array): string {
		const entropyBytes = entropy == null
			? crypto.getRandomValues(new Uint8Array(HOST_DURABLE_ENTROPY_LEN))
			: new Uint8Array(entropy);
		if (entropyBytes.length !== HOST_DURABLE_ENTROPY_LEN) {
			throw new PancakeError(
				INVALID_ARGUMENT,
				`durable entropy must be exactly ${HOST_DURABLE_ENTROPY_LEN} bytes`,
			);
		}
		const ctx = this.registerHostedBehavior({ run: behavior, resolveLocal: null });
		const swiss = new Uint8Array(HOST_DURABLE_SWISS_LEN);
		let written: number;
		try {
			written = hostS.pancake_host_publish_durable(
				this.#raw,
				ab(entropyBytes),
				BigInt(entropyBytes.length),
				trampolinePointer(),
				ctx,
				NULL,
				ab(swiss),
				BigInt(swiss.length),
			);
			if (written <= 0) checkHost(written);
		} catch (err) {
			this.unregisterHostedBehavior(ctx);
			throw err;
		}
		const name = utf8Decoder.decode(swiss.subarray(0, written));
		this.#giftables.set(name, ctx);
		this.scheduleKick();
		return name;
	}

	/** Retain one callback entry for this Host's native lifetime. */
	registerHostedBehavior(entry: BehaviorEntry): bigint {
		const ctx = registerBehavior(entry);
		this.#behaviorEntries.set(ctx, entry);
		this.#finalizerState.behaviorIds.add(ctx);
		return ctx;
	}

	/** Undo a refused callback mint before it joins Host authority. */
	unregisterHostedBehavior(ctx: bigint): void {
		this.#behaviorEntries.delete(ctx);
		this.#finalizerState.behaviorIds.delete(ctx);
		unregisterBehavior(ctx);
	}

	/** Remove a minted durable publication (ADR-0098): the old sturdyref
	 * misses from now on, while issued `Ref`s and deposited gifts keep the
	 * exact actor. Returns false when no such durable name exists. */
	unpublishDurable(swiss: string): boolean {
		const bytes = utf8Encoder.encode(swiss);
		const rc = hostS.pancake_host_remove_durable(this.#raw, ab(bytes), BigInt(bytes.length));
		if (rc === NOT_FOUND) return false;
		checkHost(rc);
		const prior = this.#giftables.get(swiss);
		if (prior !== undefined) {
			this.#displacedGiftables.push(prior);
			this.#giftables.delete(swiss);
		}
		this.scheduleKick();
		return true;
	}

	/** Remove the Host-wide alias `name` (alias-only): a later fetch misses on
	 * every session, while issued `Ref`s and deposited gifts keep the exact
	 * actor, whose behavior stays hosted for the Host's life. Returns false
	 * when no such alias exists. */
	unpublishGiftable(name: string): boolean {
		const bytes = utf8Encoder.encode(name);
		const rc = hostS.pancake_host_unpublish(this.#raw, ab(bytes), BigInt(bytes.length));
		if (rc === NOT_FOUND) return false;
		checkHost(rc);
		// The alias is gone but the actor is not: its trampoline row moves to
		// the displaced list, exactly as a replacement displaces one.
		const prior = this.#giftables.get(name);
		if (prior !== undefined) {
			this.#displacedGiftables.push(prior);
			this.#giftables.delete(name);
		}
		this.scheduleKick();
		return true;
	}

	/** The trampoline ctx of the giftable published under `name`, or undefined
	 * when this host published none. Binding-internal: `Session.publishedRef`
	 * uses it to record the Host identity a session surfaced for the giftable,
	 * so a local send to that identity composes in process. */
	giftableCtx(name: string): bigint | undefined {
		return this.#giftables.get(name);
	}

	/** Track a live session by its session address. Binding-internal: the
	 * `Session` constructor calls it. */
	registerSession(ptr: Ptr, session: Session): void {
		this.#sessions.set(ptr, session);
	}

	/** Retain one physical channel-close barrier independently of the native
	 * Session address. Binding-internal: Session registers exactly once when it
	 * creates the close promise. */
	trackSessionRetirement(retirement: Promise<void>): void {
		// A standalone Session close has its own caller and remains authoritative.
		// Host/loop teardown starts by setting this latch; only then does the Host
		// become the surviving owner that must join an unregistered session.
		if (!this.#releaseStarted) return;
		this.#sessionRetirements.add(retirement);
		// The close barrier claims the result below. Mark it handled meanwhile so
		// a synchronous rejection cannot become a process-global runtime event.
		void retirement.catch(() => {});
	}

	/** Stop tracking this released wrapper. Native addresses may be recycled;
	 * stale teardown must never delete a newer Session registered at the same
	 * address. Binding-internal. */
	unregisterSession(ptr: Ptr, session: Session): void {
		if (this.#sessions.get(ptr) === session) this.#sessions.delete(ptr);
	}

	/** Look up a live session by its session address. Binding-internal: the
	 * action drain's FLUSH/CLOSE arms route through it. */
	getSession(ptr: Ptr): Session | undefined {
		return this.#sessions.get(ptr);
	}

	/** Project the ingress session a callback turn names onto its public wrapper.
	 * A driver may have opened the session without an application-facing shell,
	 * so loop-owned sessions are adopted lazily. Binding-internal. */
	turnSession(ptr: Ptr): Session | null {
		const existing = this.#sessions.get(ptr);
		if (existing !== undefined) return existing;
		return this.#driverLoop?.adoptSession(ptr) ?? null;
	}

	/** Apply the ingress Session's distributed-GC opt-in before application
	 * behavior receives newly projected arguments. Binding-internal. */
	trackTurnArguments(session: object | null, args: Argument[]): void {
		if (!(session instanceof Session)) return;
		for (const value of args) session.trackGcArgument(value);
	}

	/** The live `Session` homing remote `ref`, or null for a local, stale,
	 * foreign-Host, or closed-session capability. Deterministic (ADR-0088): the reply's
	 * own token carries its route, so `Session.sendRedeeming` resolves the exact
	 * exporter session it should host its back-channel on — no capture window,
	 * no dependence on which dial completed first, and it finds an exporter that
	 * a prior redeem already dialed (a cache hit that mints no new dial at all).
	 * `Session.sendRedeeming` suppresses its own sending session and surfaces
	 * only a different exporter. Binding-internal. */
	exporterFor(ref: Ref): Session | null {
		const refBuf = refStruct(ref);
		let ptr: Ptr;
		if (this.#driverLoop != null) {
			ptr = this.#driverLoop.claimReferenceExporter(refBuf) ?? NULL;
		} else {
			const out = new Uint8Array(8);
			checkHost(hostS.pancake_host_reference_exporter(this.#raw, ab(refBuf), ab(out)));
			ptr = outPointer(out);
		}
		if (ptr === NULL) return null;
		const found = this.#sessions.get(ptr) ?? null;
		if (found == null && this.#driverLoop != null) {
			// A loop-owned Host redeems inside its own steps (ADR-0112), so the
			// exporter session it dialed exists with no wrapper yet. Wrap it
			// lazily — adoption registers it, so a repeat lookup returns this
			// same object — and the loop stays its release authority.
			return this.#driverLoop.adoptSession(ptr);
		}
		return found;
	}

	// ── The vow table ──────────────────────────────────────────────────────────

	/** Reject every pending vow with one loop failure before loop teardown
	 * clears the table. A later observation receives the same failure. */
	failPendingVows(error: PancakeError): void {
		if (this.#terminalVowFailure == null) this.#terminalVowFailure = error;
		for (const row of this.#vows.values()) {
			if (row.state.tag === "awaited") row.state.waiter.reject(error);
		}
		this.#vows.clear();
		this.#unobserved.length = 0;
	}

	/** Record a freshly minted vow so the drain can route its completion. Must
	 * run in the same synchronous block as the minting FFI call, so no drain
	 * can pop the completion first. Binding-internal. */
	vowMinted(vow: bigint, trackGc = false): void {
		this.#vows.set(vow, { state: { tag: "minted" }, trackGc });
	}

	/** The vow's eventual outcome: the fulfilled wire value, or a rejection —
	 * `VowBroken` for a partner break, the typed CLOSED `PancakeError` when the
	 * settle was the disconnect's own break. Settles immediately from the
	 * recorded state when the outcome already landed. Binding-internal. */
	awaitVow(vow: bigint): Promise<Argument> {
		const row = this.#vows.get(vow);
		if (row === undefined) {
			if (this.#terminalVowFailure != null) {
				return Promise.reject(this.#terminalVowFailure);
			}
			// Evicted (never awaited until past the cap) or never minted here.
			return Promise.reject(
				new PancakeError(CLOSED, "the vow's outcome is gone (unobserved past the cap)"),
			);
		}
		if (row.state.tag !== "settled") {
			// Minted or re-awaited: (re)park a waiter. A prior awaited waiter is
			// replaced here, the same overwrite the separate field performed.
			return new Promise<Argument>((resolve, reject) => {
				row.state = { tag: "awaited", waiter: { resolve, reject } };
			});
		}
		this.#vows.delete(vow);
		const outcome = row.state.outcome;
		return "ok" in outcome ? Promise.resolve(outcome.ok) : Promise.reject(outcome.err);
	}

	/** The drain's settle arms: fire the waiter, or record the outcome for a
	 * late observation (bounded FIFO — an outcome nobody ever awaits is evicted
	 * at the cap). Binding-internal: `action.ts` calls it. */
	settleVow(vow: bigint, outcome: { ok: Argument } | { err: PancakeError }): void {
		const row = this.#vows.get(vow);
		if (row === undefined) return; // an outcome nobody registered for
		if (row.trackGc && "ok" in outcome) this.#gc.trackArgument(outcome.ok);
		if (row.state.tag === "awaited") {
			const waiter = row.state.waiter;
			this.#vows.delete(vow);
			if ("ok" in outcome) waiter.resolve(outcome.ok);
			else waiter.reject(outcome.err);
			return;
		}
		// Minted, or an already-settled row re-settled: hold for a late observation.
		row.state = { tag: "settled", outcome };
		this.#unobserved.push(vow);
		while (this.#unobserved.length > MAX_UNOBSERVED_OUTCOMES) {
			const oldest = this.#unobserved.shift()!;
			const stale = this.#vows.get(oldest);
			// Only evict a row still parked unobserved; an observed one is gone.
			if (stale !== undefined && stale.state.tag === "settled") {
				this.#vows.delete(oldest);
			}
		}
	}

	// ── The action drain (the one loop rule) ──────────────────────────────────

	/** Park a C release the host refused inside a behavior callback; the next
	 * drain — the head of `kickActions`, or the feed's unwind — runs it where
	 * it is legal. Binding-internal. */
	parkRelease(release: () => void): void {
		this.#parkedReleases.push(release);
	}

	/** Track every newly projected capability occurrence in an application
	 * value. Binding-internal; Session decides whether its opt-in applies. */
	trackGcArgument(value: Argument): Argument {
		return this.#gc.trackArgument(value);
	}

	drainGc(): void {
		if (this.#backgroundFailure !== null) {
			const failure = this.#backgroundFailure;
			this.#backgroundFailure = null;
			throw failure;
		}
		this.#gc.drainGc();
	}

	/** Retain the first failure from a callerless runtime task. Binding-internal. */
	recordBackgroundFailure(failure: unknown): void {
		if (this.#backgroundFailure === null) this.#backgroundFailure = failure;
		else this.#backgroundFailure = retainSecondaryFailure(this.#backgroundFailure, failure);
		this.signalCloseActivity();
	}

	disarmGc(ref: Ref): void {
		this.#gc.disarm(ref);
	}

	/** Run every parked release, always outside a callback frame where the C
	 * tier accepts them. Called at the head of `kickActions` and right after a
	 * feed returns. Binding-internal. */
	drainParkedReleases(): void {
		if (insideTurn()) return;
		const ranAny = this.#parkedReleases.length > 0;
		while (this.#parkedReleases.length > 0) {
			const pending = this.#parkedReleases.splice(0);
			for (const release of pending) release();
		}
		// A parked release retires a native session or Host handle, which is
		// close-relevant state; wake any parked close driver to re-check.
		if (ranAny) this.signalCloseActivity();
	}

	/** How many releases are parked on this host — test observability for the
	 * mid-turn close park. Binding-internal. */
	pendingReleaseCount(): number {
		return this.#parkedReleases.length;
	}

	/** Pop and honor every pending embedder action. Reentrant on purpose: DIAL
	 * starts its connection task without awaiting establishment, and that task's
	 * start-session FLUSH re-enters this drain independently. Actions are
	 * popped and decoded first (`parkActions` over `pancake_host_next_action`,
	 * each copied out before the next pop frees its views) and awaited after
	 * the pops, so async I/O never runs while a borrowed view is live.
	 * Re-parks until empty: a NEED_GIFT_ID's `provide_gift_id` can queue FLUSH
	 * legs after a full pop round (same as Racket's `drain-host-actions!`). A
	 * no-op inside a hosted turn: the host refuses the driving verbs there,
	 * and everything the turn enqueued pumps when the enclosing feed unwinds
	 * into this same drain. Binding-internal. */
	kickActions(): Promise<void> {
		if (this.#driverLoop != null) {
			// The native loop is the one drain on an adopted Host (ADR-0112):
			// the kick becomes a scheduled loop step, which runs the parked
			// releases and the GC drain at its own head — legal even from
			// inside a turn, because the step defers past the enclosing feed.
			if (!insideTurn()) this.drainParkedReleases();
			this.#driverLoop.scheduleStep();
			return Promise.resolve();
		}
		if (insideTurn()) return Promise.resolve();
		// Parked releases run first — before the raw-handle check, because a
		// mid-turn Host.close cleared `#raw` while parking the actual free.
		this.drainParkedReleases();
		if (this.#raw === NULL) return Promise.resolve();

		// Register before execution starts. A drain can synchronously cause Host
		// teardown through an action it runs; deferring its body to a microtask
		// closes the admission window before that body can make progress.
		const drain = Promise.resolve().then(() => this.#drainActions());
		this.#actionDrains.add(drain);
		const retire = () => {
			this.#actionDrains.delete(drain);
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
		await this.#joinActionDrains();
	}

	async #drainActions(): Promise<void> {
		if (this.#raw === NULL) return;
		// The live trace's capture ring drains on the same unwind as the action
		// queue: both are host effects the embedder pops, and popping them
		// together is what keeps a queued fact from waiting on the next verb.
		traceDrainHost(this.#raw);
		while (true) {
			if (this.#raw === NULL) return;
			const { actions, yielded } = parkActions(this);
			if (actions.length === 0 && !yielded) return;
			let firstFailure: { error: unknown } | null = null;
			for (const action of actions) {
				if (this.#raw === NULL) return;
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
				if (this.#raw === NULL) return;
				// Prefer the scheduler API where it exists; the timer fallback is
				// portable across browsers, Deno, and Node and yields to I/O rather
				// than chaining an unbounded microtask run.
				const scheduler = (globalThis as {
					scheduler?: { yield?: () => Promise<void> };
				}).scheduler;
				if (scheduler?.yield != null) await scheduler.yield();
				else await new Promise<void>((resolve) => setTimeout(resolve, 0));
			}
		}
	}
}
