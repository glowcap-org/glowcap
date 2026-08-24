/**
 * Live-feed converter — the epoch and replay envelope around one
 * record's effect on the stage (`apply.ts`). The wire record
 * shape and field readers live in `record.ts`. The CapTP
 * consumer that delivers those records is `connection.ts`.
 *
 * Each record is one JSON object with `v: 1` and a `kind`.
 * The kinds this reads are the `ocapn.*` family, which a producer emits
 * about the protocol it is speaking, and the `trace.*` family, which an
 * endpoint emits about the stream itself. A kind outside those is
 * ignored rather than guessed at.
 */

import type { TimelineEvent } from "../timeline.ts";
import { applyEvent, scopeOf } from "./apply.ts";
import { type BaseTimelineEvent, nonEmptyStringFromWire, numberFromWire, stringFromWire } from "./record.ts";
import { StageLedger, wireKeyFor } from "../stage-ledger.ts";

/** What one feed remembers between records. Named rather than threaded as
 * loose parameters: it started as a ledger, gained an epoch, and gained the
 * producer-to-host map below, and each of those would otherwise have been one
 * more positional argument at every call. */
export type FeedState = {
	ledger: StageLedger;
	epoch: { current: number | undefined };
	/** Producer scope -> the host that producer reports as its own `a`, so a
	 * departure retires exactly that node and no other. */
	hostOfScope: Map<string, string>;
	/** Producer scope -> the sessions it is watching. A producer leaving takes
	 * its view of them with it, and the endpoint no longer synthesizes a close
	 * per session to say so — it reports the departure, and this is what turns
	 * that into the right ending for each session the viewer was shown. */
	sessionsOfScope: Map<string, Set<string>>;
	/** The replayed batch, held until the endpoint says it has ended.
	 * Empty when no snapshot is in flight, which is every ordinary
	 * moment of a live feed. */
	replayBatch: BaseTimelineEvent[];
};

/** Which kinds a replayed batch holds.
 *
 * Only the ones that carry topology, because only those are what the
 * batch is FOR: it exists so both ends of a wire are known before
 * either is drawn. Everything else a feed might replay is already
 * dropped on arrival — `applyEvent` refuses replayed messages, which
 * are the past and not this viewer's capture — so buffering them
 * would hold bytes to reach a `continue`.
 *
 * That is also what makes the count bound below a real bound. A
 * message record carries a base64 frame and a session record does
 * not, so holding only these keeps the batch small per record, and
 * counting records is then a fair proxy for holding memory. */
const REPLAY_BATCH_KINDS = new Set([
	"ocapn.session-opened",
	"ocapn.session-closed",
	"ocapn.session-meta",
]);

/** How many replayed records the converter will hold before drawing
 * what it has.
 *
 * The batch is bounded because everything on this feed is
 * attacker-controlled until it has been read: the viewer dials the
 * endpoint, and a feed that marked records `replay` forever would
 * otherwise grow this buffer for the connection's life. Past the
 * bound the batch is drawn rather than dropped — a viewer that
 * silently discarded topology would be worse than one that draws it
 * a moment early and has to learn an end, which is the same honest
 * degradation a feed sending no end-of-batch mark already gets.
 *
 * The number is a backstop, not a fit: a replay carries one row per
 * live session per producer, and this converter takes any producer of
 * the schema, so there is no ceiling upstream to derive it from. What
 * makes it safe is `REPLAY_BATCH_KINDS` above keeping payloads out. */
const MAX_REPLAY_BATCH = 8192;

/** Apply a replayed batch as ONE picture.
 *
 * A snapshot is not a sequence of moments. Every session in it is
 * already open, and a wire watched from both ends is in it twice —
 * so the far end's name is in hand before anything is drawn, and a
 * viewer that left the end loose and then attributed it would be
 * reporting a transition that never happened.
 *
 * What resolves it is one pass over the batch's opens, grouping each
 * wire's reporting selves. A wire with exactly two distinct selves is
 * fully known: each end's own designator is the other end's answer.
 * Anything else — one end reporting, or a shape this cannot read —
 * falls through to what a live feed does, which is honest about what
 * it did not know rather than merely acceptable.
 *
 * The batch then replays in ARRIVAL order through the ordinary path.
 * Every edge is still made by `openSession` and `#joinWire`, in the
 * same order, so the snapshot only hands over a fact the live path
 * had to wait for. What that buys is the same TOPOLOGY and the same
 * names, reached without reporting a learning that did not happen —
 * not identical documents. The live path leaves an unbacked end loose
 * and mints the peer only when a producer speaks for it, so the two
 * paths can reach one picture by different routes.
 * `feed-test/` holds the equality that does apply.
 *
 * Both of a wire's records still apply — the second is what marks its
 * reporting host eternal, which the first draw does not. */
function removeObservedSession(
	state: FeedState,
	session: string,
	t: number,
	out: TimelineEvent[],
): void {
	const scope = scopeOf(session);
	const watching = state.sessionsOfScope.get(scope);
	if (watching !== undefined) {
		watching.delete(session);
		if (watching.size === 0) state.sessionsOfScope.delete(scope);
	}
	for (
		const retired of state.ledger.closeSession(
			session,
			t,
			out,
			"unobserved",
		)
	) {
		const retiredScope = scopeOf(retired);
		const counterpart = state.sessionsOfScope.get(retiredScope);
		if (counterpart === undefined) continue;
		counterpart.delete(retired);
		if (counterpart.size === 0) state.sessionsOfScope.delete(retiredScope);
	}
}

function flushReplayBatch(
	state: FeedState,
	out: TimelineEvent[],
	snapshotT?: number,
): void {
	const batch = state.replayBatch;
	state.replayBatch = [];
	// Both passes ask the same question of a record — is this an open, and
	// which wire is it of — so they ask it once, the same way.
	const replayOpen = (ev: BaseTimelineEvent): {
		wire: string;
		self: string;
		profile: string | undefined;
	} | null => {
		if (stringFromWire(ev.kind) !== "ocapn.session-opened") return null;
		const session = nonEmptyStringFromWire(ev.session);
		const self = nonEmptyStringFromWire(ev.a);
		const partner = nonEmptyStringFromWire(ev.b);
		if (session == null || self == null || partner == null) return null;
		return {
			wire: wireKeyFor(session, nonEmptyStringFromWire(ev.session_id)),
			self,
			profile: nonEmptyStringFromWire(ev.a_profile),
		};
	};
	// Each wire's reporting selves, and what each of them said it runs. The
	// profile rides along because the batch holds it too: an end drawn from the
	// far producer's own report can be drawn as what that producer stated,
	// instead of being drawn unknown and then updated a moment later by the
	// very record that was already in hand.
	const selvesByWire = new Map<string, Map<string, string | undefined>>();
	for (const ev of batch) {
		const open = replayOpen(ev);
		if (open === null) continue;
		const selves = selvesByWire.get(open.wire);
		if (selves === undefined) {
			selvesByWire.set(open.wire, new Map([[open.self, open.profile]]));
		} else selves.set(open.self, open.profile);
	}

	// Only an explicit replay-end makes this batch authoritative. A reconnect
	// snapshot replaces the observations the viewer previously retained: an
	// observation absent now was lost while the byte channel was down. This is
	// deliberately "unobserved", never a claim that the CapTP session closed.
	// Bounded and live-tail fallback flushes omit snapshotT because their batch
	// may be incomplete and therefore cannot prove absence.
	if (snapshotT !== undefined) {
		const present = new Set<string>();
		for (const ev of batch) {
			const open = replayOpen(ev);
			const session = open === null ? undefined : nonEmptyStringFromWire(ev.session);
			if (session !== undefined) present.add(session);
		}
		const retained = [...state.sessionsOfScope.values()].flatMap((
			sessions,
		) => [
			...sessions,
		]);
		for (const session of retained) {
			if (!present.has(session)) {
				removeObservedSession(state, session, snapshotT, out);
			}
		}
	}

	if (batch.length === 0) return;
	for (const ev of batch) {
		const open = replayOpen(ev);
		const selves = open === null ? undefined : selvesByWire.get(open.wire);
		// Exactly two ends reporting is what "fully known" means: each one's own
		// name is the other's answer. One end, or a shape this cannot read,
		// falls through to what a live feed does — which is honest about what it
		// did not know.
		const partnerOwnName = selves?.size === 2 ? [...selves.keys()].find((self) => self !== open?.self) : undefined;
		const stated = partnerOwnName === undefined ? undefined : selves?.get(partnerOwnName);
		applyEvent(ev, state, out, {
			partnerOwnName,
			partnerOwnProfile: stated,
		});
	}
}

/**
 * Convert one wire event into zero or more OCapN-flavored
 * `TimelineEvent`s. Some inputs (`ocapn.session-opened`,
 * `ocapn.message-decoded`) yield multiple outputs because they
 * reference peers that the renderer needs as separate entities;
 * the ledger synthesizes `peer-joined` events on first sight and on
 * each return, and `peer-left` when a peer's last session closes.
 *
 * Returns `[]` for a kind this viewer does not read. Epoch changes
 * and the replay batch are this function's; one record's effect is
 * `applyEvent`.
 */
export function convertEvent(
	ev: BaseTimelineEvent,
	state: FeedState,
): TimelineEvent[] {
	const out: TimelineEvent[] = [];
	const simNs = numberFromWire(ev.sim_t_ns);
	if (simNs == null) return out;
	const kind = stringFromWire(ev.kind);
	if (kind == null) return out;
	const t_ms = simNs / 1_000_000;

	const epoch = numberFromWire(ev.epoch);
	if (epoch != null && epoch !== state.epoch.current) {
		// A new producer process. Retire the old one's topology first;
		// its sessions died with it and its wire ids may now recur.
		if (state.epoch.current !== undefined) {
			state.ledger.closeEpoch(t_ms, out);
		}
		// Both of these are keyed by producer scope, and the scopes of a
		// process that has gone will never be spoken for again — the same
		// reason `closeEpoch` drops the ledger's own per-producer state.
		state.hostOfScope.clear();
		state.sessionsOfScope.clear();
		state.epoch.current = epoch;
		// A batch held from the previous process describes sessions that
		// died with it, and its wire names may now belong to something
		// else. Drawing it into the new epoch would materialize exactly
		// the ghost topology `closeEpoch` just cleared — the same reason
		// it drops names claimed for sessions that will never open.
		state.replayBatch = [];
	}

	// The endpoint has sent everything it had; the picture is complete.
	if (kind === "trace.replay-end") {
		flushReplayBatch(state, out, t_ms);
		return out;
	}
	if (ev.replay === true) {
		// A replayed record the batch cannot use is dropped here rather than
		// held to be dropped later, which is what keeps the bound below a bound
		// on memory and not just on count.
		if (!REPLAY_BATCH_KINDS.has(kind)) return out;
		state.replayBatch.push(ev);
		// A feed that never marks the end cannot grow this without limit.
		if (state.replayBatch.length >= MAX_REPLAY_BATCH) {
			flushReplayBatch(state, out);
		}
		return out;
	}
	// A live record while a batch is open means the endpoint sent no
	// end-of-batch mark — an older one, or another producer of this
	// schema. Draw what is held rather than stranding it. This is a
	// backstop and not the boundary: a quiet feed may send no live
	// record for minutes, and the batch must not wait on one.
	flushReplayBatch(state, out);
	applyEvent(ev, state, out, {
		partnerOwnName: undefined,
		partnerOwnProfile: undefined,
	});
	return out;
}

/**
 * Stateful converter — the `StageLedger` tracks live incarnations
 * across calls so `peer-joined` fires once per lifetime, closes
 * release refcounts, and a producer restart (epoch change) retires
 * the previous process's topology.
 */
export function makeBaseEventConverter(): (
	ev: BaseTimelineEvent,
) => TimelineEvent[] {
	const state = newFeedState();
	return (ev) => convertEvent(ev, state);
}

/** A feed's memory, fresh. `makeBaseEventConverter` is the ordinary
 *  door; this and `convertEvent` are the same thing with the state
 *  named, so a caller that has to weigh what a feed RETAINS — every
 *  map here is per producer or per conversation, and each has to give
 *  its rows back — can hold it and look. */
export function newFeedState(): FeedState {
	return {
		ledger: new StageLedger(),
		epoch: { current: undefined },
		hostOfScope: new Map(),
		sessionsOfScope: new Map(),
		replayBatch: [],
	};
}
