/**
 * What the Inspector can say about a selection of more than one thing.
 *
 * The panel paints; this module answers, and every number here is a
 * claim that lands on screen. So each one is asked of the authority
 * that already owns it — the world for what is on stage, the
 * engine's effective range for when an entity runs, `sessionInfo`
 * for which peers a session is between, the observation stream for
 * what states a beginning — rather than re-derived by hand.
 *
 * Two rules hold the claims honest. A count says which set it
 * counted, and the words around it agree with that set: "4 of 17"
 * names both. And a plural is computed from the number beside it, so
 * a summary of one thing never reads as a summary of several.
 */

import type { Engine } from "../../engine/engine.ts";
import type { TimelineEvent } from "../../engine/timeline.ts";
import { observationsOf } from "../../engine/temporal/recording-access.ts";
import { parseEndpointStageId } from "../../schema/session-end.ts";
import type { EntityKind, EntityRefKey } from "../../interactions/types.ts";
import { parseEntityKey } from "../../interactions/types.ts";
import { sessionInfo } from "./entity-info.ts";

// ───────────────────────── words ───────────────────────────────────────

/** How each kind reads in a sentence, at one and at several.
 *
 *  A session end is spelled the way the panels talk about it — one end
 *  of a session — rather than by the stage id that names it. */
const KIND_NOUNS: Record<EntityKind, readonly [one: string, many: string]> = {
	peer: ["peer", "peers"],
	session: ["session", "sessions"],
	endpoint: ["session end", "session ends"],
	message: ["message", "messages"],
};

/** The order the panel names kinds in: the parties first, then what
 *  runs between them, then an end nothing has attributed to a party,
 *  then what crosses the wire. */
const KIND_ORDER: readonly EntityKind[] = [
	"peer",
	"session",
	"endpoint",
	"message",
];

/** Kinds the document can delete on their own. An end is one of the
 *  two a session HAS, so deleting it would leave a session with one;
 *  the session's own delete is what takes it. */
export const DELETABLE_KINDS: ReadonlySet<EntityKind> = new Set<EntityKind>([
	"peer",
	"session",
	"message",
]);

/** The noun `n` of this kind takes. */
export function kindNoun(kind: EntityKind, n: number): string {
	const [one, many] = KIND_NOUNS[kind];
	return n === 1 ? one : many;
}

/** "3 peers", "1 session end" — a count with the noun that count takes. */
export function countPhrase(kind: EntityKind, n: number): string {
	return `${n} ${kindNoun(kind, n)}`;
}

/** The members of a selection, grouped by kind, in the order above.
 *  Kinds nothing is selected of are absent rather than zero, so a
 *  caller reading this list never has to skip empties. */
export type KindTally = {
	readonly kind: EntityKind;
	readonly keys: readonly EntityRefKey[];
};

export function tallyByKind(
	selection: ReadonlySet<EntityRefKey>,
): readonly KindTally[] {
	const byKind = new Map<EntityKind, EntityRefKey[]>();
	for (const key of selection) {
		const { kind } = parseEntityKey(key);
		const seen = byKind.get(kind);
		if (seen) seen.push(key);
		else byKind.set(kind, [key]);
	}
	const out: KindTally[] = [];
	for (const kind of KIND_ORDER) {
		const keys = byKind.get(kind);
		if (keys) out.push({ kind, keys });
	}
	return out;
}

/** What the selection is, in words: "2 peers and 3 sessions".
 *
 *  It names every kind it holds, because the one thing a reader
 *  cannot recover from a bare total is what the total is made of, and
 *  a heading that says "5 entities" while the reader is holding two
 *  peers and three messages has told them nothing they did not
 *  already know. */
export function selectionPhrase(tallies: readonly KindTally[]): string {
	const parts = tallies.map((t) => countPhrase(t.kind, t.keys.length));
	if (parts.length === 0) return "nothing";
	if (parts.length === 1) return parts[0]!;
	return `${parts.slice(0, -1).join(", ")} and ${parts[parts.length - 1]}`;
}

/** What a group delete would take, in words, or null when it would
 *  take nothing. Ends are left out because the delete leaves them
 *  alone — the phrase and the act count the same things, and a
 *  selection of ends alone is offered no delete at all rather than
 *  one that claims to take them. */
export function deletionPhrase(
	selection: ReadonlySet<EntityRefKey>,
): string | null {
	const takes = tallyByKind(selection).filter((t) => DELETABLE_KINDS.has(t.kind));
	return takes.length === 0 ? null : selectionPhrase(takes);
}

// ───────────────────────── facts ───────────────────────────────────────

/** The lane an entity's span lives in, and the id it lives under.
 *
 *  A session end has no span of its own: it exists exactly while the
 *  session it is one end of does, so it answers with that session.
 *  Null when the selection names something the document does not
 *  hold, which keeps a stale key out of the span rather than letting
 *  it report the fallback range as if it were a fact. */
type Timed = {
	readonly category: "peers" | "sessions" | "messages";
	readonly id: string;
};

function timedOf(engine: Engine, key: EntityRefKey): Timed | null {
	const { kind, id } = parseEntityKey(key);
	const entities = engine.doc.entities;
	if (kind === "peer") {
		return entities?.peers?.[id] ? { category: "peers", id } : null;
	}
	if (kind === "session") {
		return entities?.sessions?.[id] ? { category: "sessions", id } : null;
	}
	if (kind === "message") {
		return entities?.messages?.[id] ? { category: "messages", id } : null;
	}
	const at = parseEndpointStageId(id);
	if (!at || !entities?.sessions?.[at.sessionId]) return null;
	return { category: "sessions", id: at.sessionId };
}

/** What the world is holding at the playhead, by id.
 *
 *  On stage is exactly "the world has it", which is what an "active"
 *  lifecycle means in `peerInfo` and `sessionInfo` too. Asked in bulk
 *  rather than one at a time: the panel answers for every member of
 *  the selection on every render, and the world's own lookups are
 *  linear, so a wide selection would ask a linear question once per
 *  member on every frame of a scrub. */
type OnStage = {
	readonly peers: ReadonlySet<string>;
	readonly sessions: ReadonlySet<string>;
	readonly messages: ReadonlySet<string>;
};

function onStageNow(engine: Engine): OnStage {
	const peers = new Set<string>();
	const sessions = new Set<string>();
	const messages = new Set<string>();
	for (const e of engine.queries.peers) peers.add(e.peer.id);
	for (const e of engine.queries.sessions) sessions.add(e.session.id);
	for (const e of engine.queries.messagesInFlight) {
		messages.add(e.messageInFlight.id);
	}
	return { peers, sessions, messages };
}

/** An end is drawn exactly while the session it is an end of is, so
 *  it answers with that session. */
function isOnStage(live: OnStage, key: EntityRefKey): boolean {
	const { kind, id } = parseEntityKey(key);
	if (kind === "peer") return live.peers.has(id);
	if (kind === "message") return live.messages.has(id);
	const sessionId = kind === "session" ? id : parseEndpointStageId(id)?.sessionId;
	return sessionId !== undefined && live.sessions.has(sessionId);
}

export type SelectionFacts = {
	readonly total: number;
	readonly tallies: readonly KindTally[];
	/** Earliest start and latest end across every selected entity the
	 *  document holds a span for. Null when it holds none. */
	readonly span: { readonly start: number; readonly end: number } | null;
	/** How many of the selected are on stage at the playhead. */
	readonly onStage: number;
	/** Of the selected sessions, how many run between two peers that
	 *  are themselves selected — the difference between a selection
	 *  that closes on itself and one that trails loose ends. Null when
	 *  the selection holds no session or no peer, where the question
	 *  does not arise. */
	readonly between:
		| { readonly closed: number; readonly sessions: number }
		| null;
};

export function selectionFacts(
	engine: Engine,
	selection: ReadonlySet<EntityRefKey>,
): SelectionFacts {
	const tallies = tallyByKind(selection);
	const live = onStageNow(engine);

	let start = Infinity;
	let end = -Infinity;
	let onStage = 0;
	for (const key of selection) {
		if (isOnStage(live, key)) onStage += 1;
		const timed = timedOf(engine, key);
		if (!timed) continue;
		start = Math.min(
			start,
			engine.effectiveStart(timed.category, timed.id),
		);
		end = Math.max(end, engine.effectiveEnd(timed.category, timed.id));
	}

	const sessions = tallies.find((t) => t.kind === "session");
	const peers = tallies.find((t) => t.kind === "peer");
	let between: SelectionFacts["between"] = null;
	if (sessions && peers) {
		let closed = 0;
		for (const key of sessions.keys) {
			const { id } = parseEntityKey(key);
			const s = sessionInfo(engine, id);
			if (!s) continue;
			if (
				selection.has(`peer:${s.a}` as EntityRefKey) &&
				selection.has(`peer:${s.b}` as EntityRefKey)
			) closed += 1;
		}
		between = { closed, sessions: sessions.keys.length };
	}

	return {
		total: selection.size,
		tallies,
		span: Number.isFinite(start) ? { start, end } : null,
		onStage,
		between,
	};
}

// ───────────────────────── the bulk shift ──────────────────────────────

/** What one bulk time shift moves, and what it leaves alone.
 *
 *  Only each selected entity's own genesis observation is listed. The
 *  engine's `translate` already carries everything scoped to that
 *  entity — a peer's departure and its updates, a session's close and
 *  every moment on its trajectory, a message's arrival — so naming
 *  those here would be a second answer to a question the authoring
 *  layer has already answered, and the two would drift.
 *
 *  The counts are what the panel warns with, so each names exactly
 *  the set it counted rather than a reason that happens to fit most
 *  of it. */
export type ShiftPlan = {
	/** The genesis observations to translate, with the time each held
	 *  when the plan was made — a shift is relative to that, so the
	 *  plan is captured once per selection and not re-read mid-drag. */
	readonly events: readonly { readonly id: string; readonly t: number }[];
	/** Selected peers, sessions and messages that no observation says
	 *  the beginning of, so nothing in them can be moved. */
	readonly eternal: number;
	/** Selected session ends. An end has no time of its own. */
	readonly ends: number;
};

/** The observation that states when an entity begins, and whose
 *  entity that is. Everything else is either a moment inside an
 *  entity or its ending, and both of those ride the genesis. */
function genesisKeyOf(ev: TimelineEvent): EntityRefKey | null {
	if (ev.kind === "peer-joined") return `peer:${ev.peerId}`;
	if (ev.kind === "session-opened") return `session:${ev.sessionId}`;
	if (ev.kind === "message-sent") return `message:${ev.messageId}`;
	return null;
}

export function bulkShiftPlan(
	engine: Engine,
	selection: ReadonlySet<EntityRefKey>,
): ShiftPlan {
	const genesis = new Map<EntityRefKey, { id: string; t: number }>();
	// `TimelineEvent` is the authoring name for `Observation`; the
	// engine's own helpers read the stream the same way.
	for (const ev of observationsOf(engine.doc) as readonly TimelineEvent[]) {
		const key = genesisKeyOf(ev);
		if (key === null || !selection.has(key)) continue;
		genesis.set(key, { id: ev.id, t: ev.t });
	}
	let eternal = 0;
	let ends = 0;
	for (const key of selection) {
		if (parseEntityKey(key).kind === "endpoint") ends += 1;
		else if (!genesis.has(key)) eternal += 1;
	}
	return { events: [...genesis.values()], eternal, ends };
}

/** What the panel says about the entities a shift cannot move, in
 *  sentences that count what they name. Empty when it moves
 *  everything, which is the ordinary case and gets no note at all. */
export function shiftCaveats(
	plan: ShiftPlan,
	total: number,
): readonly string[] {
	const out: string[] = [];
	if (plan.eternal === 1) {
		out.push(
			`One of the ${total} selected has no start event, so the shift ` +
				`leaves it where it is.`,
		);
	} else if (plan.eternal > 1) {
		out.push(
			`${plan.eternal} of the ${total} selected have no start event, so ` +
				`the shift leaves them where they are.`,
		);
	}
	if (plan.ends === 1) {
		out.push(
			"The selected session end has no time of its own; it moves when " +
				"its session does.",
		);
	} else if (plan.ends > 1) {
		out.push(
			`The ${plan.ends} selected session ends have no time of their own; ` +
				"they move when their sessions do.",
		);
	}
	return out;
}
