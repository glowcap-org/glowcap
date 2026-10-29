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

import {
	BINDING_UNOBSERVED_OUTCOME_CAP,
	CLOSED,
	DEFAULT_FRAME_CAP,
	INTERNAL,
	INVALID_ARGUMENT,
	OK,
} from "@glowcap/abi";
import { encodeArgs } from "../abi_value.ts";
import { Context, type FailureEvent, recordCallerlessFailure, releaseContext, retainContext } from "../context.ts";
import { checkHost, GlowcapError, hostLastError, retainSecondaryFailure } from "../errors.ts";
import { drainFinalizerRetries } from "../finalizer_retry.ts";
import { HostGc } from "../gc.ts";
import type { HostOptions } from "../host.ts";
import { hostS } from "../internal/ffi/host.ts";
import { NULL, type Ptr } from "../internal/ffi/runtime.ts";
import { ab, outPointer, outU64 } from "../internal/seam.ts";
import { type DriverLoopHandle, Session } from "../session.ts";
import { traceAttachHost, traceDetachHost } from "../trace.ts";
import { type BehaviorEntry } from "../trampoline.ts";
import type { Connector } from "../transport.ts";
import {
	type Argument,
	type CaptpVersion,
	captpVersionId,
	type Codec,
	codecId,
	DEFAULT_CAPTP_VERSION,
	DEFAULT_CODEC,
	DEFAULT_FEATURES,
	featureMask,
	type FeatureSet,
	INTEROP_CAPTP_VERSION,
	INTEROP_CODEC,
	OWN_CAPTP_VERSION,
	OWN_CODEC,
} from "../value.ts";
import {
	type HostFinalizerState,
	registerHostFinalizer,
	releaseHostState,
	unregisterHostFinalizer,
} from "./finalizer.ts";

// One encoder/decoder pair for the whole module: both are stateless here.
class HostedBehaviorMap extends Map<bigint, bigint> {
	constructor(readonly behaviorIds: Set<bigint>) {
		super();
	}

	override set(refId: bigint, ctx: bigint): this {
		this.behaviorIds.add(ctx);
		return super.set(refId, ctx);
	}
}

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
		waiter: { resolve: (v: Argument) => void; reject: (e: GlowcapError) => void };
	}
	| { tag: "settled"; outcome: { ok: Argument } | { err: GlowcapError } };

interface VowRow {
	state: VowState;
	trackGc: boolean;
}

/** Cap on stored outcomes whose vow is never awaited, so the store cannot grow
 * without bound; the oldest un-awaited outcome is evicted at the cap. */
export const MAX_UNOBSERVED_OUTCOMES = BINDING_UNOBSERVED_OUTCOME_CAP;
export abstract class HostState {
	abstract designator(): string;
	abstract scheduleKick(): void;
	abstract kickActions(): Promise<void>;
	abstract drainParkedReleases(): void;
	abstract recordBackgroundFailure(failure: unknown): void;
	abstract vowMinted(vow: bigint, trackGc?: boolean): void;
	abstract awaitVow(vow: bigint): Promise<Argument>;
	abstract abandonVow(vow: bigint): void;
	protected readonly _context: Context;
	protected readonly _diagnosticId: bigint;
	/** The host's retained durable identity seed. Each read returns a copy. */
	protected readonly _seed: Uint8Array;
	/** The wire grammar every session this host mints negotiates in. */
	readonly codec: Codec;
	readonly captpVersion: CaptpVersion;
	readonly features: FeatureSet;
	protected _raw: Ptr;
	// Set before trace draining because a sink may recursively release this Host.
	protected _releaseStarted = false;
	protected _releasePromise: Promise<void> | null = null;
	protected readonly _finalizerState: HostFinalizerState;
	/** Host-owned finalizer registry and release queue. */
	protected readonly _gc: HostGc;
	// Every live session by its GlowcapHostSession address, so a FLUSH action
	// routes to the transport that owns the bytes, a dialed exporter stays
	// reachable for teardown, and `exporterFor` maps a redeemed reply's route
	// (a GlowcapHostSession pointer) back to its `Session` wrapper.
	protected readonly _sessions: Map<Ptr, Session> = new Map();
	// Physical channel closes can outlive the FFI Session pointer that
	// initiated them. Keep their promises at the Host barrier after the wrapper
	// unregisters, so Host close cannot lose a late transport refusal.
	protected readonly _sessionRetirements: Set<Promise<void>> = new Set();
	// The vow table the drain's SETTLE/FAIL arms settle.
	protected readonly _vows: Map<bigint, VowRow> = new Map();
	// A loop drive failure outlives table teardown so promises observed after
	// the loop failed receive the original cause rather than a generic close.
	protected _terminalVowFailure: GlowcapError | null = null;
	// The first failure from work detached from its immediate
	// caller. The next verb head or terminal close barrier consumes the exact cause.
	protected _backgroundFailure: { readonly error: unknown } | null = null;
	// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	protected readonly _unobserved: bigint[] = [];
	protected _unobservedHead = 0;
	// DIAL actions are asynchronous after the C queue has consumed them. Retain
	// their executors until they report a terminal result; otherwise a detached
	// promise can disappear while its ticket and half-open channel remain live.
	protected readonly _dialTasks: Map<string, {
		readonly controller: AbortController;
		readonly promise: Promise<void>;
	}> = new Map();
	// Action drains may await transport I/O after popping FFI actions. Keep
	// every admitted drain under Host teardown so none can resume after FFI
	// Host storage is released.
	protected readonly _actionDrains: Set<Promise<void>> = new Set();
	// Each session's writer task. A CLOSE leaves the transport close to its
	// writer, so Host release waits for every writer to exit. Session teardown
	// barriers never join them: a write blocked on a slow partner must not
	// stop that partner's reader.
	protected readonly _sessionWriters: Set<Promise<void>> = new Set();
	// Explicit embedder-owned byte-channel authority, retained by transport so
	// a later handoff redeem uses the same application-selected integration.
	protected readonly _connectors: Map<string, Connector> = new Map();
	// Releases the C tier refused inside a behavior callback park here
	// (`glowcap_host_session_release` / `glowcap_host_release` are refused
	// mid-turn); the drain runs them once the enclosing feed unwinds, so a
	// mid-turn close never leaks its C handle. Mirrors Python/Rust.
	protected readonly _parkedReleases: Array<() => void> = [];
	// Trampoline ctx ids of this host's live Host publicationes, by published name.
	// FFI actor retirement drops their strong behavior ownership; Host release
	// is the final catch-all. Keyed by name so `Session.publishedRef` can find the
	// ctx.
	protected readonly _publications: Map<string, bigint> = new Map();
	// Every Session.spawn/publish trampoline on this Host. Actors live in the
	// Host Vat and remain callable through sibling Ports after the Port that
	// first projected them closes.
	readonly hosted: Map<bigint, bigint>;
	// Strong ownership behind the weak process-global trampoline lookup. This
	// may contain a behavior that captures this Host; that cycle is local and
	// therefore collectable.
	protected readonly _behaviorEntries: Map<bigint, BehaviorEntry> = new Map();
	// The driver loop that owns this Host's handle, when this wrapper was
	// adopted over a loop's host (ADR-0024). In that mode the C loop is the
	// action drain: the kick verbs nudge a loop step instead of running the
	// binding drain, and release belongs to `DriverLoop.close`.
	protected _driverLoop: DriverLoopHandle | null = null;
	// The shared close-activity notifier (wake-all): a close driver arms it
	// before reading FFI close progress, and every FFI verb that can
	// advance close-relevant state resolves it after the verb returns. Null
	// while no arm is outstanding.
	protected _closeActivity: { promise: Promise<void>; resolve: () => void } | null = null;

	/** A host with identity `seed` (32 bytes; omitted draws a fresh random one:
	 * entropy at the binding boundary, never inside the sans-io host). `codec`,
	 * `captpVersion`, and `features` are this Host's signed profile offer;
	 * each session settles version and codec with its partner, falling back to
	 * v1.0/Syrup when needed, and runs only the intersection of the two offered
	 * feature sets. Omitted profile options use the generated C ABI defaults.
	 * `context` routes every byte the host owns through a caller-supplied
	 * allocation scope; `localTurnBudget` caps local-turn amplification per
	 * session (ADR-0018): `0` applies the Host's finite default, `0xFFFF_FFFF`
	 * (the C ABI's `GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED`) turns the cap off, and
	 * any other value is the cap. */
	constructor(
		seed?: Uint8Array,
		opts: HostOptions = {},
	) {
		drainFinalizerRetries();
		if (seed != null && seed.length !== 32) {
			throw new GlowcapError(INVALID_ARGUMENT, "Host: seed must be 32 bytes");
		}
		const durableSeed = seed ?? crypto.getRandomValues(new Uint8Array(32));
		// Keep the binding's own copy: callers can reuse or mutate their input
		// without changing the identity FFI Host already retained.
		this._seed = new Uint8Array(durableSeed);
		if (opts.profile !== undefined && opts.profile !== "glowcap" && opts.profile !== "interop") {
			throw new GlowcapError(INVALID_ARGUMENT, `Host: unknown profile ${JSON.stringify(opts.profile)}`);
		}
		if (opts.profile !== undefined && (opts.codec !== undefined || opts.captpVersion !== undefined)) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				"Host: profile cannot be combined with codec or captpVersion",
			);
		}
		this.codec = opts.profile === "glowcap"
			? OWN_CODEC
			: opts.profile === "interop"
			? INTEROP_CODEC
			: opts.codec ?? DEFAULT_CODEC;
		this.captpVersion = opts.profile === "glowcap"
			? OWN_CAPTP_VERSION
			: opts.profile === "interop"
			? INTEROP_CAPTP_VERSION
			: opts.captpVersion ?? DEFAULT_CAPTP_VERSION;
		this.features = opts.features ?? DEFAULT_FEATURES;
		const frameCap = opts.frameCap ?? DEFAULT_FRAME_CAP;
		if (!Number.isSafeInteger(frameCap) || frameCap <= 0) {
			throw new GlowcapError(
				INVALID_ARGUMENT,
				"Host: frameCap must be a positive safe integer",
			);
		}
		// The durable identity followed by a session-key root drawn here, at
		// this binding's entropy boundary, because the library draws none
		// (ADR-0028). The root is fresh per process, so every CapTP session
		// signs with its own key and a restart cannot recreate a prior
		// session's handoff names; the durable half stays exactly `seed`,
		// since a keyed locator's designator derives from it.
		const seedWithRoot = new Uint8Array(64);
		seedWithRoot.set(this._seed, 0);
		crypto.getRandomValues(seedWithRoot.subarray(32));
		const out = new Uint8Array(8);
		const localTurnBudget = opts.localTurnBudget ?? 0;
		const context = opts.context ?? Context.create();
		this._context = context;
		const contextRaw = retainContext(context);
		try {
			checkHost(hostS.glowcap_host_new_in(
				contextRaw,
				ab(seedWithRoot),
				64n,
				BigInt(frameCap),
				1,
				codecId(this.codec),
				captpVersionId(this.captpVersion),
				featureMask(this.features),
				localTurnBudget,
				0,
				ab(out),
			));
		} catch (err) {
			releaseContext(context);
			throw err;
		}
		this._raw = outPointer(out);
		const diagnosticOut = new Uint8Array(8);
		try {
			checkHost(hostS.glowcap_host_diagnostic_id(this._raw, ab(diagnosticOut)));
		} catch (err) {
			const cleanupState: HostFinalizerState = {
				raw: this._raw,
				diagnosticId: 0n,
				behaviorIds: new Set(),
				context,
				releaseFailureReported: false,
			};
			try {
				releaseHostState(cleanupState, true, true);
			} catch (cleanup) {
				this._raw = NULL;
				throw retainSecondaryFailure(err, cleanup);
			}
			this._raw = NULL;
			throw err;
		}
		this._diagnosticId = outU64(diagnosticOut);
		this._finalizerState = {
			raw: this._raw,
			diagnosticId: this._diagnosticId,
			behaviorIds: new Set(),
			context,
			releaseFailureReported: false,
		};
		this.hosted = new HostedBehaviorMap(this._finalizerState.behaviorIds);
		registerHostFinalizer(this, this._finalizerState);
		try {
			// The host's own key designator, the name a partner knows it by:
			// the live trace reports it as this host's endpoint so one peer stays
			// one node in a feed several producers share.
			traceAttachHost(this._raw, this.designator(), this._context, this._diagnosticId);
			this._gc = new HostGc();
			// deno-lint-ignore no-this-alias -- GcHandle object closes over Host fields
			const host = this;
			this._gc.bind({
				get released() {
					return host._raw === NULL;
				},
				get hostRaw() {
					return host._raw;
				},
				kick: () => {
					host.scheduleKick();
				},
				recordFailure: (failure) => host.recordBackgroundFailure(failure),
				abandonVow: (vow) => host.abandonVow(vow),
				scheduleDrain: (run) => queueMicrotask(run),
			});
		} catch (err) {
			unregisterHostFinalizer(this);
			traceDetachHost(this._raw);
			try {
				releaseHostState(this._finalizerState, true, true);
			} catch (cleanup) {
				this._raw = NULL;
				throw retainSecondaryFailure(err, cleanup);
			}
			this._raw = NULL;
			throw err;
		}
	}

	/** Return a defensive copy of the durable identity seed. */
	get seed(): Uint8Array {
		return new Uint8Array(this._seed);
	}

	/** Transfer a retained task failure to a verb or terminal close barrier. */
	protected _takeBackgroundFailure(): { readonly error: unknown } | null {
		const failure = this._backgroundFailure;
		this._backgroundFailure = null;
		return failure;
	}

	/** The raw GlowcapHost handle. Binding-internal: `Session` mints and
	 * drives sessions against it. */
	get raw(): Ptr {
		if (this._raw === NULL) throw new GlowcapError(CLOSED, "host released");
		return this._raw;
	}

	/** Whether terminal Host teardown has invalidated the FFI handle. */
	get released(): boolean {
		return this._raw === NULL;
	}

	/** Claim callerless failures retained by this Host's Context. */
	takeFailures(): FailureEvent[] {
		return this._context.takeFailures();
	}

	/** Retain an application callback failure that has no return recipient.
	 * Binding-internal: returned failures must stay on their ordinary path. */
	recordCallerlessFailure(operation: string, error: unknown): void {
		recordCallerlessFailure(this._context, {
			layer: "application-observer",
			scope: "host",
			scopeId: this._diagnosticId,
			operation,
			primaryName: error instanceof Error ? error.name : "ThrownValue",
			primaryResult: INTERNAL,
			primaryMessage: error instanceof Error ? error.message : String(error),
		});
	}

	/** Retain a binding-owned rollback failure after its initiating call already
	 * returned another primary. Binding-internal. */
	recordCallerlessBindingFailure(operation: string, error: unknown): void {
		recordCallerlessFailure(this._context, {
			layer: "binding",
			scope: "host",
			scopeId: this._diagnosticId,
			operation,
			primaryName: error instanceof Error ? error.name : "ThrownValue",
			primaryResult: INTERNAL,
			primaryMessage: error instanceof Error ? error.message : String(error),
		});
	}

	/** The driver loop that owns this Host, or null for a byte-fed Host.
	 * Binding-internal: the dial executor routes a dial on a loop-owned Host
	 * onto that same loop (ADR-0024). */
	get driverLoop(): DriverLoopHandle | null {
		return this._driverLoop;
	}

	/** Refuse operations only after the FFI handle has been invalidated. */
	assertHandle(): void {
		if (this._raw === NULL) {
			throw new GlowcapError(CLOSED, "Host is closed");
		}
	}

	protected clearVowRows(): void {
		this._vows.clear();
		this._unobserved.length = 0;
		this._unobservedHead = 0;
	}

	/** Transfer FFI ownership to a DriverLoop after its ABI claim succeeds;
	 * only that loop may release the handle. Binding-internal. */
	attachDriverLoop(driverLoop: DriverLoopHandle): HostFinalizerState {
		if (this._raw === NULL || this._releaseStarted || this._driverLoop != null) {
			throw new GlowcapError(INVALID_ARGUMENT, "host is not transferable");
		}
		unregisterHostFinalizer(this);
		this._driverLoop = driverLoop;
		return this._finalizerState;
	}

	/** Run one popped DIAL executor under this Host's terminal lifetime. The
	 * signal owns transport cancellation; retention alone is not ownership. */
	startDialTask(ticket: bigint, routeIndex: bigint, run: (signal: AbortSignal) => Promise<void>): Promise<void> {
		if (this._raw === NULL) return Promise.resolve();
		const controller = new AbortController();
		// Defer invocation until after the task is registered. A callback that
		// synchronously releases this Host can therefore never create untracked
		// work between `run` entering and the map insertion below.
		const key = `${ticket}:${routeIndex}`;
		const retained = Promise.resolve().then(() => {
			if (controller.signal.aborted) return;
			return run(controller.signal);
		}).catch((error) => this.recordBackgroundFailure(error))
			.finally(() => {
				if (this._dialTasks.get(key)?.promise === retained) this._dialTasks.delete(key);
			});
		this._dialTasks.set(key, { controller, promise: retained });
		return retained;
	}

	/** Execute one core-issued dial cancellation and acknowledge physical
	 * retirement only after its task can no longer touch the Host.  status-allow: lifecycle transition */
	async cancelDialTask(ticket: bigint, routeIndex: bigint): Promise<void> {
		const key = `${ticket}:${routeIndex}`;
		const task = this._dialTasks.get(key);
		if (task != null) {
			task.controller.abort();
			await task.promise;
		}
		if (this._raw !== NULL) {
			checkHost(hostS.glowcap_host_dial_cancelled(this._raw, ticket, routeIndex));
			// Retiring a pending dial is close-relevant pending work.
			this.signalCloseActivity();
		}
	}

	/** Binding-internal (the trampoline's async-behavior arm): defer `turn`'s
	 * answer onto a fresh resolver vow and settle it when `pending` does
	 * (ADR-0014). The settle re-enters on the runtime's microtask queue (the
	 * top-level re-entry the host requires). Owning-thread capabilities use
	 * the Host's application-value projection in the original caller session.
	 * A refused value breaks the answer rather than stranding it.
	 * False when the deferral itself refused; the caller breaks the turn. */
	deferTurnToPromise(turn: Ptr, pending: PromiseLike<Argument | void>): boolean {
		const resolverOut = new Uint8Array(8);
		if (hostS.glowcap_host_turn_defer(turn, ab(resolverOut)) !== OK) return false;
		const resolver = outU64(resolverOut);
		void Promise.resolve(pending).then(
			(value) => this._settleResolver(resolver, value === undefined ? null : value),
			(err) => this._breakResolver(resolver, err instanceof Error ? err.message : String(err)),
		);
		return true;
	}

	protected _settleResolver(resolver: bigint, value: Argument): void {
		if (this._raw === NULL) return; // released hosts freed their rows
		const keep: Uint8Array[] = [];
		let buf: Uint8Array;
		try {
			buf = encodeArgs([value], keep);
		} catch (error) {
			this._breakResolver(resolver, error instanceof Error ? error.message : String(error));
			return;
		}
		if (hostS.glowcap_host_resolver_fulfill_value(this._raw, resolver, ab(buf)) !== OK) {
			this._breakResolver(resolver, hostLastError() ?? "deferred settle refused");
			return;
		}
		this.signalCloseActivity();
		this.scheduleKick();
	}

	protected _breakResolver(resolver: bigint, message: string): void {
		if (this._raw === NULL) return;
		const msg = new TextEncoder().encode(message);
		try {
			// The awaitable can finish after its calling session retired the answer.
			checkHost(hostS.glowcap_host_resolver_abandon(this._raw, resolver, ab(msg), BigInt(msg.length)));
		} catch (error) {
			this.recordBackgroundFailure(error);
		}
		this.signalCloseActivity();
		this.scheduleKick();
	}

	/** Arm the shared close-activity waiter. A close driver arms before it
	 * reads FFI progress (the lost-wakeup discipline): a state advance
	 * landing after the arm resolves the returned promise, and one landing
	 * before it is visible to the progress read that follows. Wake-all: every
	 * armed driver shares the one promise. Binding-internal. */
	armCloseActivity(): Promise<void> {
		if (this._closeActivity == null) {
			let resolve!: () => void;
			const promise = new Promise<void>((r) => (resolve = r));
			this._closeActivity = { promise, resolve };
		}
		return this._closeActivity.promise;
	}

	/** Wake every parked close driver. Called after an FFI verb that can
	 * advance close-relevant state returns: a byte feed, a drained action
	 * batch, a resolver settle, a close call (escalation), a session release,
	 * or a loop step that ran work (`DriverLoop` parks its close drivers on
	 * this same notifier). Over-signaling is harmless because the drivers
	 * re-check progress; a missed source is a hang. Binding-internal. */
	signalCloseActivity(): void {
		const armed = this._closeActivity;
		if (armed == null) return;
		this._closeActivity = null;
		armed.resolve();
	}

	/** The longest a close driver may wait before re-polling progress:
	 * milliseconds to the nearest FFI FINISH grace deadline (the Host's own
	 * or any session's), or -1 when none is pending and only activity can
	 * advance terminal progress. */
}
