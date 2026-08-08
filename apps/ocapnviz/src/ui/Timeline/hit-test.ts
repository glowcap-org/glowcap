/**
 * Scrubber hit-testing — the geometry side of the timeline's
 * pointer pipeline. Returns the entity identity AND the temporal
 * gesture (`DragPlan`) a click enables, so the pointerdown handler
 * can dispatch select + drag in one pass.
 *
 * Pure math: no React, no Pixi, no engine mutation. Walks the same
 * `iterateRows` layout the renderer paints so paint and hit-test
 * stay in lockstep across lane expand/collapse and per-row hidden
 * states. Effective shapes resolve through the same
 * `peerEffective` / `sessionEffective` / `messageEffective`
 * resolvers the renderer reads — a click on the visible pill
 * always succeeds.
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
import { type RowDescriptor, RULER_HEIGHT } from "./row-layout.ts";
import {
  gutterWidthOf,
  LANE_LABEL_WIDTH,
  type LaneKind,
  PLOT_RIGHT_PAD_PX,
  plotStartXOf,
  plotWidthOf,
  type TimelineView,
  tToCanvasPx,
} from "./state.ts";
import { type SpanRect, spanScreenRect } from "./span-geometry.ts";

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
 * of reconstructing intent from `(rightEdge, leftEdge, originalArrivalT)`
 * boolean+optional combinations as the legacy shape did.
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

/** Pixel-edge tolerance for right-edge drag handles (Phase 3) and
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

/** The moment glyph nearest `px` within the edge-handle band, on the
 * given lane. `entityId` narrows to one entity's row; null means the
 * whole lane. The lane picks its own owner rule out of
 * `MOMENT_OWNER`, so no caller can pair a lane with another lane's
 * rule. The hit t is the painted t (`momentEffective`), so clicking
 * the VISIBLE diamond works even when the stored observation t
 * drifts outside its parent's span. */
function nearestMoment(
  events: readonly TimelineEvent[],
  doc: TimelineDocument,
  lane: MomentLane,
  entityId: string | null,
  px: number,
  pxAtClamped: (t: number) => number,
): { eventId: string; ownerId: string; t: number } | null {
  let best:
    | { eventId: string; ownerId: string; t: number; dPx: number }
    | null = null;
  for (const ev of events) {
    const moment = momentOf(ev);
    if (moment?.lane !== lane) continue;
    const ownerId = moment.owner;
    if (entityId !== null && ownerId !== entityId) continue;
    const dPx = Math.abs(
      pxAtClamped(momentEffective(doc, lane, ownerId, ev.t)) - px,
    );
    if (dPx > EDGE_HANDLE_PX) continue;
    if (best === null || dPx < best.dPx) {
      best = { eventId: ev.id, ownerId, t: ev.t, dPx };
    }
  }
  return best === null
    ? null
    : { eventId: best.eventId, ownerId: best.ownerId, t: best.t };
}

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
    if (spanHitsX(eff.start, eff.end)) out.add(entityKey({ kind: "peer", id }));
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
      if (cx + EDGE_HANDLE_PX < xLo || cx - EDGE_HANDLE_PX > xHi) continue;
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
    if (row.kind === "category-collapsed" || row.kind === "category-header") {
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

/** Lane / entity context at a screen-y. Walks the canonical row
 * iteration the renderer uses, so hit-test geometry stays in
 * lockstep with paint even when categories expand into headers +
 * per-entity rows of mixed heights. Returns null for the ruler
 * row, the gutter, beyond the last row, or on a category-header
 * row (which has no event content — clicks on header rows toggle
 * expansion via `hitTestGutter`). `entityId` narrows event lookup
 * to a single entity on per-entity rows; collapsed rows leave it
 * null and the lane-level search applies. */
type LaneContext = {
  lane: "peers" | "sessions" | "messages";
  entityId: string | null;
};

/**
 * The row under the pointer, asking each question in the space that answers it.
 *
 * Two coordinate spaces meet here and conflating them cost every row below the
 * fold. The ruler band sits at the bottom of the HOST, so whether a point is in
 * it is a question about `hostY` and the host's height. Which row a point is on
 * is a question about the row stack, which scrolls, so it is asked in LAYOUT
 * coordinates. One `py` compared against both bounds rejected any row whose
 * layout y had passed the viewport's ruler line, however far the reader had
 * scrolled it into view, and it took the click and the cursor together because
 * both come through here. Marquee selection walks the rows itself and kept
 * working, which is what made the two disagree.
 */
function laneContextAtY(
  hostY: number,
  scrollY: number,
  height: number,
  rows: readonly RowDescriptor[],
): LaneContext | null {
  if (hostY < 0) return null;
  // Host space: the ruler is drawn at the bottom edge of this element.
  if (hostY >= height - RULER_HEIGHT) return null;
  // Layout space: the row stack is taller than the host and slides under it.
  const layoutY = hostY + scrollY;
  for (const row of rows) {
    if (layoutY < row.y || layoutY >= row.y + row.height) continue;
    if (row.kind === "category-collapsed") {
      return { lane: row.category, entityId: null };
    }
    if (row.kind === "category-header") {
      // Header has no event content — clicks here are gutter
      // chevron toggles, handled separately.
      return null;
    }
    if (row.kind === "entity-row") {
      return { lane: row.category, entityId: row.entityId };
    }
  }
  return null;
}

/** Pure hit-test against the doc events. Exposed so unit tests
 *  can exercise the geometry without spinning up a Pixi scene.
 *
 *  `rows` is the same row layout the renderer uses (from
 *  `iterateRows`); the lane + optional per-entity narrowing comes
 *  from whichever row the pointer y lands in. This keeps the
 *  click geometry in lockstep with paint when categories expand
 *  into headers + per-entity rows of mixed heights — previously
 *  the hit-test assumed every lane was exactly one
 *  `laneHeight + LANE_GAP` tall, which diverged from the paint as
 *  soon as a category expanded. */
export function hitTestEvents(
  px: number,
  py: number,
  width: number,
  height: number,
  view: TimelineView,
  events: readonly TimelineEvent[],
  rows: readonly RowDescriptor[],
  // `doc` is the source of truth the renderer reads via
  // `peerEffective` / `sessionEffective` / `messageEffective`. Span
  // hit-shapes resolve through the same helpers so a click on the
  // visible pill always succeeds — regardless of whether
  // observations and `entity.timing` have drifted (e.g. after an
  // authoring write that only mirrored one side). Observations are
  // still consulted to resolve the drag target's `eventId`.
  doc: TimelineDocument,
  /**
   * How far the row stack is scrolled under the host, so `py` can stay in the
   * host's own coordinates. Callers used to add this to `py` themselves, which
   * handed one number to two bounds that wanted different spaces; the row walk
   * needs the scrolled position and the ruler band does not.
   *
   * Defaults to zero, which is the unscrolled case a test constructs.
   */
  scrollY = 0,
): ScrubberHit | null {
  const ctx = laneContextAtY(py, scrollY, height, rows);
  if (!ctx) return null;
  // Reject clicks in the gutter (lane labels live there — no
  // t-content) and beyond the right pad (off-canvas). The left /
  // right PAD bands are visually empty but stay reachable so the
  // ±EDGE_HANDLE_PX tolerance around clamped pill edges still
  // succeeds — `pxAtClamped` below maps any clamped edge onto plotLeft,
  // so a click 6 px LEFT of t=0's clamped pill edge (i.e. inside
  // the left pad) lands on the edge instead of falling into a
  // dead zone the user can't see. Subsequent hit-testing is in
  // pixel-space because time-space comparisons reject zero-
  // duration spans (start == end) since `px → t` rarely lands
  // exactly on the entity's t.
  if (px < gutterWidthOf(view)) return null;
  if (px >= width - PLOT_RIGHT_PAD_PX + EDGE_HANDLE_PX) return null;
  // Mirror the renderer's left clamp so hit-test agrees with paint.
  // Long pills clamp their left edge to `plotStartXOf(view)`; zero-
  // span stamps clamp their center to `plotStartXOf + MIN_PILL_PX/2`.
  // If the event's natural px lands inside the left pad (scrolled-
  // off-screen entity rendered clamped at the visible edge), hit-
  // test against the clamped position so a click on the visible
  // shape succeeds.
  const plotLeft = plotStartXOf(view);
  const plotWidth = plotWidthOf(width, view);
  // Two t→px helpers coexist here, on purpose, and their names
  // encode the policy split so call sites can't confuse them.
  // `pxAtClamped` is a POINT clamp (left only) used by the edge-
  // priority pass and the glyph hit-test, which compare a single
  // px to a single point; left-clamping makes an off-screen-left
  // entity's edge grabbable at the visible plot edge. `tToPxRaw`
  // is unclamped and feeds `spanScreenRect` — which needs the raw
  // x0/x1 to compute its own `leftClamped`/`rightClamped` flags
  // before applying the both-side rect clamp.
  const pxAtClamped = (tt: number) => {
    const raw = tToCanvasPx(tt, width, view);
    return raw < plotLeft ? plotLeft : raw;
  };
  const tToPxRaw = (tt: number) => tToCanvasPx(tt, width, view);
  const { lane, entityId } = ctx;
  /** Body click envelope, lockstepped with paint via `spanScreenRect`:
   *  same plot-band clamp, same `SPAN_MIN_PILL_PX` stamp promotion for
   *  spans too short to render as a pill. `EDGE_HANDLE_PX` tolerance is
   *  added on each side so a click just past the visible pill still
   *  reads as a body hit (consistent with the legacy `hitsSpan` shape).
   *  Open-ended spans (`endT` non-finite) clamp their right edge to the
   *  plot's right boundary — `spanScreenRect` handles that internally. */
  const bodyRect = (startT: number, endT: number): SpanRect | null => {
    const rect = spanScreenRect({
      startT,
      endT,
      tToPx: tToPxRaw,
      plotX: plotLeft,
      plotWidth,
    });
    if (!rect) return null;
    if (px < rect.left - EDGE_HANDLE_PX) return null;
    if (px > rect.right + EDGE_HANDLE_PX) return null;
    return rect;
  };

  if (lane === "peers") {
    // Source of truth for the painted shape: `peerEffective` reads
    // the same `def.timing` the renderer paints, so the clickable
    // region always matches what the user sees. Observations are
    // consulted only to resolve the anchor `eventId` for the drag
    // target — finding the peer-joined / peer-left event by peerId.
    //
    // Priority: edges > body. Mirrors the session lane: a dedicated
    // edge-priority pass picks the closest endpoint across all peer
    // spans within EDGE_HANDLE_PX, so a click on a peer's edge wins
    // over a click on a different peer's body at the same x. Open-
    // ended peers still expose a left-edge handle (the right edge
    // is absent — endPx is null and skipped). This symmetry was the
    // structural fix behind bug #3a: the prior single-loop "best
    // body then check edges" branch couldn't reach a peer whose
    // body didn't contain the click even when its edge did.
    const peerIds = entityId !== null
      ? (doc.entities?.peers?.[entityId] ? [entityId] : [])
      : Object.keys(doc.entities?.peers ?? {});
    let bestEdge:
      | { peerId: string; dPx: number; rightEdge: boolean }
      | null = null;
    for (const peerId of peerIds) {
      const eff = peerEffective(doc, peerId);
      const startDPx = Math.abs(pxAtClamped(eff.start) - px);
      if (startDPx <= EDGE_HANDLE_PX) {
        if (!bestEdge || startDPx < bestEdge.dPx) {
          bestEdge = { peerId, dPx: startDPx, rightEdge: false };
        }
      }
      if (Number.isFinite(eff.end)) {
        const endDPx = Math.abs(pxAtClamped(eff.end) - px);
        if (endDPx <= EDGE_HANDLE_PX) {
          if (!bestEdge || endDPx < bestEdge.dPx) {
            bestEdge = { peerId, dPx: endDPx, rightEdge: true };
          }
        }
      }
    }
    if (bestEdge) {
      const target = findPeerAnchorEvent(
        events,
        bestEdge.peerId,
        bestEdge.rightEdge,
      );
      const entity: HitEntity = { kind: "peer", id: bestEdge.peerId };
      const effNow = peerEffective(doc, bestEdge.peerId);
      if (!target) {
        // No observation event to name — the span is `entity.timing`
        // alone (freshly authored). The gesture is the same resize;
        // it dispatches entity-addressed.
        return {
          entity,
          drag: {
            kind: "entity-span-edge",
            ref: { kind: "peer", id: bestEdge.peerId },
            originalT: bestEdge.rightEdge ? effNow.end : effNow.start,
            edge: bestEdge.rightEdge ? "right" : "left",
          },
        };
      }
      // `originalT` anchors the drag math (newT = originalT + dt) to
      // the visible edge — read from the effective resolver, the SOT
      // for the painted edge. Falling back to `target.t` (the anchor
      // observation event) breaks when Inspector edits to
      // entity.timing have moved the painted edge but left the
      // observation event's t stale: the first dt is applied to the
      // stale t, snapping the edge backward to where it used to be.
      const eff = peerEffective(doc, bestEdge.peerId);
      return {
        entity,
        drag: {
          kind: "span-edge",
          eventId: target.id,
          originalT: bestEdge.rightEdge ? eff.end : eff.start,
          edge: bestEdge.rightEdge ? "right" : "left",
        },
      };
    }
    // Rename glyphs next, on the same priority rule the session lane
    // uses below: edges beat diamonds, diamonds beat the body.
    const rename = nearestMoment(
      events,
      doc,
      "peers",
      entityId,
      px,
      pxAtClamped,
    );
    if (rename) {
      return {
        entity: { kind: "peer", id: rename.ownerId },
        drag: { kind: "moment", eventId: rename.eventId, originalT: rename.t },
      };
    }
    // Body hit: latest start wins (mirrors original pickLatestStart)
    // so overlapping spans pick the topmost (most recently joined).
    let best:
      | { peerId: string; startT: number; endT: number | null }
      | null = null;
    for (const peerId of peerIds) {
      const eff = peerEffective(doc, peerId);
      if (!bodyRect(eff.start, eff.end)) continue;
      const endT = Number.isFinite(eff.end) ? eff.end : null;
      if (!best || eff.start >= best.startT) {
        best = { peerId, startT: eff.start, endT };
      }
    }
    if (!best) return null;
    const target = findPeerAnchorEvent(events, best.peerId, false);
    const entity: HitEntity = { kind: "peer", id: best.peerId };
    // No anchor event = the span is `entity.timing` alone (freshly
    // authored peer). The body drag translates it entity-addressed.
    if (!target) {
      return {
        entity,
        drag: {
          kind: "entity-span-body",
          ref: { kind: "peer", id: best.peerId },
          originalT: best.startT,
        },
      };
    }
    return {
      entity,
      drag: { kind: "span-body", eventId: target.id, originalT: best.startT },
    };
  }

  if (lane === "sessions") {
    // Priority: edges > diamonds > body. Edges (session-opened /
    // -closed) are the retime handles; a click within EDGE_HANDLE_PX
    // of either MUST land on the edge so dragging retimes the pill,
    // even when a state-change diamond happens to sit at the same t
    // (e.g. final state change at session close).
    // Edge px comes from `sessionEffective` (same source as the
    // painted pill). Anchor event resolves through observations so
    // the drag target's `eventId` is well-defined.
    // Same id set is walked twice below (edges, then body) — hoisted.
    const sessionIds = entityId !== null
      ? (doc.entities?.sessions?.[entityId] ? [entityId] : [])
      : Object.keys(doc.entities?.sessions ?? {});
    let bestEdge:
      | { sessionId: string; dPx: number; rightEdge: boolean }
      | null = null;
    for (const sessionId of sessionIds) {
      const eff = sessionEffective(doc, sessionId);
      const startDPx = Math.abs(pxAtClamped(eff.start) - px);
      if (startDPx <= EDGE_HANDLE_PX) {
        if (!bestEdge || startDPx < bestEdge.dPx) {
          bestEdge = { sessionId, dPx: startDPx, rightEdge: false };
        }
      }
      if (Number.isFinite(eff.end)) {
        const endDPx = Math.abs(pxAtClamped(eff.end) - px);
        if (endDPx <= EDGE_HANDLE_PX) {
          if (!bestEdge || endDPx < bestEdge.dPx) {
            bestEdge = { sessionId, dPx: endDPx, rightEdge: true };
          }
        }
      }
    }
    if (bestEdge) {
      const target = findSessionAnchorEvent(
        events,
        bestEdge.sessionId,
        bestEdge.rightEdge,
      );
      if (!target) {
        // No observation event to name (freshly authored session):
        // same edge grab, dispatched entity-addressed.
        const eff = sessionEffective(doc, bestEdge.sessionId);
        return {
          entity: { kind: "session", id: bestEdge.sessionId },
          drag: {
            kind: "entity-span-edge",
            ref: { kind: "session", id: bestEdge.sessionId },
            originalT: bestEdge.rightEdge ? eff.end : eff.start,
            edge: bestEdge.rightEdge ? "right" : "left",
          },
        };
      }
      if (target) {
        // See peer-lane comment above: `originalT` reads from the
        // effective resolver so the drag math anchors at the painted
        // edge, not at a stale observation event t.
        const eff = sessionEffective(doc, bestEdge.sessionId);
        return {
          entity: { kind: "session", id: bestEdge.sessionId },
          drag: {
            kind: "span-edge",
            eventId: target.id,
            originalT: bestEdge.rightEdge ? eff.end : eff.start,
            // start-side edge hit = left edge; end-side = right.
            edge: bestEdge.rightEdge ? "right" : "left",
          },
        };
      }
    }
    // Glyphs (session-state-changed) next: single-moment overlays
    // painted ON TOP of session pill bodies; a click within
    // EDGE_HANDLE_PX should pick them over the body. Hit-test t
    // matches the lane-bundle's saturating clamp into the parent
    // session's effective span so clicking the VISIBLE diamond
    // succeeds even when the stored observation t drifts outside.
    const stateChange = nearestMoment(
      events,
      doc,
      "sessions",
      entityId,
      px,
      pxAtClamped,
    );
    if (stateChange) {
      return {
        entity: { kind: "session", id: stateChange.ownerId },
        drag: {
          kind: "moment",
          eventId: stateChange.eventId,
          originalT: stateChange.t,
        },
      };
    }
    // Body / span hit: same resolver-as-renderer principle as peers.
    // (`sessionIds` hoisted above the edge loop.)
    let best:
      | { sessionId: string; startT: number; endT: number | null }
      | null = null;
    for (const sessionId of sessionIds) {
      const eff = sessionEffective(doc, sessionId);
      if (!bodyRect(eff.start, eff.end)) continue;
      const endT = Number.isFinite(eff.end) ? eff.end : null;
      if (!best || eff.start >= best.startT) {
        best = { sessionId, startT: eff.start, endT };
      }
    }
    if (!best) return null;
    const startPx = pxAtClamped(best.startT);
    const endPx = best.endT !== null ? pxAtClamped(best.endT) : null;
    const dxRight = endPx !== null ? endPx - px : Number.POSITIVE_INFINITY;
    const dxLeft = px - startPx;
    const rightEdge = endPx !== null && dxRight <= EDGE_HANDLE_PX &&
      dxRight < dxLeft;
    const leftEdge = !rightEdge && endPx !== null &&
      dxLeft <= EDGE_HANDLE_PX && dxLeft < dxRight;
    const target = findSessionAnchorEvent(events, best.sessionId, rightEdge);
    const entity: HitEntity = { kind: "session", id: best.sessionId };
    // No anchor event = the span is `entity.timing` alone (freshly
    // authored session). The gesture dispatches entity-addressed.
    if (!target) {
      if (rightEdge || leftEdge) {
        return {
          entity,
          drag: {
            kind: "entity-span-edge",
            ref: { kind: "session", id: best.sessionId },
            originalT: rightEdge ? best.endT! : best.startT,
            edge: rightEdge ? "right" : "left",
          },
        };
      }
      return {
        entity,
        drag: {
          kind: "entity-span-body",
          ref: { kind: "session", id: best.sessionId },
          originalT: best.startT,
        },
      };
    }
    if (rightEdge || leftEdge) {
      return {
        entity,
        drag: {
          kind: "span-edge",
          eventId: target.id,
          // Anchor on the painted edge value, not the observation
          // event's t. `best.endT` is null only for open-ended
          // sessions, and `rightEdge` is unreachable in that case
          // (the right-edge hit-test guard above requires a finite
          // endpoint).
          originalT: rightEdge ? best.endT! : best.startT,
          edge: rightEdge ? "right" : "left",
        },
      };
    }
    return {
      entity,
      drag: { kind: "span-body", eventId: target.id, originalT: best.startT },
    };
  }

  // Messages: span shape comes from `messageEffective`, anchor
  // event from observations (the message-sent event by messageId).
  const messageIds = entityId !== null
    ? (doc.entities?.messages?.[entityId] ? [entityId] : [])
    : Object.keys(doc.entities?.messages ?? {});
  let bestMsg:
    | { messageId: string; startT: number; endT: number }
    | null = null;
  for (const messageId of messageIds) {
    const eff = messageEffective(doc, messageId);
    if (!Number.isFinite(eff.end)) continue;
    if (!bodyRect(eff.start, eff.end)) continue;
    if (!bestMsg || eff.start >= bestMsg.startT) {
      bestMsg = { messageId, startT: eff.start, endT: eff.end };
    }
  }
  if (!bestMsg) return null;
  const sentPx = pxAtClamped(bestMsg.startT);
  const arrivalPx = pxAtClamped(bestMsg.endT);
  const dxRight = arrivalPx - px;
  const dxLeft = px - sentPx;
  const rightEdge = dxRight <= EDGE_HANDLE_PX && dxRight < dxLeft;
  const leftEdge = !rightEdge && dxLeft <= EDGE_HANDLE_PX &&
    dxLeft < dxRight;
  const sentEv = events.find(
    (e): e is Extract<TimelineEvent, { kind: "message-sent" }> =>
      e.kind === "message-sent" && e.messageId === bestMsg!.messageId,
  );
  const entity: HitEntity = { kind: "message", id: bestMsg.messageId };
  // No anchor event = freshly authored message before any
  // message-sent observation; selectable but drag-suppressed.
  if (!sentEv) return { entity, drag: null };
  if (rightEdge || leftEdge) {
    return {
      entity,
      drag: {
        kind: "message-edge",
        eventId: sentEv.id,
        // Anchor on the painted endpoints (messageEffective), not the
        // observation event's sent/arrival t — Inspector edits to
        // entity timing move the painted shape but leave the
        // observation stale, which would snap the edge backward on
        // first dt.
        start: bestMsg.startT,
        end: bestMsg.endT,
        edge: rightEdge ? "right" : "left",
      },
    };
  }
  return {
    entity,
    drag: {
      kind: "message-body",
      eventId: sentEv.id,
      start: bestMsg.startT,
      end: bestMsg.endT,
    },
  };
}

/** Resolve the drag-target observation event for a peer body /
 *  edge hit. Right-edge gestures need the peer-left event; body
 *  and left-edge gestures retime via peer-joined. Returns null when
 *  the expected anchor event isn't present — the caller treats this
 *  as a non-hit so a phantom peer (def.timing without observations)
 *  doesn't claim a drag it can't actually execute. */
function findPeerAnchorEvent(
  events: readonly TimelineEvent[],
  peerId: string,
  rightEdge: boolean,
): TimelineEvent | null {
  for (const ev of events) {
    if (rightEdge && ev.kind === "peer-left" && ev.peerId === peerId) {
      return ev;
    }
    if (!rightEdge && ev.kind === "peer-joined" && ev.peerId === peerId) {
      return ev;
    }
  }
  return null;
}

function findSessionAnchorEvent(
  events: readonly TimelineEvent[],
  sessionId: string,
  rightEdge: boolean,
): TimelineEvent | null {
  for (const ev of events) {
    if (
      rightEdge && ev.kind === "session-closed" && ev.sessionId === sessionId
    ) {
      return ev;
    }
    if (
      !rightEdge && ev.kind === "session-opened" && ev.sessionId === sessionId
    ) {
      return ev;
    }
  }
  return null;
}
