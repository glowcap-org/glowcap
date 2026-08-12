/**
 * Timeline view state — the visible window into `[0, doc.duration]`,
 * plus follow-live behavior and per-lane expansion. All operations
 * are pure functions over the view; the React layer (`useTimelineView`)
 * wraps them in a reducer so component re-renders stay disciplined.
 */

import { pickTickStep } from "./ticks.ts";

export type LaneKind = "ruler" | "peers" | "sessions" | "messages";

export type TimelineView = {
  /** Left edge of the visible window, in simulated ms. */
  windowStart: number;
  /** Right edge of the visible window, in simulated ms. */
  windowEnd: number;
  /** Lanes currently visible at all. `"ruler"` is implicit and
   * always shown; the others are opt-in. */
  expandedLanes: ReadonlySet<LaneKind>;
  /** Categories (subset of expandedLanes) drawn as a per-entity
   * row stack instead of today's flat stacked-spans summary. UI-
   * state only — not persisted onto `TimelineDocument`. A category
   * can be visible (in `expandedLanes`) AND collapsed (NOT in
   * `expandedCategories`) — that's today's default look. */
  expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>;
  /** Optional per-view gutter width override. When set, replaces
   * the default `LANE_LABEL_WIDTH` for px↔t math AND row-label
   * layout. Drag-resize updates this; reload restores it via the
   * usual view persistence. Falls back to `LANE_LABEL_WIDTH` when
   * absent so older persisted views keep working. */
  gutterWidth?: number;
};

/** Smallest window we allow zooming into, in ms. Below this the
 * ruler ticks degenerate. */
export const MIN_WINDOW_MS = 5;

/** Default gutter width — runtime uses `view.gutterWidth ?? LANE_LABEL_WIDTH`.
 *  104 fits chevron + eyeball + the longest built-in category label
 *  ("messages") without truncation; matches `GUTTER_MIN_PX` so the
 *  resize floor is also the default. Below the gutter, px↔t conversions
 *  treat the band as a dead zone (returns `null`). */
export const LANE_LABEL_WIDTH = 104;

/** Resize bounds. Min must clear chevron + category-eyeball + a short
 *  label ("peers" / "sessions" / "messages") AND the per-entity rows'
 *  own eyeball+label; max guards against eating the whole plot. */
export const GUTTER_MIN_PX = 104;
export const GUTTER_MAX_PX = 320;

/** Breathing-room band on each side of the plot's t-content. Left
 *  pad sits between the gutter divider and the leftmost paintable
 *  pixel of content (playhead, ticks, spans, glyphs); right pad
 *  reserves the matching gap before the canvas's right edge. Both
 *  thread through `plotWidthOf` / `tToCanvasPx` / `canvasPxToT` so
 *  every px↔t conversion, paint pass, and hit-test clamps to the
 *  inset band without having to special-case the edges themselves.
 *  Row backgrounds (zebra, header tint, drag overlays) paint
 *  THROUGH both pads — the bands are content-clamp, not visual-
 *  hide. */
export const PLOT_LEFT_PAD_PX = 4;
export const PLOT_RIGHT_PAD_PX = 4;

/** Per-view effective gutter width — the override on the view or
 *  the package default. Use this everywhere instead of the bare
 *  constant so a wider gutter sticks to its column. */
export function gutterWidthOf(v: TimelineView): number {
  const w = v.gutterWidth;
  if (typeof w !== "number" || !Number.isFinite(w)) return LANE_LABEL_WIDTH;
  return Math.max(GUTTER_MIN_PX, Math.min(GUTTER_MAX_PX, w));
}

/** Canvas-relative pixel of the plot's leftmost CONTENT column —
 *  the gutter width plus the left breathing pad. Anything painting
 *  t-content (playhead, ticks, spans, glyphs, visible-window rect
 *  in Overview) anchors here so a t at `windowStart` lands inside
 *  the pad, mirroring the right edge. The gutter SEPARATOR itself
 *  still sits at `gutterWidthOf(v) + 0.5` — that line marks the
 *  gutter↔plot boundary, not where content starts. */
export function plotStartXOf(v: TimelineView): number {
  return gutterWidthOf(v) + PLOT_LEFT_PAD_PX;
}

/** Pixel width of the plot's t-content area inside a canvas of
 *  total `width`. Returns 0 if the canvas is narrower than the
 *  gutter plus both pads. Both pads keep the t-content axis from
 *  slamming against the gutter divider on the left or the panel
 *  edge on the right. */
export function plotWidthOf(width: number, v: TimelineView): number {
  return Math.max(
    0,
    width - gutterWidthOf(v) - PLOT_LEFT_PAD_PX - PLOT_RIGHT_PAD_PX,
  );
}

/** Convert a canvas-relative pixel offset (where 0 = canvas's
 *  left edge, including the gutter) into a sim-time `t`. Returns
 *  `null` for clicks inside the gutter, the left-edge pad, or the
 *  right-edge pad — all three are dead zones, callers no-op
 *  cleanly. */
export function canvasPxToT(
  canvasPx: number,
  canvasWidth: number,
  v: TimelineView,
): number | null {
  const plotX = plotStartXOf(v);
  if (canvasPx < plotX) return null;
  if (canvasPx >= canvasWidth - PLOT_RIGHT_PAD_PX) return null;
  const plotW = plotWidthOf(canvasWidth, v);
  if (plotW <= 0) return null;
  return pxToT(canvasPx - plotX, plotW, v);
}

/** Convert a sim-time `t` into a canvas-relative pixel offset
 *  (gutter + left-pad shifted). Inverse of [`canvasPxToT`] minus
 *  the `null`-on-deadzone behavior. */
export function tToCanvasPx(
  t: number,
  canvasWidth: number,
  v: TimelineView,
): number {
  return plotStartXOf(v) + tToPx(t, plotWidthOf(canvasWidth, v), v);
}

/** deltaY → zoom factor mapping. Empirical: feels like
 * pixi-viewport on the canvas. */
const WHEEL_ZOOM_RATE = 0.0015;

/**
 * Wheel-event dispatch used by both the Scrubber and Overview
 * canvases. Resolves the heuristic for "is this a pan or a zoom?"
 * from `WheelEvent` deltas:
 *
 *   - `|deltaX| > |deltaY|`  → horizontal pan (trackpad swipe).
 *   - `Shift + deltaY`       → horizontal pan (mouse-wheel users).
 *   - otherwise              → zoom around `cursorPx`.
 *
 * Shift is pan here, not a zoom multiplier — the stage's wheel
 * uses Shift for fast zoom; the timeline already spent Shift on
 * selection, so the wheel matches Alt+drag's "pan the window"
 * rather than inventing a third Shift meaning.
 *
 * Returns the next view.
 *
 * `cursorPx` is canvas-relative (0 = canvas left edge, including
 * the gutter). When the cursor is over the gutter, zoom anchors at
 * the visible-window midpoint as a sensible fallback.
 */
export function applyWheel(
  e: { deltaX: number; deltaY: number; shiftKey: boolean },
  v: TimelineView,
  duration: number,
  cursorPx: number,
  canvasWidth: number,
  maxWidth: number = duration,
  panMaxT: number = duration,
): TimelineView {
  const plotW = plotWidthOf(canvasWidth, v);
  const horizontal = Math.abs(e.deltaX) > Math.abs(e.deltaY) ||
    (e.shiftKey && e.deltaY !== 0 && e.deltaX === 0);
  if (horizontal) {
    // Pan: a pixel of horizontal scroll moves the window by the
    // same fraction of its visible duration as a pixel of drag.
    const dx = e.deltaX !== 0 ? e.deltaX : e.deltaY;
    if (plotW <= 0) return v;
    const dt = (dx / plotW) * (v.windowEnd - v.windowStart);
    return pan(v, dt, duration, maxWidth, panMaxT);
  }
  // Zoom.
  const t = canvasPxToT(cursorPx, canvasWidth, v) ??
    (v.windowStart + v.windowEnd) / 2;
  const zoomDelta = -e.deltaY * WHEEL_ZOOM_RATE;
  const factor = Math.exp(zoomDelta);
  return zoomAround(v, t, factor, duration, maxWidth, panMaxT);
}

/** Default lanes opened when the timeline first mounts. */
export const DEFAULT_EXPANDED: ReadonlySet<LaneKind> = new Set([
  "ruler",
  "peers",
  "sessions",
  "messages",
]);

export function defaultView(duration: number): TimelineView {
  return {
    windowStart: 0,
    windowEnd: Math.max(MIN_WINDOW_MS, duration),
    expandedLanes: DEFAULT_EXPANDED,
    // All categories ship collapsed — today's stacked-spans look
    // is still the default. User opts in to per-entity view by
    // clicking the category chevron.
    expandedCategories: new Set(),
  };
}

/** Clamp the window to honor three independent bounds while
 * preserving the requested width as much as possible:
 *
 *   - **Width** ≤ `maxWidth`. The zoom-out floor.
 *   - **`windowStart`** ≥ 0. Time can't go negative — there's
 *     no "before-zero". Pan-left bottoms out at the origin.
 *   - **`windowEnd`** ≤ `panMaxT`. The pan-right cap. Play /
 *     Build pass `panMaxT = duration` so pan stops at the
 *     doc end; Live passes `panMaxT = Infinity` so pan-right
 *     is unbounded — the timeline has no end, only the captured
 *     history.
 *
 * Width is computed first; then we anchor windowStart ≥ 0 and
 * push windowEnd in from the right if it overshoots panMaxT.
 *
 * `maxWidth` and `panMaxT` both default to `duration` — Play /
 * Build's historical single-bound behavior collapses to one
 * value: width never exceeds the doc, pan never exceeds the
 * doc, and pan-right at 1× snaps back to `[0, duration]` (the
 * "no point in panning a fully-fit view" semantic). The
 * `duration` parameter is retained for that default-arg shape;
 * the clamp logic itself uses only the explicit bounds. */
export function clampView(
  v: TimelineView,
  duration: number,
  maxWidth: number = duration,
  panMaxT: number = duration,
): TimelineView {
  const requestedWidth = v.windowEnd - v.windowStart;
  const width = Math.max(MIN_WINDOW_MS, Math.min(maxWidth, requestedWidth));
  let start = Math.max(0, v.windowStart);
  let end = start + width;
  if (end > panMaxT) {
    end = panMaxT;
    start = Math.max(0, end - width);
  }
  return { ...v, windowStart: start, windowEnd: end };
}

/**
 * Zoom around a focal point `t` (typically the cursor's time
 * position). `factor > 1` zooms IN (window shrinks); `factor < 1`
 * zooms OUT. The proportion of the window to the left of `t` is
 * preserved, so the focal point stays under the cursor.
 */
export function zoomAround(
  v: TimelineView,
  t: number,
  factor: number,
  duration: number,
  maxWidth: number = duration,
  panMaxT: number = duration,
): TimelineView {
  const width = v.windowEnd - v.windowStart;
  const newWidth = Math.max(
    MIN_WINDOW_MS,
    Math.min(maxWidth, width / factor),
  );
  const tFrac = width === 0 ? 0.5 : (t - v.windowStart) / width;
  const start = t - newWidth * tFrac;
  const end = start + newWidth;
  return clampView(
    { ...v, windowStart: start, windowEnd: end },
    duration,
    maxWidth,
    panMaxT,
  );
}

/** Pan the window by `deltaMs`. Positive = right (later); negative
 * = left (earlier). Bounded by `panMaxT` on the right (`Infinity`
 * lets Live mode pan into "future" empty space; finite values
 * cap pan at the doc end); width preserved. */
export function pan(
  v: TimelineView,
  deltaMs: number,
  duration: number,
  maxWidth: number = duration,
  panMaxT: number = duration,
): TimelineView {
  return clampView(
    {
      ...v,
      windowStart: v.windowStart + deltaMs,
      windowEnd: v.windowEnd + deltaMs,
    },
    duration,
    maxWidth,
    panMaxT,
  );
}

/** Make the window snap to fit the entire `[0, duration]` range. */
export function fitAll(v: TimelineView, duration: number): TimelineView {
  return clampView(
    { ...v, windowStart: 0, windowEnd: Math.max(MIN_WINDOW_MS, duration) },
    duration,
  );
}

/** Make the window slide so that `t` is centered (or as centered as
 * the window edges allow). Used by the live-mode follow logic. */
export function centerOn(
  v: TimelineView,
  t: number,
  duration: number,
): TimelineView {
  const width = v.windowEnd - v.windowStart;
  return clampView(
    { ...v, windowStart: t - width / 2, windowEnd: t + width / 2 },
    duration,
  );
}

/**
 * Convert a pixel offset within the scrubber's rendered width into a
 * sim-time `t`. Inverse of [`tToPx`].
 */
export function pxToT(
  px: number,
  scrubberWidth: number,
  v: TimelineView,
): number {
  if (scrubberWidth <= 0) return v.windowStart;
  const frac = px / scrubberWidth;
  return v.windowStart + frac * (v.windowEnd - v.windowStart);
}

/**
 * Convert a sim-time `t` into a pixel offset within the scrubber's
 * rendered width. Returns values outside `[0, scrubberWidth]` when
 * `t` is outside the visible window — callers cull off-screen
 * glyphs themselves.
 */
export function tToPx(
  t: number,
  scrubberWidth: number,
  v: TimelineView,
): number {
  const width = v.windowEnd - v.windowStart;
  if (width <= 0) return 0;
  return ((t - v.windowStart) / width) * scrubberWidth;
}

/** Snap a sim-time `t` to the nearest major tick of the
 * current view's tick grid (the SAME grid the ruler shows).
 * Used by the Flash-grade snap-to-grid drag modifier (Shift):
 * the user sees the major ticks they're snapping to so the
 * snap targets are predictable. Returns the snapped t; may
 * equal `t` if already on a tick boundary.
 *
 * `targetMajorPx ≈ 90` matches the Scrubber's TARGET_MAJOR_PX
 * (the spacing the ruler aims for). Out-of-band inputs (negative
 * plotWidth, zero window) pass through unchanged. */
export function snapToMajorTick(
  t: number,
  v: TimelineView,
  plotWidth: number,
  targetMajorPx = 90,
): number {
  const windowMs = v.windowEnd - v.windowStart;
  if (windowMs <= 0 || plotWidth <= 0) return t;
  const pxPerMs = plotWidth / windowMs;
  const step = pickTickStep(pxPerMs, targetMajorPx).major;
  if (step <= 0) return t;
  return Math.round(t / step) * step;
}
