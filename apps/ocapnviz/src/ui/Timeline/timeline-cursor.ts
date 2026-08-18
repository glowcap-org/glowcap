/**
 * The Timeline's side of the one cursor rule — `docs/cursor.md`,
 * for the two surfaces that are not the Stage.
 *
 * The Scrubber and the Overview own DOM hosts stacked above the unified
 * canvas, so each has to write its own element's cursor. What neither may do
 * is decide it. This module turns a pointer position into the `Hit` the
 * interactions vocabulary names, and hands that to `cursorFor` — the same
 * function the Stage asks, answering from the same `resolveGesture` a click
 * goes through.
 *
 * So the split is: geometry here, rule there. A cursor this file names
 * directly would be a second answer to a question `cursor.ts` already
 * answers, and the two would drift.
 *
 * Pure: no DOM, no React, no Pixi.
 */

import { allVisModeOnDoc, categoryVisModeOnDoc, rowVisModeOnDoc } from "../../engine/visibility.ts";
import { type CSSCursor, cursorFor } from "../../interactions/cursor.ts";
import {
  type DefaultVerb,
  type EntityRef,
  type Hit,
  navigationToolOf,
  type PointerMachineState,
  type PointerSnapshot,
  type SurfaceGestureCtx,
  type SurfaceId,
} from "../../interactions/types.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { GUTTER_DRAG_GRAB_PX, hitTestGutter, OVERVIEW_EDGE_GRAB_PX } from "./hit-test.ts";
import { hitTestEvents } from "./event-hit.ts";
import { eyeGlyphStatus, HEADER_EYEBALL_X } from "./gutter-paint.ts";
import { type RowDescriptor, RULER_HEIGHT } from "./row-layout.ts";
import { canvasPxToT, gutterWidthOf, plotStartXOf, plotWidthOf, type TimelineView } from "./state.ts";

/**
 * Hover title for a gutter eyeball — current stored mode, same verbs as the
 * undo label for setting that mode. Null when the pointer is not on an eye.
 */
export function eyeballHoverStatus(
  hit: Hit | null,
  doc: TimelineDocument,
): string | null {
  if (hit?.surface !== "timeline-gutter-eyeball") return null;
  switch (hit.scope.kind) {
    case "row":
      return eyeGlyphStatus(
        rowVisModeOnDoc(doc, hit.scope.category, hit.scope.entityId),
        { kind: "row" },
      );
    case "category":
      return eyeGlyphStatus(
        categoryVisModeOnDoc(doc, hit.scope.category),
        { kind: "category", category: hit.scope.category },
      );
    case "all":
      return eyeGlyphStatus(allVisModeOnDoc(doc), { kind: "all" });
  }
}

/**
 * The gesture a Timeline host is running, named where it starts.
 *
 * The pointer FSM would hold this; these two hosts still run their own drag
 * loops (§ 13), so each keeps it in a ref from pointerdown to teardown and
 * hands it back here. `verb` is the § 4.5 vocabulary, so the cursor for a
 * running gesture comes out of the same table as the cursor for an offered
 * one.
 */
export type TimelineGesture = { surface: SurfaceId; verb: DefaultVerb };

/** The pointer position, in the host element's own coordinates. */
export type HostPoint = { px: number; py: number };

/**
 * What the Scrubber is pointing at, and which gutter row that lights up.
 *
 * Two answers from one walk because they come from one hit test: the surface
 * the cursor describes and the row key the paint pass fills. The zone order
 * is the pointerdown handler's order — seam, gutter, scrub zone, lanes — so
 * the pointer promises the gesture the press will actually start.
 */
export function scrubberHoverAt(
  args: {
    point: HostPoint;
    /** Host size in CSS px. */
    size: { width: number; height: number };
    view: TimelineView;
    scrollY: number;
    rows: readonly RowDescriptor[];
    events: readonly TimelineEvent[];
    doc: TimelineDocument;
    /** Live mode suppresses seeking, so the scrub zone takes no click. */
    disabledScrub: boolean;
  },
): { hit: Hit | null; hoverKey: string | null } {
  const { point, size, view, scrollY, rows, events, doc } = args;
  const { px, py } = point;
  const gutter = gutterWidthOf(view);
  if (Math.abs(px - gutter) <= GUTTER_DRAG_GRAB_PX) {
    return { hit: { surface: "timeline-gutter-edge" }, hoverKey: "edge" };
  }
  if (px < gutter) return gutterHover(px, py + scrollY, rows, gutter);

  const lanesBottomY = (rows.length > 0 ? rows[rows.length - 1]!.y + rows[rows.length - 1]!.height : 0) - scrollY;
  const rulerTopY = size.height - RULER_HEIGHT;
  const t = canvasPxToT(px, size.width, view);
  if (py >= rulerTopY || py >= lanesBottomY) {
    // The ruler band plus the dead space between the last row and it: one
    // scrub zone, as the pointer host reads it. In Live the feed is
    // forward-only and the press does nothing, so there is nothing here to
    // describe — the same answer the left pad gives, where `t` is null.
    if (args.disabledScrub || t === null) return NOTHING;
    return { hit: { surface: "timeline-ruler", t }, hoverKey: null };
  }

  const event = hitTestEvents(
    px,
    py,
    size.width,
    size.height,
    view,
    events,
    rows,
    doc,
    scrollY,
  );
  if (event !== null) {
    const entityRef: EntityRef = event.entity;
    const plan = event.drag;
    const onEdge = plan?.kind === "span-edge" ||
      plan?.kind === "entity-span-edge" ||
      plan?.kind === "message-edge";
    // An entity-addressed plan retimes a span no observation names, so it
    // carries no event id. The pill picks and drags the same either way.
    const eventId = plan === null ||
        plan.kind === "entity-span-edge" ||
        plan.kind === "entity-span-body"
      ? null
      : plan.eventId;
    return {
      hit: onEdge
        ? { surface: "timeline-lane-event-right-edge", eventId, entityRef }
        : { surface: "timeline-lane-event", eventId, entityRef },
      hoverKey: null,
    };
  }
  if (t === null) return NOTHING;
  return { hit: { surface: "timeline-lane-empty", t }, hoverKey: null };
}

const NOTHING: { hit: Hit | null; hoverKey: string | null } = {
  hit: null,
  hoverKey: null,
};

/** The gutter's controls, and the row key each one lights. */
function gutterHover(
  px: number,
  layoutY: number,
  rows: readonly RowDescriptor[],
  gutter: number,
): { hit: Hit | null; hoverKey: string | null } {
  const hit = hitTestGutter(px, layoutY, rows, gutter);
  switch (hit?.kind) {
    case "chevron":
      return {
        hit: { surface: "timeline-gutter-chevron", category: hit.category },
        hoverKey: `header:${hit.category}`,
      };
    case "category-eyeball":
      return {
        hit: {
          surface: "timeline-gutter-eyeball",
          scope: { kind: "category", category: hit.category },
        },
        hoverKey: `category-eye:${hit.category}`,
      };
    case "eyeball":
      return {
        hit: {
          surface: "timeline-gutter-eyeball",
          scope: {
            kind: "row",
            category: hit.category,
            entityId: hit.entityId,
          },
        },
        hoverKey: `entity:${hit.category}:${hit.entityId}`,
      };
    case "row-drag":
      return {
        hit: {
          surface: "timeline-gutter-label",
          category: hit.category,
          entityId: hit.entityId,
        },
        hoverKey: `entity:${hit.category}:${hit.entityId}`,
      };
    default:
      // Gutter, but not on a control. The press no-ops, so nothing to say.
      return NOTHING;
  }
}

/** The three surfaces the Overview strip can produce. Named so a caller can
 *  read the hit's own `t` without re-deriving it. */
export type OverviewHit = Extract<
  Hit,
  {
    surface:
      | "timeline-overview"
      | "timeline-overview-edge"
      | "timeline-gutter-eyeball";
  }
>;

/**
 * What the Overview is pointing at.
 *
 * Three zones on the strip: a grip on either end of the visible-window rect,
 * and everything else on the plot, which pans — from inside the rect by
 * dragging it, from outside by jumping it here first. The gutter holds one
 * control, the all-rows eyeball.
 */
export function overviewHitAt(
  args: {
    px: number;
    width: number;
    view: TimelineView;
    duration: number;
    /** False when no all-rows callback is wired, so the eyeball is not
     *  painted and there is no control to point at. */
    hasAllRowsEyeball: boolean;
  },
): OverviewHit | null {
  const { px, width, view, duration } = args;
  const plotStart = plotStartXOf(view);
  if (px < plotStart) {
    const onEye = args.hasAllRowsEyeball &&
      px >= HEADER_EYEBALL_X - 8 && px < HEADER_EYEBALL_X + 8;
    return onEye ? { surface: "timeline-gutter-eyeball", scope: { kind: "all" } } : null;
  }
  const plotW = plotWidthOf(width, view);
  if (plotW <= 0) return null;
  const span = Math.max(duration, 1);
  const t = Math.max(
    0,
    Math.min(duration, ((px - plotStart) / plotW) * span),
  );
  const startPx = plotStart + (view.windowStart / span) * plotW;
  const endPx = plotStart + (view.windowEnd / span) * plotW;
  if (Math.abs(px - startPx) <= OVERVIEW_EDGE_GRAB_PX) {
    return { surface: "timeline-overview-edge", edge: "start", t };
  }
  if (Math.abs(px - endPx) <= OVERVIEW_EDGE_GRAB_PX) {
    return { surface: "timeline-overview-edge", edge: "end", t };
  }
  return { surface: "timeline-overview", t };
}

/**
 * THE cursor for a Timeline host, straight out of `cursorFor`.
 *
 * The rule is shared with the Stage and the vocabulary is the same, so a
 * modifier held over a lane previews the same selection edit it previews over
 * the canvas. What does not carry across is the build tools. Nothing any of
 * them does lands on the Timeline, so a `crosshair` over a lane or a `cell`
 * over the gutter would be advertising a next click no Timeline surface can
 * perform, and `navigationToolOf` is where that stops.
 *
 * It reads in both directions, which is why the tool is narrowed here rather
 * than the one rung being suppressed. These hosts never consult the active tool
 * on the way to a click, so a lane click selects under Send Message exactly as
 * it does under Select; narrowing means the Shift preview appears there too,
 * where suppressing the tool's own cursor alone would have left it missing.
 * `cursor.ts` scopes the rung by surface as well, so a third host wiring itself
 * to the ladder is safe without knowing to do this.
 *
 * The other thing this adds is `toolState: null`. A two-click pick arms on a
 * stage node, and no Timeline surface is one, so no hit here can resolve to
 * the pick the armed node would qualify. The Stage feeds its own armed pick
 * because that is where a pick can be about to complete.
 */
export function timelineCursor(
  args: {
    hit: Hit | null;
    /** The gesture the host is running, or null when it is only hovering. */
    inFlight: TimelineGesture | null;
    /** Space, the active tool, and the keys held right now, from the App's
     *  one keyboard authority — a modifier pressed over a still pointer
     *  changes the next click, so the cursor has to hear about it. */
    gestureCtx: SurfaceGestureCtx;
  },
): CSSCursor {
  return cursorFor(
    {
      ...args.gestureCtx,
      activeTool: navigationToolOf(args.gestureCtx.activeTool),
      toolState: null,
    },
    machineFor(args.hit, args.inFlight),
  );
}

/** A pointer snapshot carries where and when a press happened. These hosts
 *  keep neither for the cursor's sake, and `cursorFor` reads neither: from a
 *  running gesture it reads the resolved verb alone. */
const UNKNOWN_SNAPSHOT: PointerSnapshot = {
  clientX: 0,
  clientY: 0,
  buttons: 1,
  modifiers: { shift: false, cmd: false, alt: false },
  timestampMs: 0,
};

function machineFor(
  hit: Hit | null,
  inFlight: TimelineGesture | null,
): PointerMachineState {
  const hover = hit === null ? null : { surface: hit.surface, hit };
  if (inFlight === null) return { fsm: { kind: "idle" }, hover, lastUp: null };
  return {
    fsm: {
      kind: "dragging",
      surface: inFlight.surface,
      resolved: { tier: "default", verb: inFlight.verb },
      start: UNKNOWN_SNAPSHOT,
      current: UNKNOWN_SNAPSHOT,
    },
    hover,
    lastUp: null,
  };
}
