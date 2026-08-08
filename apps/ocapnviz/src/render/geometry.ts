/**
 * Geometry helpers for hit-test and marquee selection. Pure math —
 * no Pixi, no engine. Extracted from `Stage.tsx` so the scene file
 * holds wiring + handlers, not standalone overlap/intersection
 * functions.
 *
 * `paintMarchingAntsBand` does need a Pixi `Graphics` — it stamps
 * a 1-pixel marching-ants outline. Kept here because it belongs
 * with the segment/rect functions used by the same marquee
 * subsystem.
 */

import type { Graphics } from "pixi.js";

/** Axis-aligned rectangle in surface-local coordinates. */
export type Rect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

/** Half-open clamp bounds. `maxX` / `maxY` are exclusive in the same
 *  sense as canvas dimensions — a rect that ends exactly at `maxX`
 *  reads as flush-right against the edge. */
export type Bounds = {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
};

/** Clamp a rectangle's corners into `bounds`. Returns a rect whose
 *  edges lie within `[minX, maxX] × [minY, maxY]`. If the input rect
 *  is entirely outside, the result has zero width or height — callers
 *  shouldn't need to special-case that (paint and overlap helpers
 *  already early-out on zero-area).
 *
 *  Shared by every selection-marquee surface in the app so the
 *  visible marquee and the committed selection rect stay identical
 *  (WYSIWYG). Each surface defines its own `Bounds` — Stage uses
 *  host-element dimensions; Scrubber uses its plot content rect —
 *  and calls this at both paint and commit sites.  */
/** Build an axis-aligned `Rect` from two corner points in the same
 *  coordinate space. Order-independent. Shared by every drag-rect
 *  surface (Stage marquee, Scrubber marquee) so the "two pointer
 *  positions → AABB" conversion is spelled the same way everywhere. */
export function rectFromCorners(
  ax: number,
  ay: number,
  bx: number,
  by: number,
): Rect {
  return {
    x: Math.min(ax, bx),
    y: Math.min(ay, by),
    width: Math.abs(bx - ax),
    height: Math.abs(by - ay),
  };
}

export function clampRectToBounds(rect: Rect, bounds: Bounds): Rect {
  const x0 = Math.max(bounds.minX, rect.x);
  const y0 = Math.max(bounds.minY, rect.y);
  const x1 = Math.min(bounds.maxX, rect.x + rect.width);
  const y1 = Math.min(bounds.maxY, rect.y + rect.height);
  return {
    x: x0,
    y: y0,
    width: Math.max(0, x1 - x0),
    height: Math.max(0, y1 - y0),
  };
}

/** Rectangle ↔ circle overlap. True iff any point inside the
 *  circle (center cx, cy, radius r) lies inside the axis-aligned
 *  rect [rx0, rx1] × [ry0, ry1]. Implemented as: find the closest
 *  point on the rect to the circle center; the circle overlaps
 *  iff that point lies within `r` of the center. */
export function rectCircleOverlap(
  rx0: number,
  ry0: number,
  rx1: number,
  ry1: number,
  cx: number,
  cy: number,
  r: number,
): boolean {
  const closestX = cx < rx0 ? rx0 : cx > rx1 ? rx1 : cx;
  const closestY = cy < ry0 ? ry0 : cy > ry1 ? ry1 : cy;
  const dx = cx - closestX;
  const dy = cy - closestY;
  return dx * dx + dy * dy <= r * r;
}

/** Proper segment-segment intersection (parametric). Excludes the
 *  collinear case (returns false); for marquee selection the
 *  endpoint-in-rect check covers collinear segments touching the
 *  rect anyway. */
export function segmentsIntersect(
  p1x: number,
  p1y: number,
  p2x: number,
  p2y: number,
  p3x: number,
  p3y: number,
  p4x: number,
  p4y: number,
): boolean {
  const d = (p2x - p1x) * (p4y - p3y) - (p2y - p1y) * (p4x - p3x);
  if (d === 0) return false;
  const t = ((p3x - p1x) * (p4y - p3y) - (p3y - p1y) * (p4x - p3x)) / d;
  const u = ((p3x - p1x) * (p2y - p1y) - (p3y - p1y) * (p2x - p1x)) / d;
  return t >= 0 && t <= 1 && u >= 0 && u <= 1;
}

/** Rectangle ↔ line-segment overlap. True iff the segment
 *  (ax, ay) → (bx, by) intersects, is fully inside, or touches
 *  the axis-aligned rect [rx0, rx1] × [ry0, ry1]. */
export function rectSegmentOverlap(
  rx0: number,
  ry0: number,
  rx1: number,
  ry1: number,
  ax: number,
  ay: number,
  bx: number,
  by: number,
): boolean {
  if (ax >= rx0 && ax <= rx1 && ay >= ry0 && ay <= ry1) return true;
  if (bx >= rx0 && bx <= rx1 && by >= ry0 && by <= ry1) return true;
  if (segmentsIntersect(ax, ay, bx, by, rx0, ry0, rx1, ry0)) return true;
  if (segmentsIntersect(ax, ay, bx, by, rx1, ry0, rx1, ry1)) return true;
  if (segmentsIntersect(ax, ay, bx, by, rx0, ry1, rx1, ry1)) return true;
  if (segmentsIntersect(ax, ay, bx, by, rx0, ry0, rx0, ry1)) return true;
  return false;
}

/** Length (in perimeter pixels) of a single fg or bg dash. 2 px
 *  matches the classic Mac / early-Photoshop marching-ants look
 *  (fine pattern, not chunky); paired with the per-frame ticker it
 *  still reads smooth because the phase increments one pixel at a
 *  time. */
const ANT_DASH_PX = 2;

/** Wall-clock ms between phase steps. Phase advances ONE PIXEL per
 *  ANT_MS along the perimeter — with 2-px dashes that's half a dash
 *  per step, keeping the march fluid rather than stepped while
 *  preserving the old-school cadence. Centralized here so every
 *  marquee in the app marches at the same speed. */
const ANT_MS = 30;

/** Paint a 1-pixel marching-ants rectangle outline into a Graphics.
 *
 * Two passes (one per color) so a single `.fill` covers all the fg
 * pixels and another covers the bg pixels — fewer state changes
 * than per-pixel fills. The perimeter is treated as a 1D line of
 * pixels in clockwise order; each consecutive run of `ANT_DASH_PX`
 * pixels is one dash, alternating fg/bg. `phase` shifts the whole
 * pattern along the perimeter; incrementing it 1 pixel at a time
 * slides the dash-boundaries gradually through the dash, which
 * reads as smooth motion at any rate. */
function paintAntsRect(
  g: Graphics,
  x: number,
  y: number,
  w: number,
  h: number,
  phase: number,
): void {
  const perim = 2 * w + 2 * h;
  if (perim <= 0) return;
  const period = ANT_DASH_PX * 2;
  for (let parity = 0; parity < 2; parity++) {
    for (let p = 0; p < perim; p++) {
      const inPeriod = ((p + phase) % period + period) % period;
      const dashIdx = inPeriod < ANT_DASH_PX ? 0 : 1;
      if (dashIdx !== parity) continue;
      let px: number, py: number;
      if (p < w) {
        px = x + p;
        py = y;
      } else if (p < w + h) {
        px = x + w - 1;
        py = y + (p - w);
      } else if (p < 2 * w + h) {
        px = x + w - 1 - (p - w - h);
        py = y + h - 1;
      } else {
        px = x;
        py = y + h - 1 - (p - 2 * w - h);
      }
      g.rect(px, py, 1, 1);
    }
    g.fill({ color: parity === 0 ? 0xffffff : 0x000000, alpha: 0.95 });
  }
}

/** Paint a marching-ants marquee rectangle. Single entry point for
 *  every selection rubber-band in the app (Stage, Timeline, …) so
 *  the visual treatment and animation cadence stay locked together.
 *  Computes the phase from `performance.now()` so callers only need
 *  to repaint on their own ticker — they don't track phase. Skips
 *  zero-area rects so callers can pass raw drag deltas without
 *  guarding. */
export function paintMarchingAntsBand(
  g: Graphics,
  x: number,
  y: number,
  w: number,
  h: number,
): void {
  if (w <= 0 || h <= 0) return;
  const phase = Math.floor(performance.now() / ANT_MS);
  paintAntsRect(g, x, y, w, h, phase);
}
