/**
 * Span screen-geometry — the single source of truth for "where on
 * the canvas does this t-range live?" Used by both lane-paint
 * (deciding pill vs stamp, clamping to the plot band) and hit-test
 * (building the click envelope around what the user can actually
 * see). Keeping the math here means paint and hit-test cannot drift:
 * one function, one clamp policy, one minimum-width rule.
 *
 * Stamp/bucket layout (count badges, label placement) and pill
 * styling (color, radius application, edge-fade stripes) stay in
 * the painter — those don't affect hit-testability. The contract
 * here is narrower: clamp the on-screen rect of a single span,
 * report whether it had to be promoted to its minimum-width stamp.
 */
import { type TimelineView, tToCanvasPx } from "./state.ts";

/** Minimum visible pill width before paint demotes the span to a
 *  stamp (a fixed-footprint left-anchored marker). Hit-test uses
 *  the same minimum so a span too short to render as a pill is
 *  still as clickable as the stamp the user sees. Independent of
 *  hit-test's `EDGE_HANDLE_PX` (which is a click tolerance around
 *  an edge, not a paint footprint) — the two happen to be equal
 *  by coincidence, NOT by structural linkage. */
export const SPAN_MIN_PILL_PX = 6;

/** Corner radius for pill paint. Shared so painters that compose
 *  pills (lane spans, count badges, selection halo) agree. */
export const SPAN_RADIUS = 3;

/** Vertical inset of the pill from the lane row (top + bottom). */
export const SPAN_PILL_INSET_Y = 2;

export type SpanRect = {
  /** Canvas-px left edge — clamped to `plotX`. */
  left: number;
  /** Canvas-px right edge — clamped to `plotX + plotWidth`. For
   *  open-ended spans (endT non-finite) `right` is the plot's right
   *  boundary, so the visible pill still has a real right edge for
   *  paint and a real hit envelope for hit-test. */
  right: number;
  /** True when the unclamped width was below `SPAN_MIN_PILL_PX`,
   *  so paint draws a fixed-footprint stamp at the start anchor and
   *  hit-test inherits the same minimum width. */
  isStamp: boolean;
  /** True when the unclamped left edge was below `plotX` — the span
   *  starts before the visible window. Paint draws a left-edge
   *  fade as a "trails off to the left" cue; hit-test ignores. */
  leftClamped: boolean;
  /** True when the unclamped right edge was past `plotX + plotWidth`
   *  — the span extends past the visible window OR the span is
   *  open-ended (endT non-finite). Paint draws a right-edge fade;
   *  hit-test ignores. The open-ended case folds in here because
   *  it's the same paint behavior: a "trails off to the right" cue
   *  with no real entity edge to grab. Right-edge resize-handle
   *  suppression for open-ended spans lives at the call site
   *  (`Number.isFinite(eff.end)` in the edge-priority pass), not in
   *  this rect. */
  rightClamped: boolean;
};

/** Compute the on-screen rect of a span — what the renderer paints,
 *  what hit-test should accept clicks against. Returns null when the
 *  span is fully outside the visible plot band.
 *
 *  Single source of truth for "where does this span live on screen"
 *  — the resolver-as-renderer doctrine, extended into pixel space.
 *  Paint reads it to decide long-pill vs stamp and to clamp the pill
 *  to the plot band; hit-test reads it to build the click envelope.
 *  The two stay in lockstep by construction. */
export function spanScreenRect(args: {
  startT: number;
  endT: number;
  tToPx: (t: number) => number;
  plotX: number;
  plotWidth: number;
}): SpanRect | null {
  const { startT, endT, tToPx, plotX, plotWidth } = args;
  const x0 = tToPx(startT);
  const openEnded = !Number.isFinite(endT);
  const plotRight = plotX + plotWidth;
  const x1Raw = openEnded ? plotRight : tToPx(endT);
  const rawWidth = x1Raw - x0;
  const isStamp = rawWidth < SPAN_MIN_PILL_PX;
  const x1 = isStamp ? x0 + SPAN_MIN_PILL_PX : x1Raw;
  const left = Math.max(plotX, x0);
  const right = Math.min(plotRight, x1);
  if (right <= left) return null;
  const leftClamped = x0 < plotX;
  const rightClamped = openEnded || x1Raw > plotRight;
  return { left, right, isStamp, leftClamped, rightClamped };
}

/** Convenience wrapper that resolves `tToPx` from a `TimelineView`
 *  and total canvas `width`. The plot band is derived from the same
 *  `plotStartXOf` / `plotWidthOf` helpers paint uses, so callers
 *  don't have to thread the same three params through every call
 *  site. Pass `plotX` and `plotWidth` explicitly only when the
 *  caller is operating on a non-standard band (e.g. Overview's
 *  scaled bird's-eye view). */
export function spanScreenRectFromView(
  startT: number,
  endT: number,
  view: TimelineView,
  width: number,
  plotX: number,
  plotWidth: number,
): SpanRect | null {
  return spanScreenRect({
    startT,
    endT,
    tToPx: (t) => tToCanvasPx(t, width, view),
    plotX,
    plotWidth,
  });
}
