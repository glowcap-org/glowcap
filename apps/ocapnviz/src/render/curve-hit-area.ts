/**
 * Pointer hit-test and cull bounds for a session Bezier without a
 * stroked Graphics.
 *
 * The wire's pixels live in the shared edge stroke batch; per-edge
 * picking still needs a footprint, and `cullable` hit proxies need a
 * `boundsArea` — an empty halo Graphics reports origin bounds, which
 * would cull on-screen wires when the camera is elsewhere. Sampling
 * matches {@link CURVE_STROKE_SAMPLES} so the corridor follows the same
 * polyline the dashed stroke walks. The corridor is continuous even
 * for dashed ink — gaps are a codec reading, not a thinner target.
 */

import { Rectangle } from "pixi.js";
import { bezierAt, type SessionCurve } from "../engine/session-geometry.ts";
import { CURVE_STROKE_SAMPLES } from "./draw-helpers.ts";

export type CurveHitArea = {
  contains(x: number, y: number): boolean;
};

/** Hit area around `curve` with half-width `halfWidth` (world units). */
export function curveHitArea(
  curve: SessionCurve,
  halfWidth: number,
): CurveHitArea {
  const pts: number[] = [];
  for (let i = 0; i <= CURVE_STROKE_SAMPLES; i++) {
    const p = bezierAt(curve, i / CURVE_STROKE_SAMPLES);
    pts.push(p.x, p.y);
  }
  const thresh = halfWidth < 0 ? 0 : halfWidth;
  const thresh2 = thresh * thresh;
  return {
    contains(x: number, y: number): boolean {
      for (let i = 0; i + 3 < pts.length; i += 2) {
        if (
          dist2PointSegment(
            x,
            y,
            pts[i]!,
            pts[i + 1]!,
            pts[i + 2]!,
            pts[i + 3]!,
          ) <= thresh2
        ) {
          return true;
        }
      }
      return false;
    },
  };
}

/** Axis-aligned pad around the sampled curve for Pixi `boundsArea`. */
export function curveBoundsArea(
  curve: SessionCurve,
  pad: number,
): Rectangle {
  let minX = Number.POSITIVE_INFINITY;
  let minY = Number.POSITIVE_INFINITY;
  let maxX = Number.NEGATIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;
  for (let i = 0; i <= CURVE_STROKE_SAMPLES; i++) {
    const p = bezierAt(curve, i / CURVE_STROKE_SAMPLES);
    minX = Math.min(minX, p.x);
    minY = Math.min(minY, p.y);
    maxX = Math.max(maxX, p.x);
    maxY = Math.max(maxY, p.y);
  }
  const p = pad < 0 ? 0 : pad;
  return new Rectangle(
    minX - p,
    minY - p,
    Math.max(0, maxX - minX) + 2 * p,
    Math.max(0, maxY - minY) + 2 * p,
  );
}

function dist2PointSegment(
  px: number,
  py: number,
  ax: number,
  ay: number,
  bx: number,
  by: number,
): number {
  const abx = bx - ax;
  const aby = by - ay;
  const apx = px - ax;
  const apy = py - ay;
  const ab2 = abx * abx + aby * aby;
  if (ab2 === 0) return apx * apx + apy * apy;
  let t = (apx * abx + apy * aby) / ab2;
  if (t < 0) t = 0;
  else if (t > 1) t = 1;
  const cx = ax + abx * t - px;
  const cy = ay + aby * t - py;
  return cx * cx + cy * cy;
}
