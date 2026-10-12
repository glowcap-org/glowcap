/**
 * Lane bundle, the data layer between the doc/events and the
 * Scrubber's lane painter. One `buildLaneBundle` call resolves
 * the visible spans + glyphs + per-entity breakdown for the three
 * categorical lanes (peers / sessions / messages), and a
 * `WeakMap<doc.entities, ...>` cache keeps it free across paints
 * when nothing material changed.
 *
 * Spans come from the effective-range resolvers (`peerEffective`
 * / `sessionEffective` / `messageEffective`), i.e. the Behavior
 * layer's `entity.timing` after cascade-inheritance, NOT raw
 * observations. This lets a clear-bound (e.g.
 * `message.start.explicit=false`) fall through to its parent
 * context and paint at the inherited position instead of being
 * stranded at the original observation `t`.
 *
 * Glyphs come from `events` rather than from the keyframe tracks
 * those observations project into, because a glyph must name the
 * event it paints: that id is what the click hit-test drags and what
 * the sub-selection focus halo rings, and a keyframe carries no id.
 *
 * Two shapes, and the difference is what the moment says. A DIAMOND
 * is a property taking a value, a session's state, a peer's name or
 * flavor, one of its ends attaching to a peer. A TICK is the viewer
 * losing sight of something it had drawn. Same lanes, different
 * claims, so they do not share a glyph.
 */

import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import {
	messageEffective,
	momentEffective,
	peerEffective,
	peerLabelAt,
	peerProfileAt,
	sessionEffective,
} from "../../engine/temporal/doc-resolver.ts";
import { peerLabelText } from "../../render/stage-labels.ts";
import { sessionPairName } from "../session-name.ts";
import { elideIdentifier } from "../elide.ts";
import {
	CAPTP_VERSION_COLORS,
	colorForProfile,
	glyphOnFill,
	sessionStateColors,
	themedColors,
} from "../../render/palette.ts";
import { keyframeAt, type KeyframeTrack } from "../../engine/temporal/keyframes.ts";
import { momentOf } from "../../engine/event-helpers.ts";
import { PEER_TRAJECTORY, peerUpdateStates } from "../../engine/trajectory.ts";
import type { SessionState } from "../../schema/topology.ts";
import type { Theme } from "../tokens.ts";

/** 0xRRGGBB → 6-digit `#rrggbb` CSS string. */
export function hex(n: number): string {
	return `#${n.toString(16).padStart(6, "0")}`;
}

/**
 * One contiguous time span on a lane (peer alive, session open,
 * message in flight). Open-ended spans use
 * `Number.POSITIVE_INFINITY` for `endT` and paint with a gradient
 * fade at the visible window's right edge.
 */
export type LaneSpan = {
	id: string;
	startT: number;
	endT: number;
	open: boolean;
	color: string;
	label: string | undefined;
	/** Per-state color bands within the pill. Painted as plain rects
	 *  inset by `RADIUS` from each end so the rounded caps keep
	 *  `color` (the categorical encoding, captpVersion for sessions).
	 *  Only populated when ≥1 in-range state keyframe exists. Absent
	 *  for peers, messages, and single-state sessions. */
	segments?: readonly LaneSegment[];
};

export type LaneSegment = {
	t0: number;
	t1: number;
	color: string;
};

/**
 * Discrete-moment overlay drawn ON TOP of pills. Spans answer
 * "from when to when?". Glyphs answer "what happened on top?".
 *
 *   diamond, 6 px rotated square, "transition / state change"
 *             (Wireshark + DAW marker vocabulary).
 *   tick:    1 px vertical line, "this exact moment" (lighter
 *             weight than a diamond).
 *
 * Cluster-collapse: glyphs in the same 4-px bucket collapse to one
 * mid-bucket glyph (the pill cluster already badges its count).
 */
export type LaneGlyph = {
	t: number;
	shape: "diamond" | "tick";
	color: string;
	label: string | undefined;
	/** Event id this glyph paints. Set on observation-sourced glyphs
	 *  (`session-state-changed`, `peer-updated`). Used by the focus
	 *  halo to single out the keyframe a sub-selection state machine
	 *  is parked on. */
	eventId?: string;
};

/** Per-category lane contents. `spans` is the flat list used by
 * the collapsed (stacked-summary) render, today's look. `glyphs`
 * are the single-moment diamonds: a session's state changes, a
 * peer's renames. `byEntity` is the Flash-grade per-entity
 * breakdown, same data, indexed by
 * entity id, used by the expanded per-row render. Both are built
 * in one pass. The bundle cache holds them together. */
export type LaneCategoryBundle = {
	spans: LaneSpan[];
	glyphs: LaneGlyph[];
	byEntity: Map<string, { spans: LaneSpan[]; glyphs: LaneGlyph[] }>;
};

export type LaneBundle = {
	peers: LaneCategoryBundle;
	sessions: LaneCategoryBundle;
	messages: LaneCategoryBundle;
};

/** Hex-string colors baked into spans + glyphs at bundle build
 * time (cached, so the colors are pre-resolved per theme). */
export type LaneBundleColors = {
	message: string;
	sessionMuted: string;
	/** Rename glyphs whose peer is undeclared, so there is no pill
	 *  fill to choose a readable tone against. A declared peer's
	 *  glyph takes `glyphOnFill(profile color)` instead. */
	peerMuted: string;
	/** Per-state pill segment colors, pre-resolved per theme. */
	sessionStates: Record<SessionState, string>;
};

export function laneBundleColorsFromTheme(theme: Theme): LaneBundleColors {
	const c = themedColors(theme);
	const states = sessionStateColors(c);
	return {
		message: hex(c.messageInFlight),
		sessionMuted: hex(c.warning),
		peerMuted: hex(c.text),
		sessionStates: {
			open: hex(states.open),
			negotiating: hex(states.negotiating),
			draining: hex(states.draining),
			closed: hex(states.closed),
		},
	};
}

// Cache keyed by `doc.entities` identity, entity.timing mutations
// always swap the entities object reference (authoring intents
// return a new doc), so reference equality is sufficient to detect
// staleness. Glyph contents come from `events`, folded into the
// secondary cache key alongside theme / duration.
const laneBundleCache = new WeakMap<
	NonNullable<TimelineDocument["entities"]>,
	Map<string, LaneBundle>
>();

/** Sentinel for docs with no `entities` field, keeps the WeakMap
 *  key non-null when an early-load doc has neither identity nor
 *  observations yet. */
const EMPTY_ENTITIES: NonNullable<TimelineDocument["entities"]> = {};

/** How many bundles one entities identity keeps.
 *
 *  The painter only ever asks for the current key, so one slot would serve
 *  it. A handful, because two keys are legitimately alive at once while a
 *  reader toggles the theme or the duration grows, and paying a rebuild for
 *  each toggle would be its own stutter.
 *
 *  It is a ceiling rather than a fit because the key carries the observation
 *  COUNT: a live feed mints a new key per record it receives, so an
 *  unbounded map here would grow for the length of the capture and hold
 *  every lane stack it ever painted. Oldest out first, which is the one the
 *  playhead has moved furthest past. */
const MAX_CACHED_BUNDLES = 4;

/** Identity key for the `events` array dimension of the lane-bundle
 *  cache. Reference + length covers in-place appends from the live
 *  feed (same array, length grew) AND swap-for-new-array authoring
 *  flows (different reference). Cheap. */
const eventsIdentityMap = new WeakMap<readonly TimelineEvent[], string>();
let eventsIdentitySeq = 0;
function eventsIdentityKey(events: readonly TimelineEvent[]): string {
	let id = eventsIdentityMap.get(events);
	if (id === undefined) {
		id = `e${++eventsIdentitySeq}`;
		eventsIdentityMap.set(events, id);
	}
	return `${id}#${events.length}`;
}

/** Single source of truth for "which entity ids get a row" in each
 *  category. Consumed by `buildLaneBundle` (to drive both span
 *  iteration and the glyph orphan-suppression filter) AND by
 *  Scrubber (to size the row stack and route gutter hit-tests).
 *  Routing both readers through one function is what guarantees
 *  the hit-test row stack matches the painted row stack, there
 *  is no second mirror to drift from. Orphan glyphs (sessionIds
 *  not in `entities.sessions`) still ride the flat collapsed view
 *  via `bundle.sessions.glyphs`. They just don't earn a per-entity
 *  row, because a row holding nothing but stray diamonds reads as
 *  a ghost session to the user. */
export function laneRowEntityIds(
	entities: TimelineDocument["entities"],
	_events: readonly TimelineEvent[],
): { peers: string[]; sessions: string[]; messages: string[] } {
	const peers = Object.keys(entities?.peers ?? {});
	const sessions = Object.keys(entities?.sessions ?? {});
	const messages = Object.keys(entities?.messages ?? {});
	return { peers, sessions, messages };
}

/** Build per-state segments for a session pill. Returns `undefined`
 *  when the session stays in a single state across its effective
 *  range. The caller paints the unsegmented pill in the categorical
 *  (captp) color in that case. Keyframes outside `[startT, endT)`
 *  do not split the bar. The active state at `startT` (via
 *  `keyframeAt`) seeds the first segment. */
function buildTrackSegments(
	track: KeyframeTrack<string> | undefined,
	genesis: string | undefined,
	startT: number,
	endT: number,
	colorOf: (value: string) => string,
): readonly LaneSegment[] | undefined {
	if (!track || endT <= startT) return undefined;
	const inRange = track.filter((kf) => kf.t > startT && kf.t < endT);
	if (inRange.length === 0) return undefined;
	const first = keyframeAt(track, startT) ?? genesis;
	if (first === undefined) return undefined;
	const segs: LaneSegment[] = [];
	let cur = { t0: startT, value: first };
	for (const kf of inRange) {
		segs.push({ t0: cur.t0, t1: kf.t, color: colorOf(cur.value) });
		cur = { t0: kf.t, value: kf.value };
	}
	segs.push({ t0: cur.t0, t1: endT, color: colorOf(cur.value) });
	return segs;
}

/** What a row in the gutter is called: the name its own pill carries.
 *
 *  The gutter asks the question the pill already answered, what is this
 *  entity called, so it reads that answer rather than deriving a second
 *  one. Every row this bundle builds has a span, because a row and a span
 *  come from the same entity. The fallback is for a caller holding an id
 *  no row was built for, and it says what the app says about any bare
 *  identifier. */
export function laneRowLabel(
	entity: { readonly spans: readonly LaneSpan[] } | undefined,
	entityId: string,
): string {
	return entity?.spans[0]?.label ?? elideIdentifier(entityId);
}

/** Get-or-create per-entity bucket. Mutates the `byEntity` map. */
function bucket(
	byEntity: Map<string, { spans: LaneSpan[]; glyphs: LaneGlyph[] }>,
	id: string,
): { spans: LaneSpan[]; glyphs: LaneGlyph[] } {
	let b = byEntity.get(id);
	if (!b) {
		b = { spans: [], glyphs: [] };
		byEntity.set(id, b);
	}
	return b;
}

export function buildLaneBundle(
	doc: TimelineDocument,
	events: readonly TimelineEvent[],
	duration: number,
	colors: LaneBundleColors,
	themeKey: string,
): LaneBundle {
	const entities = doc.entities;
	// Cache key uses `doc.entities` reference identity; any timing
	// edit produces a new entities object via the authoring intents.
	// Glyphs fold the events-array identity into the secondary key so
	// observation-side appends (live feed) invalidate.
	const cacheRoot = entities ?? EMPTY_ENTITIES;
	let perTheme = laneBundleCache.get(cacheRoot);
	if (!perTheme) {
		perTheme = new Map();
		laneBundleCache.set(cacheRoot, perTheme);
	}
	const eventsId = eventsIdentityKey(events);
	const cacheKey = `${themeKey}|${duration}|${eventsId}`;
	const cached = perTheme.get(cacheKey);
	if (cached) return cached;

	const peerSpans: LaneSpan[] = [];
	const sessionSpans: LaneSpan[] = [];
	const messageSpans: LaneSpan[] = [];
	const peerGlyphs: LaneGlyph[] = [];
	const sessionGlyphs: LaneGlyph[] = [];
	const peersByEntity = new Map<
		string,
		{ spans: LaneSpan[]; glyphs: LaneGlyph[] }
	>();
	const sessionsByEntity = new Map<
		string,
		{ spans: LaneSpan[]; glyphs: LaneGlyph[] }
	>();
	const messagesByEntity = new Map<
		string,
		{ spans: LaneSpan[]; glyphs: LaneGlyph[] }
	>();

	// Single decision point for "which ids get a row", shared with
	// Scrubber's gutter hit-test and height math via the same
	// `laneRowEntityIds` call, so paint and hit-test cannot disagree.
	const rowIds = laneRowEntityIds(entities, events);

	// Peers: span = peerEffective(doc, id). Effective.end is +∞ when
	// the peer has no explicit end and inherits world's unbounded
	// upper edge; we clip to `duration` for paint so the open-edge
	// pill stretches to the visible end of the doc.
	for (const peerId of rowIds.peers) {
		const def = entities?.peers?.[peerId];
		if (!def) continue;
		const eff = peerEffective(doc, peerId);
		const open = !Number.isFinite(eff.end);
		const endT = open ? duration : eff.end;
		// A peer that changes flavor bands its pill at the moment it
		// changed, the way a session bands by state. The row shows what
		// it was known as when, not only what it ended up as.
		const segments = buildTrackSegments(
			PEER_TRAJECTORY.profile.track(def),
			def.profile,
			eff.start,
			endT,
			(profile) => hex(colorForProfile(profile)),
		);
		const span: LaneSpan = {
			id: peerId,
			startT: eff.start,
			endT,
			open,
			// One row covers the peer's whole life, so it carries what the
			// peer was last known as. The name and flavor a reader is
			// looking for when either changed partway through.
			color: hex(colorForProfile(peerProfileAt(doc, peerId, endT))),
			// The same caption the stage writes under this peer, by the
			// same rule: a peer with no stated name wears its id, and in a
			// recording that id is the name it answers to on the wire,
			// long and opaque, so it is shortened rather than allowed to
			// fill the pill.
			label: peerLabelText(peerLabelAt(doc, peerId, endT)),
			...(segments ? { segments } : {}),
		};
		peerSpans.push(span);
		bucket(peersByEntity, peerId).spans.push(span);
	}

	// Sessions: span = sessionEffective(doc, id). Same open-edge
	// treatment when end inherits past the doc's tail.
	for (const sessionId of rowIds.sessions) {
		const def = entities?.sessions?.[sessionId];
		if (!def) continue;
		const eff = sessionEffective(doc, sessionId);
		const open = !Number.isFinite(eff.end);
		const endT = open ? duration : eff.end;
		const segments = buildTrackSegments(
			def.keyframes?.state,
			def.initialState ?? "negotiating",
			eff.start,
			endT,
			(state) => colors.sessionStates[state as SessionState],
		);
		const span: LaneSpan = {
			id: sessionId,
			startT: eff.start,
			endT,
			open,
			color: hex(CAPTP_VERSION_COLORS[def.captpVersion]),
			// A session is called what the pair it joins is called, and one
			// module answers that for the Inspector's heading, its pickers,
			// and this pill alike. Read at `endT`, because a row covers the
			// session's whole life and a reader is looking for what it ended
			// up joining.
			label: sessionPairName(doc, sessionId, endT),
			...(segments ? { segments } : {}),
		};
		sessionSpans.push(span);
		bucket(sessionsByEntity, sessionId).spans.push(span);
	}

	// Messages: span = messageEffective(doc, id). Messages always
	// have explicit duration (per `projectFromObservations`), so
	// effective.end is finite as long as the parent session resolves.
	for (const messageId of rowIds.messages) {
		const def = entities?.messages?.[messageId];
		if (!def) continue;
		const eff = messageEffective(doc, messageId);
		const open = !Number.isFinite(eff.end);
		const span: LaneSpan = {
			id: messageId,
			startT: eff.start,
			endT: open ? duration : eff.end,
			open,
			color: colors.message,
			label: def.label,
		};
		messageSpans.push(span);
		bucket(messagesByEntity, messageId).spans.push(span);
	}

	// Glyphs (peer-updated): the moments a peer changed the name it
	// answers to. Same treatment as the session diamonds below,
	// observation-sourced, clamped into the parent's painted span, and
	// pickable, so a rename can be seen and retimed like any other
	// moment. A `peer-updated` carrying no label renames nothing and
	// gets no glyph.
	const rowPeerIds = new Set(rowIds.peers);
	for (const ev of events) {
		// `momentOf` decides what a diamond is and whose it is; the
		// hit-test, the marquee, and the drag's clamp ask the same
		// question of the same function, so a glyph the painter draws is
		// one they can pick. What the moment SAYS comes from the
		// trajectory table, so a second temporal peer property paints
		// here with no change.
		if (momentOf(ev)?.lane !== "peers" || ev.kind !== "peer-updated") {
			continue;
		}
		const stated = peerUpdateStates(ev);
		// The diamond sits on the peer's own pill, whose fill is the
		// profile color, so its tone is chosen against that fill. A
		// glyph whose peer is undeclared has no pill under it and takes
		// the chrome tone instead.
		const profile = entities?.peers?.[ev.peerId] === undefined ? undefined : peerProfileAt(doc, ev.peerId, ev.t);
		const glyph: LaneGlyph = {
			t: momentEffective(doc, "peers", ev.peerId, ev.t),
			shape: "diamond",
			color: profile === undefined ? colors.peerMuted : hex(glyphOnFill(colorForProfile(profile))),
			label: stated
				.map((s) => `${PEER_TRAJECTORY[s.property].noun} → ${s.value}`)
				.join(", "),
			eventId: ev.id,
		};
		peerGlyphs.push(glyph);
		if (rowPeerIds.has(ev.peerId)) {
			bucket(peersByEntity, ev.peerId).glyphs.push(glyph);
		}
	}

	// Glyphs (peer-unobserved / session-unobserved): the moment the viewer
	// lost sight of a row. A tick, like the identifications, because it is
	// the same class of fact, something changed about what this viewer can
	// see, and nothing changed on the network.
	for (const ev of events) {
		if (ev.kind !== "peer-unobserved") continue;
		const glyph: LaneGlyph = {
			t: momentEffective(doc, "peers", ev.peerId, ev.t),
			shape: "tick",
			color: colors.peerMuted,
			label: "the feed stopped showing this",
			eventId: ev.id,
		};
		peerGlyphs.push(glyph);
		if (rowPeerIds.has(ev.peerId)) {
			bucket(peersByEntity, ev.peerId).glyphs.push(glyph);
		}
	}

	// Session-lane glyphs: one pass over one table, because every entry
	// below is the same thing, a single point on a session's row, and
	// differs only in what it says and how much weight it carries. A
	// fourth session glyph is a case here, not a fourth loop.
	//
	// Shape carries the one distinction that survives: a diamond is a
	// change to the session itself, and a tick is a change to what the
	// feed can see. Attribution is a diamond. Nothing on the wire is
	// hidden behind the viewer's knowledge of it: an end attaching to a
	// peer is a fact about the session, drawn at the same weight as its
	// state changing and dragged with the same grip.
	//
	// Paint t is the session-clamped t, the same saturating-clamp
	// doctrine `peerEffective`/`sessionEffective`/`messageEffective`
	// apply to spans, lifted to single moments via `momentEffective`.
	// The stored observation t stays the source of truth for authoring;
	// this keeps a glyph inside its pill until the user moves it (drag
	// clamps via `applyEventDragMove`) or resizes the session. Orphan
	// glyphs, a sessionId `rowIds.sessions` never declared, ride the
	// flat collapsed view but skip the per-entity bucket, because the
	// row source of truth gave them no row.
	// The switch is the whole filter. `momentOf` is not consulted: it
	// answers "does this change the entity", and `session-unobserved`
	// is painted here without being one, it marks what the feed can
	// see rather than what the session did. Guarding on it would drop
	// that tick silently.
	const rowSessionIds = new Set(rowIds.sessions);
	for (const ev of events) {
		let shape: LaneGlyph["shape"];
		let label: string;
		switch (ev.kind) {
			case "session-state-changed":
				shape = "diamond";
				label = `${ev.sessionId} → ${ev.state}`;
				break;
			case "session-endpoint-attributed":
				shape = "diamond";
				// Not "end a" / "end b": nothing the viewer draws labels an
				// end, so a positional name would send a reader looking for
				// something that is not on screen. The glyph already sits on
				// this session's row, so "this end" is the one it is on.
				label = `this end is ${ev.peerId}`;
				break;
			case "session-unobserved":
				shape = "tick";
				label = "the feed stopped showing this";
				break;
			default:
				continue;
		}
		const glyph: LaneGlyph = {
			t: momentEffective(doc, "sessions", ev.sessionId, ev.t),
			shape,
			color: colors.sessionMuted,
			label,
			eventId: ev.id,
		};
		sessionGlyphs.push(glyph);
		if (rowSessionIds.has(ev.sessionId)) {
			bucket(sessionsByEntity, ev.sessionId).glyphs.push(glyph);
		}
	}

	const bundle: LaneBundle = {
		peers: {
			spans: peerSpans,
			glyphs: peerGlyphs,
			byEntity: peersByEntity,
		},
		sessions: {
			spans: sessionSpans,
			glyphs: sessionGlyphs,
			byEntity: sessionsByEntity,
		},
		messages: {
			spans: messageSpans,
			glyphs: [],
			byEntity: messagesByEntity,
		},
	};
	perTheme.set(cacheKey, bundle);
	while (perTheme.size > MAX_CACHED_BUNDLES) {
		const oldest = perTheme.keys().next();
		if (oldest.done === true) break;
		perTheme.delete(oldest.value);
	}
	return bundle;
}
