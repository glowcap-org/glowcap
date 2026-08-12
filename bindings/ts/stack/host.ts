// The CapTP host — multi-session CapTP product over the byte-fed host archive
// (libpancake_host, ADR-0072). Goblins' `mycapn` is two roles: the product maps
// to this `Host`, the router tables map to `engine.Node` that the host owns — never
// a single-type equation. The `PancakeHost` owns every decision: the retained
// identity, live-session directory, routing, transparent three-party
// redemption, and the gifter half's origination. What lives here is only what
// the embedder contract leaves to the binding: the host handle, the
// session-pointer → `Session` registry the action drain routes by, the vow table
// the drain's SETTLE/FAIL arms settle, the serialized action drain itself,
// gift-id entropy, and the iroh redeem posture the dial executor reads. The
// action decode+execute switch lives in `action.ts`; the pump lives in
// `pump.ts`; the dial executor lives in `dial.ts`. `session.ts` owns the
// `Session` they act on. `mod.ts` re-exports the public `Host`.

import { hostS } from "./internal/ffi/host.ts";
import { NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outPointer, outU64 } from "./internal/seam.ts";
import {
	CLOSED,
	DEFAULT_FRAME_CAP,
	INVALID_ARGUMENT,
	IROH_REACH_REDEEM_DEFAULT,
	NOT_FOUND,
	OK,
} from "@pancake/abi";
import { checkHost, hostLastError, PancakeError } from "./errors.ts";
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
	Reachability,
	Ref,
} from "./value.ts";
import { encodeArgs, refStruct } from "./codec.ts";
import {
	type BehaviorEntry,
	insideTurn,
	registerBehavior,
	trampolinePointer,
	unregisterBehavior,
} from "./trampoline.ts";
import { type Context, releaseContext, retainContext } from "./context.ts";
import { type DriverLoopHandle, Session } from "./session.ts";
import { asLiveRef } from "./promise.ts";
import { parkActions, runAction } from "./action.ts";
import { HostGc } from "./gc.ts";
import { type Locator, withOwnedLocator } from "./locator.ts";

// One encoder/decoder pair for the whole module: both are stateless here.
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

interface HostFinalizerState {
	raw: Ptr;
	/** Every process-global trampoline row owned by this Host. Bigints only:
	 * the held state must never retain the Host wrapper or a behavior closure. */
	behaviorIds: Set<bigint>;
	/** Keep a caller-supplied allocation scope alive until native Host release.
	 * The Context does not retain this Host, so this cannot create a cycle. */
	context: Context | null;
}

// Finalizers cannot report release refusal. Keep the native allocation policy
// alive in that impossible-by-contract arm rather than freeing it under the
// still-live Host.
const refusedHostFinalizers = new Set<HostFinalizerState>();

function releaseHostState(state: HostFinalizerState): void {
	if (state.raw === NULL) return;
	const raw = state.raw;
	if (hostS.pancake_host_release(raw) !== OK) {
		refusedHostFinalizers.add(state);
		return;
	}
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

// A host vow's row: its home session plus its pending state.
interface VowRow {
	/** The session the vow was minted on, for closed-vs-broken classification;
	 * null for a vow whose home is not a single session. */
	session: Session | null;
	state: VowState;
}

/** Cap on stored outcomes whose vow is never awaited, so the store cannot grow
 * without bound; the oldest un-awaited outcome is evicted at the cap. */
const MAX_UNOBSERVED_OUTCOMES = 1024;

/** The CapTP host: one identity, one session directory, one routing and redeem
 * authority, shared by every session minted against it. Owns `engine.Node`
 * (the sans-io handoff router). The cross-host machinery lives in the Zig
 * core behind `libpancake_host` (ADR-0072); this is the host-idiom residue
 * over it — the `Session` registry, the vow table, the serialized action
 * drain that performs the I/O the host asks for (dial, flush, settle,
 * entropy), and the iroh redeem posture. */
/** How a host signals a `webrtc` peer it dials (ADR-0089): the language-level
 * face of the signaling capability the application holds. WebRTC needs an
 * offer, an answer, and trickled ICE candidates exchanged before its
 * DataChannel exists; the application decides how those messages travel — over
 * a room session, a relay, any capability both parties reach — and the dial
 * executor only drives the exchange. SDP and candidates cross this seam as the
 * opaque strings the wire shape carries (a candidate is the JSON-serialized
 * `RTCIceCandidateInit`). */
export interface SignalingAuthority {
	/** Deliver the SDP offer to `designator`'s peer and resolve its SDP answer. */
	offer(designator: string, sdp: string): Promise<string>;
	/** Deliver one locally gathered ICE candidate to `designator`'s peer. */
	candidate(designator: string, ice: string): void | Promise<void>;
	/** Register the sink for candidates the far peer trickles back, before the
	 * offer is sent. Returns a disposer the dial calls once the channel opens. */
	onCandidate(designator: string, sink: (ice: string) => void): () => void;
}

export class Host {
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
	// The vow table the drain's SETTLE/FAIL arms settle.
	readonly #vows = new Map<bigint, VowRow>();
	// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	readonly #unobserved: bigint[] = [];
	// DIAL actions are asynchronous after the C queue has consumed them. Retain
	// their executors until they report a terminal result; otherwise a detached
	// promise can disappear while its ticket and half-open channel remain live.
	readonly #dialTasks = new Map<Promise<void>, AbortController>();
	// Action drains may await transport I/O after popping native actions. Keep
	// every admitted drain under Host teardown so none can resume after native
	// Host storage is released.
	readonly #actionDrains = new Set<Promise<void>>();
	// The iroh reachability posture this host uses to redeem a *hint-less*
	// handoff give — one whose exporter location names the exporter by node id
	// alone. Starts at the generated ABI default (`Discovery`: n0 relays +
	// DNS/pkarr, the maximal-reach choice); a relay-policy deployment lowers it
	// to `DiscoveryNoRelay`. A hinted give always dials `Direct` and ignores
	// this.
	#redeemReachability: Reachability = IROH_REACH_REDEEM_DEFAULT as Reachability;
	// How this host reaches a `keyed-relay` peer — one that opens no socket and
	// holds an inbound socket at a relay under its key designator (ADR-0088).
	// Deployment configuration exactly like `#redeemReachability` above: null
	// until the application supplies the relay's rendezvous mapping, and a
	// `keyed-relay` dial refuses loud without it.
	#rendezvousUrl: ((designator: string) => string) | null = null;
	// How this host signals a `webrtc` peer it dials (ADR-0089). The same
	// deployment-configuration posture as the two fields above: null until the
	// application supplies the authority, and a `webrtc` dial refuses loud
	// without it.
	#signaling: SignalingAuthority | null = null;
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
		opts: {
			codec?: Codec;
			captpVersion?: CaptpVersion;
			features?: FeatureSet;
			context?: Context;
			frameCap?: number;
			localTurnBudget?: number;
		} = {},
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
		const context = opts.context ?? null;
		let contextRetained = false;
		if (context != null) {
			const contextRaw = retainContext(context);
			contextRetained = true;
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
		} else {
			checkHost(hostS.pancake_host_new(
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
		}
		this.#raw = outPointer(out);
		this.#finalizerState = {
			raw: this.#raw,
			behaviorIds: new Set(),
			context: contextRetained ? context : null,
		};
		this.hosted = new HostedBehaviorMap(this.#finalizerState.behaviorIds);
		hostFinalizer.register(this, this.#finalizerState, this);
		try {
			// The host's own key designator, which is what a partner names it by:
			// the live trace reports it as this host's endpoint so one peer stays
			// one node in a feed several producers share.
			traceAttachHost(this.#raw, this.designator());
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
					void host.kickActions();
				},
				scheduleDrain: (run) => setTimeout(run, 0),
			});
		} catch (err) {
			hostFinalizer.unregister(this);
			traceDetachHost(this.#raw);
			releaseHostState(this.#finalizerState);
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

	/** The native loop that owns this Host, or null for a byte-fed Host.
	 * Binding-internal: the dial executor routes a dial on a loop-owned Host
	 * onto that same loop (ADR-0112). */
	get driverLoop(): DriverLoopHandle | null {
		return this.#driverLoop;
	}

	/** Transfer native ownership to a DriverLoop after its ABI claim succeeds.
	 * The wrapper remains the sole JavaScript Host authority; only the loop may
	 * release the native handle after this point. Binding-internal. */
	attachDriverLoop(driverLoop: DriverLoopHandle): void {
		if (this.#raw === NULL || this.#releaseStarted || this.#driverLoop != null) {
			throw new PancakeError(INVALID_ARGUMENT, "host is not transferable");
		}
		hostFinalizer.unregister(this);
		this.#finalizerState.raw = NULL;
		this.#driverLoop = driverLoop;
	}

	/** Run one popped DIAL executor under this Host's terminal lifetime. The
	 * signal owns transport cancellation; retention alone is not ownership. */
	startDialTask(run: (signal: AbortSignal) => Promise<void>): void {
		if (this.#raw === NULL) return;
		const controller = new AbortController();
		// Defer invocation until after the task is registered. A callback that
		// synchronously releases this Host can therefore never create untracked
		// work between `run` entering and the map insertion below.
		const retained = Promise.resolve().then(() => {
			if (controller.signal.aborted) return;
			return run(controller.signal);
		}).catch(() => {})
			.finally(() => {
				this.#dialTasks.delete(retained);
			});
		this.#dialTasks.set(retained, controller);
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
			(err) =>
				this.#breakResolver(resolver, err instanceof Error ? err.message : String(err)),
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
		void this.kickActions();
	}

	#breakResolver(resolver: bigint, message: string): void {
		if (this.#raw === NULL) return;
		const msg = new TextEncoder().encode(message);
		// Best-effort: a resolver already consumed has nothing left to break.
		hostS.pancake_host_resolver_break(this.#raw, resolver, ab(msg), BigInt(msg.length));
		void this.kickActions();
	}

	release(): void {
		if (this.#raw === NULL || this.#releaseStarted) return;
		if (this.#driverLoop != null) {
			// The loop owns this handle: its close releases loop, sessions, and
			// host together, then runs `loopTeardown` on this wrapper.
			void this.#driverLoop.close();
			return;
		}
		this.#releaseStarted = true;
		const raw = this.#raw;
		// Whatever the ring still holds reaches the sink before the ring dies
		// with the host.
		traceDrainHost(raw);
		traceDetachHost(raw);
		hostFinalizer.unregister(this);
		// Teardown revokes callback reachability immediately. Native storage has
		// a longer lifetime: it remains behind every admitted async task below,
		// but no worker admitted before that barrier may begin another JS turn.
		for (const ctx of this.#finalizerState.behaviorIds) unregisterBehavior(ctx);
		this.#finalizerState.behaviorIds.clear();
		const dialTasks = [...this.#dialTasks.keys()];
		for (const controller of this.#dialTasks.values()) controller.abort();
		const actionDrains = [...this.#actionDrains];
		// Sessions first: each releases its own handle, and a handle outliving
		// the host it belongs to is a free of freed memory.
		const sessionCloses = this.closeSessions();
		this.#failOutstandingVows("host released");
		this.#raw = NULL;
		this.#releasePromise = (async () => {
			const settled = await Promise.allSettled([
				...dialTasks,
				...actionDrains,
				...sessionCloses,
			]);
			// A handshake that was already minting when cancellation began may
			// briefly have registered a Session. Its admission task now owns no
			// work, so this second sweep closes that last possible child.
			const lateSessions = await Promise.allSettled(this.closeSessions());
			this.drainParkedReleases();
			// `state.raw` is authoritative for native and Context ownership. The
			// wrapper's raw pointer was cleared above to reject further calls.
			if (this.#finalizerState.raw !== raw) return;
			releaseHostState(this.#finalizerState);
			this.#behaviorEntries.clear();
			this.#giftables.clear();
			this.#displacedGiftables.length = 0;
			this.hosted.clear();
			const failure = [...settled, ...lateSessions].find(
				(result): result is PromiseRejectedResult => result.status === "rejected",
			);
			if (failure != null) throw failure.reason;
		})();
	}

	/** Request terminal teardown and wait until every action drain, dial, and
	 * admission worker has stopped before the native Host is released. */
	async releaseAsync(): Promise<void> {
		if (this.#driverLoop != null) {
			await this.#driverLoop.close();
			return;
		}
		this.release();
		if (this.#releasePromise != null) await this.#releasePromise;
	}

	/** Retire callback reachability while the native Host is still readable.
	 * The allocation Context deliberately remains pinned until
	 * `finishLoopTeardown`, after the driver has freed the Host through it. */
	prepareLoopTeardown(): void {
		if (this.#raw === NULL) return;
		const raw = this.#raw;
		this.#releaseStarted = true;
		traceDrainHost(raw);
		traceDetachHost(raw);
		for (const ctx of this.#finalizerState.behaviorIds) unregisterBehavior(ctx);
		this.#finalizerState.behaviorIds.clear();
		this.#failOutstandingVows("host released");
		this.#raw = NULL;
		this.#behaviorEntries.clear();
		this.#giftables.clear();
		this.#displacedGiftables.length = 0;
		this.hosted.clear();
	}

	/** Release the Host's allocation Context after native driver release. */
	finishLoopTeardown(): void {
		const context = this.#finalizerState.context;
		this.#finalizerState.context = null;
		if (context != null) releaseContext(context);
	}

	[Symbol.dispose](): void {
		this.release();
	}

	async [Symbol.asyncDispose](): Promise<void> {
		await this.releaseAsync();
	}

	/** The iroh reachability posture used to redeem a hint-less handoff give
	 * (exporter named by node id alone). Binding-internal: the dial executor
	 * reads it when a give carries no direct-address hints. */
	get redeemReachability(): Reachability {
		return this.#redeemReachability;
	}

	/** Set the iroh reachability posture this host uses to redeem a *hint-less*
	 * handoff give (the exporter named by node id alone, with no direct-address
	 * hints). Defaults to `Discovery` (n0 relays + DNS/pkarr); set
	 * `DiscoveryNoRelay` to honor a no-relay deployment policy. A hinted give
	 * always dials `Direct` and ignores this. */
	setRedeemReachability(reachability: Reachability): void {
		this.#redeemReachability = reachability;
	}

	/** The configured `keyed-relay` rendezvous mapping, or null. Binding-
	 * internal: the dial executor reads it for a `keyed-relay` dial. */
	get rendezvousUrl(): ((designator: string) => string) | null {
		return this.#rendezvousUrl;
	}

	/** Configure how this host reaches a `keyed-relay` peer: map the peer's key
	 * designator to the WebSocket URL of the relay rendezvous leg that bridges
	 * onto its held inbound socket, e.g.
	 * `` (id) => `wss://example/relay?rendezvous=${id}` `` (ADR-0088). The
	 * keyed-relay sibling of `setRedeemReachability`: deployment configuration
	 * for reaching an exporter that opens no listener. Without it, a
	 * `keyed-relay` dial refuses loud. */
	setRendezvousUrl(url: (designator: string) => string): void {
		this.#rendezvousUrl = url;
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
		// The vow may be parked on a dial with no session of its own, which is
		// exactly the null-session row the vow table already admits.
		this.vowMinted(vow, null);
		void this.kickActions();
		const result = await this.awaitVow(vow);
		return asLiveRef(result, sturdyref);
	}

	/** The configured `webrtc` signaling authority, or null. Binding-internal:
	 * the dial executor reads it for a `webrtc` dial. */
	get signaling(): SignalingAuthority | null {
		return this.#signaling;
	}

	/** Configure how this host signals a `webrtc` peer it dials (ADR-0089): the
	 * language-level face of whatever signaling capability the application
	 * holds — a room's signaling object, a relay, any channel both parties
	 * reach. The `webrtc` sibling of `setRendezvousUrl`: a bare `webrtc`
	 * locator names a designator and carries no signaling route, so the
	 * authority is deployment configuration of the dialing host. Without it, a
	 * `webrtc` dial refuses loud. */
	setSignaling(signaling: SignalingAuthority): void {
		this.#signaling = signaling;
	}

	/** Retain and select this Host's complete acceptable location. Later
	 * sessions advertise it regardless of their transport; existing sessions
	 * retain the locator their hello signed. */
	setAdvertisedLocator(locator: Locator): void {
		withOwnedLocator(
			locator,
			(owned) =>
				checkHost(hostS.pancake_host_set_advertised_locator(this.#raw, owned.borrowView())),
		);
	}

	/** Install this Host's default advertised locator for `transport` without displacing an
	 * acceptable location selected for another transport. Binding-internal. */
	ensureAdvertisedLocator(transport: string): void {
		const bytes = utf8Encoder.encode(transport);
		checkHost(hostS.pancake_host_ensure_advertised_locator(
			this.#raw,
			ab(bytes),
			BigInt(bytes.length),
		));
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
		void this.kickActions();
	}

	/** Publish `behavior` under a freshly minted durable swiss name and return
	 * that name — the swiss to place in a sturdyref beside this host's own
	 * locator (ADR-0098). Unpredictable, never reassigned, structurally
	 * disjoint from every mutable alias, removable only through
	 * {@link unpublishDurable}. Entropy is drawn here, from the platform RNG. */
	publishDurable(behavior: Behavior): string {
		const ctx = this.registerHostedBehavior({ run: behavior, resolveLocal: null });
		const entropy = crypto.getRandomValues(new Uint8Array(16));
		const swiss = new Uint8Array(64);
		let written: number;
		try {
			written = hostS.pancake_host_publish_durable(
				this.#raw,
				ab(entropy),
				BigInt(entropy.length),
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
		void this.kickActions();
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
		void this.kickActions();
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
		void this.kickActions();
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

	/** Stop tracking a released session. Binding-internal. */
	unregisterSession(ptr: Ptr): void {
		this.#sessions.delete(ptr);
	}

	/** Look up a live session by its session address. Binding-internal: the
	 * action drain's FLUSH/CLOSE arms route through it. */
	getSession(ptr: Ptr): Session | undefined {
		return this.#sessions.get(ptr);
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
		const out = new Uint8Array(8);
		checkHost(hostS.pancake_host_reference_exporter(this.#raw, ab(refBuf), ab(out)));
		const ptr = outPointer(out);
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

	/** Close every session this host holds — the ones an application opened
	 * and the ones the host dialed for redeems alike. Each close releases that
	 * session's handle, so this must run before the host handle goes.
	 * Binding-internal: `release` sweeps them. */
	closeSessions(): Promise<void>[] {
		return [...this.#sessions.values()].map((session) => session.closeTransport());
	}

	// ── The vow table ──────────────────────────────────────────────────────────

	/** Record a freshly minted vow so the drain can route its completion. Must
	 * run in the same synchronous block as the minting FFI call, so no drain
	 * can pop the completion first. Binding-internal. */
	vowMinted(vow: bigint, session: Session | null): void {
		this.#vows.set(vow, { session, state: { tag: "minted" } });
	}

	/** The vow's eventual outcome: the fulfilled wire value, or a rejection —
	 * `VowBroken` for a partner break, the typed CLOSED `PancakeError` when the
	 * settle was the disconnect's own break. Settles immediately from the
	 * recorded state when the outcome already landed. Binding-internal. */
	awaitVow(vow: bigint): Promise<Argument> {
		const row = this.#vows.get(vow);
		if (row === undefined) {
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

	#failOutstandingVows(message: string): void {
		for (const row of this.#vows.values()) {
			if (row.state.tag === "awaited") {
				row.state.waiter.reject(new PancakeError(CLOSED, message));
			}
		}
		this.#vows.clear();
		this.#unobserved.length = 0;
	}

	/** Whether the vow's home connection is closing — used by the FAIL arm to
	 * classify disconnect breaks as CLOSED. Binding-internal. */
	vowSessionClosing(vow: bigint): boolean {
		return this.#vows.get(vow)?.session?.closing ?? false;
	}

	// ── The action drain (the one loop rule) ──────────────────────────────────

	/** Park a C release the host refused inside a behavior callback; the next
	 * drain — the head of `kickActions`, or the feed's unwind — runs it where
	 * it is legal. Binding-internal. */
	parkRelease(release: () => void): void {
		this.#parkedReleases.push(release);
	}

	trackGcImport(ref: Ref): Ref {
		return this.#gc.trackImport(ref);
	}

	drainGc(): void {
		this.#gc.drainGc();
	}

	disarmGc(ref: Ref): void {
		this.#gc.disarm(ref);
	}

	/** Run every parked release, always outside a callback frame where the C
	 * tier accepts them. Called at the head of `kickActions` and right after a
	 * feed returns. Binding-internal. */
	drainParkedReleases(): void {
		if (insideTurn()) return;
		while (this.#parkedReleases.length > 0) {
			const pending = this.#parkedReleases.splice(0);
			for (const release of pending) release();
		}
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
		// mid-turn Host.release cleared `#raw` while parking the actual free.
		this.drainParkedReleases();
		if (this.#releaseStarted || this.#raw === NULL) return Promise.resolve();

		// Register before execution starts. A drain can synchronously cause Host
		// teardown through an action it runs; deferring its body to a microtask
		// closes the admission window before that body can make progress.
		const drain = Promise.resolve().then(() => this.#drainActions());
		this.#actionDrains.add(drain);
		const retire = () => {
			this.#actionDrains.delete(drain);
		};
		void drain.then(retire, retire);
		// Detached kicks are common at effect-producing sync APIs. Mark their
		// rejection observed without changing the promise awaited by direct
		// callers, which still receives a genuine drain failure.
		void drain.catch(() => {});
		return drain;
	}

	async #drainActions(): Promise<void> {
		if (this.#releaseStarted || this.#raw === NULL) return;
		// The live trace's capture ring drains on the same unwind as the action
		// queue: both are host effects the embedder pops, and popping them
		// together is what keeps a queued fact from waiting on the next verb.
		traceDrainHost(this.#raw);
		while (true) {
			if (this.#releaseStarted || this.#raw === NULL) return;
			const { actions, yielded } = parkActions(this);
			if (actions.length === 0 && !yielded) return;
			for (const action of actions) {
				if (this.#releaseStarted || this.#raw === NULL) return;
				// One failing action must not strand the rest of the drain: a
				// FLUSH to a session whose socket just died throws here while
				// the actions behind it belong to other, live sessions. The
				// failed session tears itself down through its own serve loop
				// (a DIAL failure is reported to the core inside the arm).
				try {
					await runAction(this, action);
				} catch {
					// swallowed so the drain reaches every remaining action
				}
			}
			if (yielded) {
				if (this.#releaseStarted || this.#raw === NULL) return;
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
