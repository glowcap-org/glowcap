// The CapTP host — multi-session CapTP product over the byte-fed host archive
// (libpancake_driver, ADR-0072). Goblins' `mycapn` is two roles: the endpoint
// ≈ this `Host`, the router tables ≈ `engine.Node` that the host owns — never
// a single-type equation. The `PancakeHost` owns every decision: the retained
// identity, the shared gift registry, routing, transparent three-party
// redemption, and the gifter half's origination. What lives here is only what
// the embedder contract leaves to the binding: the host handle, the
// session-pointer → `Session` registry the action drain routes by, the vow table
// the drain's SETTLE/FAIL arms settle, the serialized action drain itself,
// gift-id entropy, and the iroh redeem posture the dial executor reads. The
// action decode+execute switch lives in `action.ts`; the pump lives in
// `pump.ts`; the dial executor lives in `dial.ts`. `session.ts` owns the
// `Session` they act on. `mod.ts` re-exports the public `Host`.

import { driverS } from "./internal/ffi/driver.ts";
import { NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outPointer } from "./internal/seam.ts";
import { CLOSED, DEFAULT_FRAME_CAP } from "./internal/abi.ts";
import { checkHost, PancakeError } from "./errors.ts";
import { type Argument, type Behavior, type Codec, codecId, Reachability } from "./value.ts";
import { insideTurn, registerBehavior, trampolinePointer } from "./trampoline.ts";
import type { Context } from "./context.ts";
import { Session } from "./session.ts";
import { dialExporter as dialExporterFn } from "./dial.ts";
import { popAction, runAction } from "./action.ts";

// Every connection's maximum admissible frame; mirrors PANCAKE_DEFAULT_FRAME_CAP.
const HOST_FRAME_CAP = DEFAULT_FRAME_CAP;

// One encoder/decoder pair for the whole module: both are stateless here.
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

// Frees a raw host whose `Host` wrapper the GC reclaimed. The host owns every
// still-open session, the vow map, parked actions, and the giftable rows,
// so a dropped wrapper must not leak the native handle. Mid-turn releases park
// on the live Host instead; the finalizer path only runs after the wrapper is gone.
const hostFinalizer = new FinalizationRegistry<Ptr>((raw) => {
	driverS.pancake_host_release(raw);
});

// A host vow's row: registered the instant the vow is minted (the mint IS the
// registration), settled by the drain's SETTLE/FAIL arms. An outcome that
// lands before anyone awaits is stored, so a late observation settles from
// the recorded state instead of hanging — and no rejection is materialized
// until a waiter exists, so an unobserved broken answer never raises an
// unhandled rejection.
interface VowRow {
	/** The session the vow was minted on, for closed-vs-broken classification;
	 * null for a vow whose home is not a single session. */
	session: Session | null;
	state: "pending" | { ok: Argument } | { err: PancakeError };
	waiter: { resolve: (v: Argument) => void; reject: (e: PancakeError) => void } | null;
}

/** Cap on stored outcomes whose vow is never awaited, so the store cannot grow
 * without bound; the oldest un-awaited outcome is evicted at the cap. */
const MAX_UNOBSERVED_OUTCOMES = 1024;

/** The CapTP host: one identity, one gift registry, one routing and redeem
 * authority, shared by every session minted against it. Owns `engine.Node`
 * (the sans-io handoff router). The cross-host machinery lives in the Zig
 * core behind `libpancake_driver` (ADR-0072); this is the host-idiom residue
 * over it — the `Session` registry, the vow table, the serialized action
 * drain that performs the I/O the host asks for (dial, flush, settle,
 * entropy), and the iroh redeem posture. */
export class Host {
	/** The host's retained identity seed (32 bytes), reused for every dial. */
	readonly seed: Uint8Array;
	/** The wire grammar every session this host mints negotiates in. */
	readonly codec: Codec;
	#raw: Ptr;
	// Every live session by its PancakeHostSession address, so a FLUSH action
	// routes to the transport that owns the bytes and a dialed exporter stays
	// reachable for teardown.
	readonly #sessions = new Map<Ptr, Session>();
	// The vow table the drain's SETTLE/FAIL arms settle.
	readonly #vows = new Map<bigint, VowRow>();
	// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	readonly #unobserved: bigint[] = [];
	// The iroh reachability posture this host uses to redeem a *hint-less*
	// handoff give — one whose exporter location names the exporter by node id
	// alone. Defaults to `Discovery` (n0 relays + DNS/pkarr, the maximal-reach
	// choice); a relay-policy deployment lowers it to `DiscoveryNoRelay`. A
	// hinted give always dials `Direct` and ignores this.
	#redeemReachability: Reachability = Reachability.Discovery;
	// Releases the C tier refused inside a behavior callback park here
	// (`pancake_host_session_release` / `pancake_host_release` are refused
	// mid-turn); the drain runs them once the enclosing feed unwinds, so a
	// mid-turn close never leaks its C handle. Mirrors Python/Rust.
	readonly #parkedReleases: Array<() => void> = [];

	/** A host with identity `seed` (32 bytes; omitted draws a fresh random one —
	 * entropy at the binding boundary, never inside the sans-io host). `codec`
	 * picks the wire grammar every session negotiates in (`"syrup"` by
	 * default); `context` routes every byte the host owns through a
	 * caller-supplied allocation scope; `localTurnBudget` is `0` for unbounded
	 * (the default) or a nonzero cap on local-turn amplification per drive
	 * (ADR-0076). */
	constructor(
		seed?: Uint8Array,
		opts: { codec?: Codec; context?: Context; localTurnBudget?: number } = {},
	) {
		this.seed = seed ?? crypto.getRandomValues(new Uint8Array(32));
		this.codec = opts.codec ?? "syrup";
		const out = new Uint8Array(8);
		const localTurnBudget = opts.localTurnBudget ?? 0;
		if (opts.context !== undefined) {
			checkHost(driverS.pancake_host_new_in(
				opts.context.pointer,
				ab(this.seed),
				32n,
				BigInt(HOST_FRAME_CAP),
				1,
				codecId(this.codec),
				localTurnBudget,
				ab(out),
			));
		} else {
			checkHost(driverS.pancake_host_new(
				ab(this.seed),
				32n,
				BigInt(HOST_FRAME_CAP),
				1,
				codecId(this.codec),
				localTurnBudget,
				ab(out),
			));
		}
		this.#raw = outPointer(out);
		hostFinalizer.register(this, this.#raw, this);
	}

	/** The raw PancakeHost handle. Binding-internal: `Session` mints and
	 * drives sessions against it. */
	get raw(): Ptr {
		return this.#raw;
	}

	/** Release the host and everything it owns — every still-open session
	 * (each parked vow breaks inside), the vow map, parked actions, and the
	 * giftable rows. Usually unnecessary (a dropped `Host` is reclaimed by the
	 * runtime's collector), but a host created in a caller-supplied `Context`
	 * must be released before that context. Idempotent. */
	release(): void {
		if (this.#raw === NULL) return;
		hostFinalizer.unregister(this);
		const raw = this.#raw;
		this.#raw = NULL;
		if (insideTurn()) {
			this.parkRelease(() => driverS.pancake_host_release(raw));
		} else {
			driverS.pancake_host_release(raw);
		}
	}

	[Symbol.dispose](): void {
		this.release();
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

	/** Record the designator this host's dials sign as their own dialable
	 * address (a host that also listens); `listen`/`listenIroh` set it to the
	 * bound address so a partner's crossed-hellos table can recognize this
	 * host. Binding-internal. */
	setSelfDesignator(designator: string): void {
		const bytes = utf8Encoder.encode(designator);
		checkHost(driverS.pancake_host_set_self_designator(
			this.#raw,
			ab(bytes),
			BigInt(bytes.length),
		));
	}

	/** The canonical key designator (64 lowercase hex digits) for this host's
	 * identity seed — what a keyed-tcp locator names as its designator
	 * (ADR-0075). */
	designator(): string {
		const out = new Uint8Array(64);
		checkHost(driverS.pancake_host_designator_from_seed(
			ab(this.seed),
			BigInt(this.seed.length),
			ab(out),
			BigInt(out.length),
		));
		return utf8Decoder.decode(out);
	}

	/** Publish `behavior` under `name` on every session of this host — those
	 * open now and any accepted later — so a recipient can withdraw a gift
	 * naming it on a session it dialed itself (the exporter half of a
	 * three-party handoff, ADR-0009). The replay onto future sessions is
	 * host-internal. Returns nothing — the gift's `Ref` is what the gifter
	 * passes on. */
	publishGiftable(name: string, behavior: Behavior): void {
		// A giftable is bound to no single session: its forwards always go
		// through the host, and a turn it runs belongs to whichever session
		// the deliver arrived on.
		const ctx = registerBehavior({ run: behavior, session: null, resolveLocal: null });
		const bytes = utf8Encoder.encode(name);
		checkHost(driverS.pancake_host_publish(
			this.#raw,
			ab(bytes),
			BigInt(bytes.length),
			trampolinePointer(),
			ctx,
			NULL,
		));
		void this.kickActions();
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

	/** Close every exporter connection this host dialed for redeems.
	 * Binding-internal: `Session.close` sweeps them. */
	closeExporters(): void {
		for (const session of [...this.#sessions.values()]) {
			if (session.hostDialed) session.closeTransport();
		}
	}

	/** Dial an exporter for a redeem (ActionHost). Binding-internal. */
	dialExporter(
		transport: string,
		designator: string,
		directAddressesHint: string,
	): Promise<Session> {
		return dialExporterFn(transport, designator, directAddressesHint, this);
	}

	// ── The vow table ──────────────────────────────────────────────────────────

	/** Record a freshly minted vow so the drain can route its completion. Must
	 * run in the same synchronous block as the minting FFI call, so no drain
	 * can pop the completion first. Binding-internal. */
	vowMinted(vow: bigint, session: Session | null): void {
		this.#vows.set(vow, { session, state: "pending", waiter: null });
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
		if (row.state === "pending") {
			return new Promise<Argument>((resolve, reject) => {
				row.waiter = { resolve, reject };
			});
		}
		this.#vows.delete(vow);
		return "ok" in row.state ? Promise.resolve(row.state.ok) : Promise.reject(row.state.err);
	}

	/** The drain's settle arms: fire the waiter, or record the outcome for a
	 * late observation (bounded FIFO — an outcome nobody ever awaits is evicted
	 * at the cap). Binding-internal: `action.ts` calls it. */
	settleVow(vow: bigint, outcome: { ok: Argument } | { err: PancakeError }): void {
		const row = this.#vows.get(vow);
		if (row === undefined) return; // an outcome nobody registered for
		if (row.waiter !== null) {
			this.#vows.delete(vow);
			if ("ok" in outcome) row.waiter.resolve(outcome.ok);
			else row.waiter.reject(outcome.err);
			return;
		}
		row.state = outcome;
		this.#unobserved.push(vow);
		while (this.#unobserved.length > MAX_UNOBSERVED_OUTCOMES) {
			const oldest = this.#unobserved.shift()!;
			const stale = this.#vows.get(oldest);
			// Only evict a row still parked unobserved; an observed one is gone.
			if (stale !== undefined && stale.state !== "pending" && stale.waiter === null) {
				this.#vows.delete(oldest);
			}
		}
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

	/** Run every parked release, always outside a callback frame where the C
	 * tier accepts them. Called at the head of `kickActions` and right after a
	 * feed returns. Binding-internal. */
	drainParkedReleases(): void {
		if (insideTurn()) return;
		while (this.#parkedReleases.length > 0) {
			this.#parkedReleases.pop()!();
		}
	}

	/** How many releases are parked on this host — test observability for the
	 * mid-turn close park. Binding-internal. */
	pendingReleaseCount(): number {
		return this.#parkedReleases.length;
	}

	/** Run the action drain to empty, honoring each action, and resolve when
	 * the queue is dry. Reentrant on purpose, the async spelling of the Racket
	 * binding's reentrant host lock: the DIAL arm's dial executor establishes a
	 * whole new session *inside* an action, and that establish must itself
	 * drain (its start-session FLUSH) — a single-flighted drain would await its
	 * own completion there. Each action is popped exactly once (`popAction`
	 * is synchronous), so overlapping drains split the queue between them
	 * rather than double-running anything. A no-op inside a hosted turn: the
	 * host refuses the driving verbs there, and everything the turn enqueued
	 * pumps when the enclosing feed unwinds into this same drain.
	 * Binding-internal. */
	async kickActions(): Promise<void> {
		if (insideTurn()) return;
		// Parked releases run first — before the raw-handle check, because a
		// mid-turn Host.release cleared `#raw` while parking the actual free.
		this.drainParkedReleases();
		if (this.#raw === NULL) return;
		while (true) {
			const action = popAction(this);
			if (action === null) return;
			// One failing action must not strand the rest of the drain: a FLUSH
			// to a session whose socket just died throws here while the
			// actions behind it belong to other, live sessions. The failed
			// session tears itself down through its own serve loop (a DIAL
			// failure is reported to the core inside the arm).
			try {
				await runAction(this, action);
			} catch {
				// swallowed so the drain reaches every remaining action
			}
		}
	}
}
