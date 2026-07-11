// The CapTP node — pancake's analogue of Goblins' `mycapn`, one per node —
// over the byte-fed host archive (libpancake_driver, ADR-0072). The
// `PancakeHost` owns every decision: the retained identity, the shared gift
// registry, routing, transparent three-party redemption, and the gifter half's
// origination. What lives here is only what the embedder contract leaves to
// the binding: the host handle, the conn-pointer → `Connection` registry the
// action drain routes by, the vow table the drain's SETTLE/FAIL arms settle,
// the serialized action drain itself, gift-id entropy, and the iroh redeem
// posture the dial executor reads. The pump and the dial executor live in
// `connection.ts`, which owns the `Connection` they act on. `mod.ts`
// re-exports the public `Node`.

import { driverS } from "./internal/ffi/driver.ts";
import { NULL, type Ptr } from "./internal/ffi/runtime.ts";
import { ab, outPointer, readBytes } from "./internal/seam.ts";
import {
	CLOSED,
	HOST_ACTION_CLOSE,
	HOST_ACTION_CONN_OFF,
	HOST_ACTION_DESIGNATOR_LEN_OFF,
	HOST_ACTION_DESIGNATOR_OFF,
	HOST_ACTION_DIAL,
	HOST_ACTION_DIRECT_ADDRESSES_HINT_LEN_OFF,
	HOST_ACTION_DIRECT_ADDRESSES_HINT_OFF,
	HOST_ACTION_FAIL,
	HOST_ACTION_FLUSH,
	HOST_ACTION_KIND_OFF,
	HOST_ACTION_LOCATOR_LEN_OFF,
	HOST_ACTION_LOCATOR_OFF,
	HOST_ACTION_MESSAGE_LEN_OFF,
	HOST_ACTION_MESSAGE_OFF,
	HOST_ACTION_NEED_GIFT_ID,
	HOST_ACTION_SETTLE,
	HOST_ACTION_SIZE,
	HOST_ACTION_TICKET_OFF,
	HOST_ACTION_TRANSPORT_LEN_OFF,
	HOST_ACTION_TRANSPORT_OFF,
	HOST_ACTION_VALUE_OFF,
	INVALID_ARGUMENT,
	WOULD_BLOCK,
} from "./internal/abi.ts";
import { checkHost, PancakeError, VowBroken } from "./errors.ts";
import { type Argument, type Behavior, type Codec, codecId, Reachability } from "./value.ts";
import { readArg } from "./codec.ts";
import { insideTurn, registerBehavior, trampolinePointer } from "./trampoline.ts";
import type { Context } from "./context.ts";
import { Connection } from "./connection.ts";

// Every connection's maximum admissible frame, mirroring the engine's default
// session limit; the core's stream delimiter (`pancake_host_conn_feed_bytes`)
// enforces it while it scans, so a hostile stream cannot grow an inbox past it.
const HOST_FRAME_CAP = 2 ** 20;

// One encoder/decoder pair for the whole module: both are stateless here, and
// the action drain decodes views on every pop.
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder();

// Frees a raw host whose `Node` wrapper the GC reclaimed. The host owns every
// still-open connection, the vow map, parked actions, and the giftable rows,
// so a dropped wrapper must not leak the native handle.
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
	/** The connection the vow was minted on, for closed-vs-broken classification;
	 * null for a vow whose home is not a single connection. */
	conn: Connection | null;
	state: "pending" | { ok: Argument } | { err: PancakeError };
	waiter: { resolve: (v: Argument) => void; reject: (e: PancakeError) => void } | null;
}

/** Cap on stored outcomes whose vow is never awaited, so the store cannot grow
 * without bound; the oldest un-awaited outcome is evicted at the cap. */
const MAX_UNOBSERVED_OUTCOMES = 1024;

// One popped embedder action, a discriminated union over the action kind so
// each arm carries exactly the fields the C struct fills for it. Every
// borrowed view is copied out (and a SETTLE's value lifted) before the next
// `pancake_host_next_action` call can free them.
type HostAction =
	| {
		kind: typeof HOST_ACTION_DIAL;
		ticket: bigint;
		locator: string;
		transport: string;
		designator: string;
		directAddressesHint: string;
	}
	| { kind: typeof HOST_ACTION_FLUSH; conn: Ptr }
	| { kind: typeof HOST_ACTION_CLOSE; conn: Ptr }
	| { kind: typeof HOST_ACTION_NEED_GIFT_ID; ticket: bigint }
	| { kind: typeof HOST_ACTION_SETTLE; ticket: bigint; value: Argument }
	| { kind: typeof HOST_ACTION_FAIL; ticket: bigint; message: string };

/** The CapTP node: one identity, one gift registry, one routing and redeem
 * authority, shared by every connection minted against it. The cross-node
 * machinery lives in the Zig core behind `libpancake_driver` (ADR-0072); this
 * is the host-idiom residue over it — the `Connection` registry, the vow
 * table, the serialized action drain that performs the I/O the host asks for
 * (dial, flush, settle, entropy), and the iroh redeem posture. */
export class Node {
	/** The node's retained identity seed (32 bytes), reused for every dial. */
	readonly seed: Uint8Array;
	/** The wire grammar every connection this node mints negotiates in. */
	readonly codec: Codec;
	#raw: Ptr;
	// Every live connection by its PancakeHostConn address, so a FLUSH action
	// routes to the transport that owns the bytes and a dialed exporter stays
	// reachable for teardown.
	readonly #connections = new Map<Ptr, Connection>();
	// The vow table the drain's SETTLE/FAIL arms settle.
	readonly #vows = new Map<bigint, VowRow>();
	// FIFO of settled-but-unobserved vow ids, for the eviction cap.
	readonly #unobserved: bigint[] = [];
	// The iroh reachability posture this node uses to redeem a *hint-less*
	// handoff give — one whose exporter location names the exporter by node id
	// alone. Defaults to `Discovery` (n0 relays + DNS/pkarr, the maximal-reach
	// choice); a relay-policy deployment lowers it to `DiscoveryNoRelay`. A
	// hinted give always dials `Direct` and ignores this.
	#redeemReachability: Reachability = Reachability.Discovery;

	/** A node with identity `seed` (32 bytes; omitted draws a fresh random one —
	 * entropy at the binding boundary, never inside the sans-io host). `codec`
	 * picks the wire grammar every connection negotiates in (`"syrup"` by
	 * default); `context` routes every byte the host owns through a
	 * caller-supplied allocation scope. */
	constructor(
		seed?: Uint8Array,
		opts: { codec?: Codec; context?: Context } = {},
	) {
		this.seed = seed ?? crypto.getRandomValues(new Uint8Array(32));
		this.codec = opts.codec ?? "syrup";
		const out = new Uint8Array(8);
		if (opts.context !== undefined) {
			checkHost(driverS.pancake_host_new_in(
				opts.context.pointer,
				ab(this.seed),
				32n,
				BigInt(HOST_FRAME_CAP),
				1,
				codecId(this.codec),
				ab(out),
			));
		} else {
			checkHost(driverS.pancake_host_new(
				ab(this.seed),
				32n,
				BigInt(HOST_FRAME_CAP),
				1,
				codecId(this.codec),
				ab(out),
			));
		}
		this.#raw = outPointer(out);
		hostFinalizer.register(this, this.#raw, this);
	}

	/** The raw PancakeHost handle. Binding-internal: `Connection` mints and
	 * drives connections against it. */
	get raw(): Ptr {
		return this.#raw;
	}

	/** Release the host and everything it owns — every still-open connection
	 * (each parked vow breaks inside), the vow map, parked actions, and the
	 * giftable rows. Usually unnecessary (a dropped `Node` is reclaimed by the
	 * runtime's collector), but a node created in a caller-supplied `Context`
	 * must be released before that context. Idempotent. */
	release(): void {
		if (this.#raw === NULL) return;
		hostFinalizer.unregister(this);
		driverS.pancake_host_release(this.#raw);
		this.#raw = NULL;
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

	/** Set the iroh reachability posture this node uses to redeem a *hint-less*
	 * handoff give (the exporter named by node id alone, with no direct-address
	 * hints). Defaults to `Discovery` (n0 relays + DNS/pkarr); set
	 * `DiscoveryNoRelay` to honor a no-relay deployment policy. A hinted give
	 * always dials `Direct` and ignores this. */
	setRedeemReachability(reachability: Reachability): void {
		this.#redeemReachability = reachability;
	}

	/** Record the designator this node's dials sign as their own dialable
	 * address (a node that also listens); `listen`/`listenIroh` set it to the
	 * bound address so a partner's crossed-hellos table can recognize this
	 * node. Binding-internal. */
	setSelfDesignator(designator: string): void {
		const bytes = utf8Encoder.encode(designator);
		checkHost(driverS.pancake_host_set_self_designator(
			this.#raw,
			ab(bytes),
			BigInt(bytes.length),
		));
	}

	/** Publish `behavior` under `name` on every connection of this node — those
	 * open now and any accepted later — so a recipient can withdraw a gift
	 * naming it on a connection it dialed itself (the exporter half of a
	 * three-party handoff, ADR-0009). The replay onto future connections is
	 * host-internal. Returns nothing — the gift's `Ref` is what the gifter
	 * passes on. */
	publishGiftable(name: string, behavior: Behavior): void {
		// A giftable is bound to no single connection: its forwards always go
		// through the host, and a turn it runs belongs to whichever connection
		// the deliver arrived on.
		const ctx = registerBehavior({ run: behavior, conn: null, resolveLocal: null });
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

	/** Track a live connection by its conn address. Binding-internal: the
	 * `Connection` constructor calls it. */
	registerConnection(ptr: Ptr, conn: Connection): void {
		this.#connections.set(ptr, conn);
	}

	/** Stop tracking a released connection. Binding-internal. */
	unregisterConnection(ptr: Ptr): void {
		this.#connections.delete(ptr);
	}

	/** Close every exporter connection this node dialed for redeems.
	 * Binding-internal: `Connection.close` sweeps them. */
	closeExporters(): void {
		for (const conn of [...this.#connections.values()]) {
			if (conn.nodeDialed) conn.closeTransport();
		}
	}

	// ── The vow table ──────────────────────────────────────────────────────────

	/** Record a freshly minted vow so the drain can route its completion. Must
	 * run in the same synchronous block as the minting FFI call, so no drain
	 * can pop the completion first. Binding-internal. */
	vowMinted(vow: bigint, conn: Connection | null): void {
		this.#vows.set(vow, { conn, state: "pending", waiter: null });
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

	// The drain's settle arms: fire the waiter, or record the outcome for a
	// late observation (bounded FIFO — an outcome nobody ever awaits is evicted
	// at the cap).
	#settleVow(vow: bigint, outcome: { ok: Argument } | { err: PancakeError }): void {
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

	// ── The action drain (the one loop rule) ──────────────────────────────────

	/** Run the action drain to empty, honoring each action, and resolve when
	 * the queue is dry. Reentrant on purpose, the async spelling of the Racket
	 * binding's reentrant node lock: the DIAL arm's dial executor establishes a
	 * whole new connection *inside* an action, and that establish must itself
	 * drain (its start-session FLUSH) — a single-flighted drain would await its
	 * own completion there. Each action is popped exactly once (`#nextAction`
	 * is synchronous), so overlapping drains split the queue between them
	 * rather than double-running anything. A no-op inside a hosted turn: the
	 * host refuses the driving verbs there, and everything the turn enqueued
	 * pumps when the enclosing feed unwinds into this same drain.
	 * Binding-internal. */
	async kickActions(): Promise<void> {
		if (insideTurn() || this.#raw === NULL) return;
		while (true) {
			const action = this.#nextAction();
			if (action === null) return;
			// One failing action must not strand the rest of the drain: a FLUSH
			// to a connection whose socket just died throws here while the
			// actions behind it belong to other, live connections. The failed
			// connection tears itself down through its own serve loop (a DIAL
			// failure is reported to the core inside the arm).
			try {
				await this.#runAction(action);
			} catch {
				// swallowed so the drain reaches every remaining action
			}
		}
	}

	// Pop the next embedder action, decoded per kind so each arm copies out only
	// the borrowed views the C struct fills for it — a SETTLE's PancakeArgument
	// lifted whole — before anything else can call `pancake_host_next_action`
	// (which frees them). Null when the queue is dry.
	#nextAction(): HostAction | null {
		const buf = new Uint8Array(HOST_ACTION_SIZE);
		const rc = driverS.pancake_host_next_action(this.#raw, ab(buf));
		if (rc === WOULD_BLOCK) return null;
		checkHost(rc);
		const dv = new DataView(buf.buffer);
		const kind = dv.getUint32(HOST_ACTION_KIND_OFF, true);
		const ticket = dv.getBigUint64(HOST_ACTION_TICKET_OFF, true);
		const view = (off: number, lenOff: number): string =>
			utf8Decoder.decode(
				readBytes(dv.getBigUint64(off, true), dv.getBigUint64(lenOff, true)),
			);
		switch (kind) {
			case HOST_ACTION_DIAL:
				return {
					kind,
					ticket,
					locator: view(HOST_ACTION_LOCATOR_OFF, HOST_ACTION_LOCATOR_LEN_OFF),
					transport: view(HOST_ACTION_TRANSPORT_OFF, HOST_ACTION_TRANSPORT_LEN_OFF),
					designator: view(HOST_ACTION_DESIGNATOR_OFF, HOST_ACTION_DESIGNATOR_LEN_OFF),
					directAddressesHint: view(
						HOST_ACTION_DIRECT_ADDRESSES_HINT_OFF,
						HOST_ACTION_DIRECT_ADDRESSES_HINT_LEN_OFF,
					),
				};
			case HOST_ACTION_FLUSH:
			case HOST_ACTION_CLOSE:
				return { kind, conn: dv.getBigUint64(HOST_ACTION_CONN_OFF, true) };
			case HOST_ACTION_NEED_GIFT_ID:
				return { kind, ticket };
			case HOST_ACTION_SETTLE:
				return { kind, ticket, value: readArg(dv, HOST_ACTION_VALUE_OFF) };
			case HOST_ACTION_FAIL:
				return {
					kind,
					ticket,
					message: view(HOST_ACTION_MESSAGE_OFF, HOST_ACTION_MESSAGE_LEN_OFF),
				};
			default:
				throw new PancakeError(
					INVALID_ARGUMENT,
					`unknown host action kind ${kind}`,
				);
		}
	}

	// The executor is deliberately dumb: every decision was already made in the
	// core; each arm is pure I/O or marshalling.
	async #runAction(action: HostAction): Promise<void> {
		switch (action.kind) {
			case HOST_ACTION_DIAL: {
				let conn: Connection;
				try {
					conn = await Connection.dialExporter(
						action.locator,
						action.transport,
						action.designator,
						action.directAddressesHint,
						this,
					);
				} catch (err) {
					// The host turns a failed dial into broken redeems.
					const reason = utf8Encoder.encode(
						err instanceof Error ? err.message : String(err),
					);
					checkHost(driverS.pancake_host_dial_failed(
						this.#raw,
						action.ticket,
						ab(reason),
						BigInt(reason.length),
					));
					return;
				}
				conn.nodeDialed = true;
				// Keep the exporter connection pumped: the withdraw's resolution —
				// and any later routed traffic — rides it immediately.
				conn.serve().catch(() => {});
				checkHost(driverS.pancake_host_dialed(this.#raw, action.ticket, conn.raw));
				return;
			}
			case HOST_ACTION_FLUSH:
				await this.#connections.get(action.conn)?.flushOutbound();
				return;
			case HOST_ACTION_CLOSE: {
				// The host condemned the connection mid-pump (local turn budget
				// exceeded): write its queued resource_exhausted abort, then close
				// the transport and release the conn shell.
				const conn = this.#connections.get(action.conn);
				if (conn === undefined) return;
				try {
					await conn.flushOutbound();
				} catch {
					// best-effort: the session is ending either way
				}
				conn.closeTransport();
				return;
			}
			case HOST_ACTION_NEED_GIFT_ID: {
				// Entropy is a host effect, drawn only when a reply actually becomes
				// a gift.
				const id = crypto.getRandomValues(new Uint8Array(32));
				checkHost(driverS.pancake_host_provide_gift_id(
					this.#raw,
					action.ticket,
					ab(id),
					32n,
				));
				return;
			}
			case HOST_ACTION_SETTLE:
				this.#settleVow(action.ticket, { ok: action.value });
				return;
			case HOST_ACTION_FAIL: {
				// A FAIL fired by the disconnect's own break (the connection is
				// closing) classifies as the typed CLOSED, not a partner break.
				const closing = this.#vows.get(action.ticket)?.conn?.closing ?? false;
				this.#settleVow(action.ticket, {
					err: closing
						? new PancakeError(CLOSED, action.message)
						: new VowBroken(action.message),
				});
				return;
			}
		}
	}
}
