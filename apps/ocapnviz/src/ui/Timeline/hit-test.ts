/**
 * Scrubber hit vocabulary, gutter picks, and rubber-band selection.
 *
 * Grab-band constants and the types a plot-area pick returns live
 * here so gutter, marquee, and `event-hit.ts` share one contract.
 * A point in a lane — entity + `DragPlan` — is `event-hit.ts`.
 *
 * Pure math: no React, no Pixi, no engine mutation. Walks the same
 * `iterateRows` layout the renderer paints so paint and hit-test
 * stay in lockstep across lane expand/collapse. Effective shapes
 * resolve through the same `peerEffective` / `sessionEffective` /
 * `messageEffective` resolvers the renderer reads.
 */

import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import {
	messageEffective,
	momentEffective,
	peerEffective,
	sessionEffective,
} from "../../engine/temporal/doc-resolver.ts";
import { momentOf } from "../../engine/event-helpers.ts";
import type { MomentLane } from "../../engine/trajectory.ts";
import { entityKey, type EntityRefKey } from "../../interactions/types.ts";
import { HEADER_EYEBALL_X, ROW_EYEBALL_X } from "./gutter-paint.ts";
import { type RowDescriptor } from "./row-layout.ts";
import { LANE_LABEL_WIDTH, type LaneKind, plotStartXOf, plotWidthOf, type TimelineView, tToCanvasPx } from "./state.ts";
import { spanScreenRect } from "./span-geometry.ts";

/** Identity side of a hit. `entity` is what gets selected — always
 * meaningful when `hitTestEvents` returns a non-null `ScrubberHit`,
 * even if the entity has no observation event yet (e.g. a freshly
 * authored peer rendered from `entity.timing` alone).
 *
 * Same shape as `StageSelection`'s non-null variant — pointerdown
 * forwards it verbatim to `onSelectEvent`. */
export type HitEntity = { kind: "peer" | "session" | "message"; id: string };

/** Temporal side of a hit — what retime gesture, if any, the hit
 * enables. Tagged on `kind` so the move-event dispatcher can switch
 * once and access the exact field set the variant needs, instead
 * of reconstructing intent from boolean-plus-optional combinations.
 *
 * "span" here refers to the rendered pill (peer or session bar with
 * two resizable edges), NOT the engine's `TimeSpan` storage type —
 * the words collide but the contexts are unambiguous.
 *
 *   - `span-edge`    — drag retimes one endpoint of a peer/session
 *                      span; sibling endpoint stays put. `edge`
 *                      picks which endpoint and resolves to either
 *                      the peer-joined / session-opened START event
 *                      or the peer-left / session-closed END event
 *                      (the dispatcher reads it).
 *   - `span-body`    — drag translates a peer/session span; both
 *                      endpoints slide by the same dt via the engine's
 *                      pair-aware `move-event`.
 *   - `moment`       — single-t event: a session-state-changed
 *                      diamond, a peer rename. No "edge"; drag
 *                      retimes the lone t. Distinct from `span-body`
 *                      so the move handler can clamp to the parent
 *                      entity's bounds.
 *   - `message-edge` — message has two times (sent + arrival).
 *                      Both always present; `edge` picks which one
 *                      the drag drives — left moves `start` with
 *                      `end` pinned, right moves `end` with `start`
 *                      pinned.
 *   - `message-body` — message body translate: both `start` and
 *                      `end` slide by the same dt.
 *
 * `start`/`end` match the engine's `EffectiveRange` vocabulary —
 * for messages that's `(sent, arrival)` semantically. */
export type DragPlan =
	| {
		kind: "span-edge";
		eventId: string;
		originalT: number;
		edge: "left" | "right";
	}
	| { kind: "span-body"; eventId: string; originalT: number }
	| {
		/** Entity-addressed sibling of `span-edge`: the entity has a
		 * painted span (from `entity.timing`) but no anchor observation
		 * event to name — a freshly authored peer or session. Same
		 * gesture, dispatched through the engine's `move-entity-span`
		 * instead of `move-event`, so authored and loaded entities
		 * resize identically. */
		kind: "entity-span-edge";
		ref: { kind: "peer" | "session"; id: string };
		originalT: number;
		edge: "left" | "right";
	}
	| {
		/** Entity-addressed sibling of `span-body`. */
		kind: "entity-span-body";
		ref: { kind: "peer" | "session"; id: string };
		originalT: number;
	}
	| { kind: "moment"; eventId: string; originalT: number }
	| {
		kind: "message-edge";
		eventId: string;
		start: number;
		end: number;
		edge: "left" | "right";
	}
	| { kind: "message-body"; eventId: string; start: number; end: number };

/** Result of a Scrubber pointer hit-test against the event lanes.
 *
 * Split into the identity answer (`entity` — what to select) and
 * the temporal answer (`drag` — what gesture, if any, the hit
 * enables). A freshly authored entity with no observation event yet
 * gets an entity-addressed plan (`entity-span-edge` /
 * `entity-span-body`), so it retimes exactly like a loaded one;
 * `drag: null` remains only for a message with no sent observation,
 * which authoring never produces. */
export type ScrubberHit = {
	entity: HitEntity;
	drag: DragPlan | null;
};

/** Pixel-edge tolerance for span-edge drag handles and
 * for picking moment glyphs, which are single moments rather than
 * spans. Symmetric: a click within 6 px of the edge "captures" the
 * handle, with anything inside that band the dominant target. */
export const EDGE_HANDLE_PX = 6;

/** Half-width of the grab band on the gutter's right seam, so the
 *  divider stays catchable at ±3 px. It sits above every other
 *  gutter control: the Scrubber's pointerdown checks it first, and
 *  `scrubberHoverAt` reads it in the same order. */
export const GUTTER_DRAG_GRAB_PX = 3;

/** Half-width of the grab band on each end of the Overview's
 *  visible-window rect. Wider than the gutter seam because the grips
 *  are a moving target on a 26 px strip. */
export const OVERVIEW_EDGE_GRAB_PX = 8;

/** Hit-test result for a click in the row-header gutter
 * (px < `gutterWidthOf(view)`). Distinct from `ScrubberHit` (event
 * hits in the plot area) so the two regimes don't collide in
 * the same hit-test contract — Scrubber's pointerdown checks
 * the gutter first, falls through to event hit-test second. */
export type GutterHit =
	| {
		kind: "chevron";
		category: Exclude<LaneKind, "ruler">;
	}
	| {
		/** Category-row eyeball — show-all / hide-all for the
		 * category. Distinct from `chevron` so the same header row
		 * can carry both gestures (chevron expands, eyeball
		 * toggles category visibility). */
		kind: "category-eyeball";
		category: Exclude<LaneKind, "ruler">;
	}
	| {
		kind: "eyeball";
		category: Exclude<LaneKind, "ruler">;
		entityId: string;
	}
	| {
		kind: "row-drag";
		category: Exclude<LaneKind, "ruler">;
		entityId: string;
		/** y of the row's TOP edge — drag math computes against this
		 * to determine insertion index as the pointer moves. */
		rowY: number;
		rowHeight: number;
	};

/** Selection names an entity in the singular while `doc.entities`
 * names its categories in the plural. The two vocabularies meet
 * here. */
const SELECTION_KIND: Record<MomentLane, "peer" | "session"> = {
	peers: "peer",
	sessions: "session",
};

/** Compute the set of entity refs whose painted spans intersect a
 * rectangle in HOST-pixel coordinates. Used by the rubber-band
 * gesture's pointerup commit.
 *
 * Resolver-as-renderer: spans come from `peerEffective` /
 * `sessionEffective` / `messageEffective` — the same helpers the
 * lane painter reads. Walking observations directly (the previous
 * shape) diverged from paint whenever `entity.timing` had been
 * edited but the matching observation hadn't been mirrored yet,
 * causing a marquee to miss entities the user could see and
 * click-select. Y-test follows the canonical `iterateRows` paint
 * order so geometry stays in lockstep across collapse/expand. */
export function entitiesInRect(
	rect: { x: number; y: number; width: number; height: number },
	doc: TimelineDocument,
	events: readonly TimelineEvent[],
	view: TimelineView,
	width: number,
	rows: readonly RowDescriptor[],
): Set<EntityRefKey> {
	// Marquee is the third consumer of span pixel-geometry alongside
	// lane paint and `hitTestEvents`'s body pass. All three route
	// through `spanScreenRect`, so a sub-`SPAN_MIN_PILL_PX` entity
	// promoted to a stamp by paint is also pickable by the marquee at
	// the same x-range — and an open-ended span clamps to the plot
	// right just like its painted pill.
	const out = new Set<EntityRefKey>();
	const plotLeft = plotStartXOf(view);
	const plotWidth = plotWidthOf(width, view);
	const tToPxRaw = (t: number) => tToCanvasPx(t, width, view);
	const xLo = rect.x;
	const xHi = rect.x + rect.width;
	const yLo = rect.y;
	const yHi = rect.y + rect.height;

	// Span [startT, endT]'s painted rect intersects [xLo, xHi]?
	// Routes through `spanScreenRect` so clamp + stamp policy matches
	// paint and body hit-test by construction.
	const spanHitsX = (startT: number, endT: number): boolean => {
		const r = spanScreenRect({
			startT,
			endT,
			tToPx: tToPxRaw,
			plotX: plotLeft,
			plotWidth,
		});
		if (!r) return false;
		return !(r.right < xLo || r.left > xHi);
	};

	const allPeerIds = () => Object.keys(doc.entities?.peers ?? {});
	const allSessionIds = () => Object.keys(doc.entities?.sessions ?? {});
	const allMessageIds = () => Object.keys(doc.entities?.messages ?? {});

	const addPeer = (id: string) => {
		const eff = peerEffective(doc, id);
		if (spanHitsX(eff.start, eff.end)) {
			out.add(entityKey({ kind: "peer", id }));
		}
	};
	const addSession = (id: string) => {
		const eff = sessionEffective(doc, id);
		if (spanHitsX(eff.start, eff.end)) {
			out.add(entityKey({ kind: "session", id }));
		}
	};
	const addMessage = (id: string) => {
		const eff = messageEffective(doc, id);
		if (!Number.isFinite(eff.end)) return;
		if (spanHitsX(eff.start, eff.end)) {
			out.add(entityKey({ kind: "message", id }));
		}
	};

	// A moment glyph rides on top of its entity's pill and addresses
	// that entity, not a separate selectable one — a marquee that
	// crosses a session's state change selects the session, and one
	// that crosses a peer's rename selects the peer. The entity's own
	// span hit covers the common case; this adds entities whose span
	// misses the rect but who have a glyph inside it (rare, but
	// possible at extreme zoom-out). The x-test uses the PAINTED t,
	// the same one the click hit-test and the lane painter use, so a
	// glyph the user can see is a glyph the marquee catches.
	const addByGlyph = (lane: MomentLane, entityId: string | null) => {
		for (const ev of events) {
			const moment = momentOf(ev);
			if (moment?.lane !== lane) continue;
			const ownerId = moment.owner;
			if (entityId !== null && ownerId !== entityId) continue;
			const cx = tToPxRaw(momentEffective(doc, lane, ownerId, ev.t));
			if (cx + EDGE_HANDLE_PX < xLo || cx - EDGE_HANDLE_PX > xHi) {
				continue;
			}
			out.add(entityKey({ kind: SELECTION_KIND[lane], id: ownerId }));
		}
	};

	for (const row of rows) {
		const rowYLo = row.y;
		const rowYHi = row.y + row.height;
		if (rowYHi < yLo || rowYLo > yHi) continue;
		if (row.kind === "category-header") continue;

		if (row.kind === "category-collapsed") {
			if (row.category === "peers") {
				for (const id of allPeerIds()) addPeer(id);
				addByGlyph("peers", null);
			} else if (row.category === "sessions") {
				for (const id of allSessionIds()) addSession(id);
				addByGlyph("sessions", null);
			} else {
				for (const id of allMessageIds()) addMessage(id);
			}
			continue;
		}

		// entity-row — narrowed to one entity in one category.
		if (row.category === "peers") {
			addPeer(row.entityId);
			addByGlyph("peers", row.entityId);
		} else if (row.category === "sessions") {
			addSession(row.entityId);
			addByGlyph("sessions", row.entityId);
		} else addMessage(row.entityId);
	}
	return out;
}

/** Gutter hit-test. Returns null when the click is outside the
 * gutter OR in the gutter but not on a chevron / eyeball / row-
 * drag handle (e.g. blank gutter strip between rows). */
export function hitTestGutter(
	px: number,
	py: number,
	rows: readonly RowDescriptor[],
	gutterWidth: number = LANE_LABEL_WIDTH,
): GutterHit | null {
	if (px >= gutterWidth) return null;
	for (const row of rows) {
		if (py < row.y || py >= row.y + row.height) continue;
		if (
			row.kind === "category-collapsed" || row.kind === "category-header"
		) {
			// Category eyeball wins inside its ±8 px zone — visibility
			// is a distinct gesture from expand, and the per-entity
			// rows below align their eyeballs to the same x so the
			// column reads as one. Outside that zone the rest of the
			// header row toggles expansion (chevron + label).
			if (px >= HEADER_EYEBALL_X - 8 && px < HEADER_EYEBALL_X + 8) {
				return { kind: "category-eyeball", category: row.category };
			}
			return { kind: "chevron", category: row.category };
		}
		if (row.kind === "entity-row") {
			// Eyeball hit zone: ±8 px around ROW_EYEBALL_X.
			if (px >= ROW_EYEBALL_X - 8 && px < ROW_EYEBALL_X + 8) {
				return {
					kind: "eyeball",
					category: row.category,
					entityId: row.entityId,
				};
			}
			// Anywhere right of the eyeball is the row-drag handle
			// (the entity label area + slack). Reorder + tap-to-select
			// work whether the entity is hidden on stage or not — the
			// row stays at full height and stays interactive.
			return {
				kind: "row-drag",
				category: row.category,
				entityId: row.entityId,
				rowY: row.y,
				rowHeight: row.height,
			};
		}
	}
	return null;
}
