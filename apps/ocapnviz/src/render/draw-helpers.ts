/**
 * Pixi draw helpers — pure functions that paint specific geometry
 * into a `Graphics`. Split from `Stage.tsx` so the giant scene-
 * orchestration file doesn't carry low-level drawing code.
 *
 * Two families live here:
 *   1. Session-curve strokes (`strokeCurve`, `strokeDashedCurve`,
 *      `positionEdgeLabel`) — Bezier-aware versions of the dashed
 *      / solid edge primitives. PixiJS has no curved-dash
 *      primitive, so `strokeDashedCurve` samples the curve into a
 *      polyline and walks dashes across the segments.
 *   2. Two-click tool overlay (`drawMarchingLine`, `drawArmedRing`)
 *      — node-editor-style wire preview and armed-peer ring with
 *      marching-ants motion driven by a per-frame offset.
 *
 * Plus the small shared `layoutPillBackground` for label pills.
 */

import type { Graphics, StrokeStyle, Text } from "pixi.js";
import {
  bezierAt,
  bezierTangent,
  SESSION_BUNDLE_SPACING,
  type SessionCurve,
} from "../engine/session-geometry.ts";
import type { ThemedColors } from "./palette.ts";
import type { LabelPill } from "./stage-labels.ts";
import type { HaloTier, PeerActivity } from "./types.ts";

// ─────────────────────── session edge strokes ───────────────────────

const EDGE_LABEL_OFFSET = 14;

/**
 * How far apart two neighbouring lanes' chips sit ALONG the corridor they
 * share, in world units.
 *
 * How big a chip is comes from `EDGE_CHIP_LABEL` in `stage-labels.ts`, which
 * is also what the renderer sets the type at: a `codec · captp` chip runs a
 * little over a hundred units wide and under twenty tall. The lanes it rides
 * are `SESSION_BUNDLE_SPACING` apart ACROSS the corridor. Thirty of separation
 * clears the height but not the width, so a bundle running roughly up the
 * screen — where across the corridor means across the page — stacked its chips
 * on top of one another. Walking each chip along the corridor puts the
 * separation on the axis that has room for it.
 *
 * More than a chip's own width, because the two separations are at right
 * angles and partly cancel on the page: at a shallow corridor angle the thirty
 * across and the walk along resolve into one nearly horizontal offset, and the
 * vertical part of it can fall under a chip's height. The pair is clear at
 * every angle once the resolved offset passes a chip's diagonal, and a hundred
 * and fifty is comfortably past it. The number is tuned rather than derived;
 * what holds it is `draw-helpers.test.ts`, which measures a real pair of chips
 * built from `EDGE_CHIP_LABEL` at every corridor angle, so growing the type
 * turns that test red rather than quietly overlapping.
 *
 * At 100% zoom. A chip is counter-scaled and a stride is not, so zooming out
 * grows the chip against a fixed stagger; `stage-labels.ts` says why one solve
 * cannot answer that.
 *
 * Two lanes clear at every angle on any corridor with room for two chips.
 * Three usually do. More than three cannot: four chips that wide want more of
 * a typical edge than it has, and no arrangement along one line fits them.
 * They still land in four places rather than on one, which is what the creep
 * below is for.
 */
const EDGE_LABEL_LANE_STRIDE = 150;
/** How far out of the middle of its own edge a chip will walk before the
 *  walk starts creeping instead of striding, as a share of the edge. */
const EDGE_LABEL_REACH_FRACTION = 0.4;
/** What is left of the stride past that point. Not zero: a chip that simply
 *  stopped would land on the one that stopped before it, and two chips on one
 *  point read as one chip, which is the thing being fixed. */
const EDGE_LABEL_REACH_CREEP = 0.15;

/**
 * A session line's tip is round.
 *
 * Where a line meets a peer, the node body covers its end and the tip is not
 * visible either way. Where it meets a session end nobody has attributed, the
 * body is see-through, so the tip shows through it — and a flat one reads as a
 * line that was cut rather than one that arrives.
 *
 * The halo behind a selected line is stroked by the same helper, which is why
 * this belongs to the helper rather than to the line's own call: a wide flat
 * halo tip behind a round line tip would show as a square shadow around it.
 */
const ROUND_TIP = "round" as const;

/** The part of a `Graphics` the two session-line helpers use.
 *
 * Same reason as {@link MarchCanvas}: naming the four methods lets a recorder
 * stand in for a `Graphics` this suite cannot construct, so which pieces of a
 * dashed line are stroked round is ordinary testable bookkeeping. */
export interface CurveCanvas {
  moveTo(x: number, y: number): unknown;
  lineTo(x: number, y: number): unknown;
  quadraticCurveTo(cx: number, cy: number, x: number, y: number): unknown;
  stroke(style: StrokeStyle): unknown;
}

/** Stroke a Bezier curve as one continuous path. Degenerate curves
 * (control = midpoint, e.g. singleton bundles) fall back to a
 * straight line — Pixi's quadratic primitive handles that fine but
 * a moveTo+lineTo is one less segment to process. */
export function strokeCurve(
  g: CurveCanvas,
  curve: SessionCurve,
  style: { color: number; width: number; alpha: number },
): void {
  g.moveTo(curve.ax, curve.ay);
  g.quadraticCurveTo(curve.cx, curve.cy, curve.bx, curve.by);
  g.stroke({
    color: style.color,
    width: style.width,
    alpha: style.alpha,
    cap: ROUND_TIP,
  });
}

/** Dashed stroke along a Bezier — Pixi has no curved-dash primitive,
 * so we sample the curve into a polyline and walk dashes across the
 * segments. Sample count is fixed at 24 (gives ~5 dashes for our
 * dash period at typical edge lengths).
 *
 * Each dash is ONE sub-path, however many sample boundaries it crosses. A dash
 * has to follow the curve, so a long one is several segments, and opening a
 * sub-path per segment put a line cap at every internal joint — invisible while
 * the caps were flat, and a row of beads the moment a tip is round.
 *
 * Only the line's own two tips are round. Dashed against solid is what the legend
 * reads as the codec, and rounding every dash would round the line into a bead
 * chain, so the first and last dash are stroked in a second pass.
 */
export function strokeDashedCurve(
  g: CurveCanvas,
  curve: SessionCurve,
  pattern: readonly [number, number],
  style: { color: number; width: number; alpha: number },
): void {
  const samples = 24;
  // Walk in cumulative arc length so the dash phase is uniform
  // (uniform-t sampling would bunch dashes near the apex on
  // strongly curved arcs).
  /** Each dash as a flat run of points, `[x, y, x, y, …]`. */
  const dashes: number[][] = [];
  let dash: number[] | null = null;
  let dashLen = 0;
  let lastX = curve.ax;
  let lastY = curve.ay;
  let on = true;
  let remaining = pattern[0];
  const closeDash = () => {
    if (dash !== null && dash.length >= 4) dashes.push(dash);
    dash = null;
    dashLen = 0;
  };
  for (let i = 1; i <= samples; i++) {
    const t = i / samples;
    const p = bezierAt(curve, t);
    const segDx = p.x - lastX;
    const segDy = p.y - lastY;
    let segLen = Math.hypot(segDx, segDy);
    if (segLen === 0) continue;
    const sx = segDx / segLen;
    const sy = segDy / segLen;
    while (segLen > 0) {
      const take = Math.min(segLen, remaining);
      const nextX = lastX + sx * take;
      const nextY = lastY + sy * take;
      if (on) {
        if (dash === null) dash = [lastX, lastY];
        dash.push(nextX, nextY);
        dashLen += take;
      }
      lastX = nextX;
      lastY = nextY;
      segLen -= take;
      remaining -= take;
      if (remaining <= 0) {
        if (on) closeDash();
        on = !on;
        remaining = on ? pattern[0] : pattern[1];
      }
    }
  }
  // A dash the curve cut short. Shorter than the line is wide, a round tip on it
  // is a dot rather than the end of a line, so the line ends at the dash before
  // it — which is where a reader would say it ends anyway.
  if (dash !== null && dashLen < style.width && dashes.length > 0) {
    dash = null;
  }
  closeDash();
  if (dashes.length === 0) return;
  const trace = (points: number[]) => {
    g.moveTo(points[0]!, points[1]!);
    for (let i = 2; i < points.length; i += 2) {
      g.lineTo(points[i]!, points[i + 1]!);
    }
  };
  // The middle, flat. Nothing to stroke when the line is one or two dashes, which
  // are both tips.
  if (dashes.length > 2) {
    for (let i = 1; i < dashes.length - 1; i++) trace(dashes[i]!);
    g.stroke({ color: style.color, width: style.width, alpha: style.alpha });
  }
  // The tips, round.
  trace(dashes[0]!);
  if (dashes.length > 1) trace(dashes[dashes.length - 1]!);
  g.stroke({
    color: style.color,
    width: style.width,
    alpha: style.alpha,
    cap: ROUND_TIP,
  });
}

/** The part of a `Container` the edge label uses.
 *
 * Same reason as {@link MarchCanvas}: naming the one method lets the geometry
 * be tested without a Pixi scene, and a real `Container` still satisfies it
 * structurally. */
export interface Positionable {
  position: { set(x: number, y: number): unknown };
}

/**
 * Edge-label position — the apex of the Bezier, offset outward along the local
 * perpendicular so the label sits clear of the stroke, and walked along the
 * corridor by however far out of the middle of its bundle this lane rides.
 * Never rotates; tilted labels are harder to read than tilted lines.
 *
 * Which lane this is comes from the curve's own bow rather than from a bundle
 * index handed in, because the bow already carries it: `curveBetween` displaces
 * the control point by twice `bundleOffset`, so the distance from the chord's
 * midpoint to the control point IS the lane's offset, doubled, and the
 * direction of that displacement is which side of the chord the lane rides.
 * Turning that direction a quarter turn gives an along-the-corridor direction
 * that does not depend on which end of the session was listed first, so two
 * lanes of one bundle walk opposite ways and separate rather than colliding.
 *
 * A trimmed edge — the prefix of a lane, drawn to a claim — bows a little less
 * than the lane it was cut from, so the lane it reads back is an estimate. It
 * is still ordered and signed the same way, which is all the stagger needs: the
 * chips have to end up in different places, not in exactly computed ones.
 *
 * A lone session is a straight curve whose control point sits on the chord
 * midpoint, so it reads back no lane and keeps the plain apex it always had.
 */
export function positionEdgeLabel(
  label: Positionable,
  curve: SessionCurve,
): void {
  const apex = bezierAt(curve, 0.5);
  const tan = bezierTangent(curve, 0.5);
  // Perpendicular to tangent; flip so y points up. The label sits
  // outside the curve's bulge so it doesn't crowd the stroke.
  let px = -tan.dy;
  let py = tan.dx;
  if (py > 0) {
    px = -px;
    py = -py;
  }
  const bowX = curve.cx - (curve.ax + curve.bx) / 2;
  const bowY = curve.cy - (curve.ay + curve.by) / 2;
  const bow = Math.hypot(bowX, bowY);
  let alongX = 0;
  let alongY = 0;
  if (bow > 0) {
    const lane = bow / (2 * SESSION_BUNDLE_SPACING);
    const chord = Math.hypot(curve.bx - curve.ax, curve.by - curve.ay);
    const want = lane * EDGE_LABEL_LANE_STRIDE;
    const reach = chord * EDGE_LABEL_REACH_FRACTION;
    const walk = want <= reach
      ? want
      : reach + (want - reach) * EDGE_LABEL_REACH_CREEP;
    alongX = (-bowY / bow) * walk;
    alongY = (bowX / bow) * walk;
  }
  label.position.set(
    apex.x + px * EDGE_LABEL_OFFSET + alongX,
    apex.y + py * EDGE_LABEL_OFFSET + alongY,
  );
}

// ─────────────────────── two-click overlay ───────────────────────

// Marching-ants visuals for two-click tools. Dash and gap are big
// enough to read as "in motion" rather than "stippled noise", and
// the ring and the wire share a period so the two animations look
// like one system.
//
// Every number here is a screen pixel, at every zoom. These
// graphics say something about the tool ("you picked Alice; pick a
// second peer"), not about the world, so they are anchored in world
// coordinates and measured in screen ones — the same split the
// peer labels already make with `counterScale`. Each helper
// therefore takes the viewport `scale` and divides, because it
// paints into a container the viewport is about to multiply.
const MARCH_DASH_PX = 6;
const MARCH_GAP_PX = 4;
const MARCH_WIRE_WIDTH = 2;
const MARCH_RING_WIDTH = 2;
/** How far outside the FOCUS ring the armed ring sits, in screen pixels.
 *
 *  Measured from that ring rather than from the body, so the two rings a node can
 *  wear hold one screen distance apart at every zoom and read as one vocabulary.
 *  It used to be measured from the body's half-width with a gap of six, which
 *  came apart in both directions: a square peer's corners reach further than its
 *  half-width, so the ring cut through them at any zoom past 0.5, and six screen
 *  pixels is six hundred world units at 1% zoom, so it ballooned to five times
 *  the body's width as the view pulled back. `haloRadius` owns the shape a ring
 *  hugs; this is the one number that says which of the two rings is outside. */
const MARCH_RING_GAP_PX = 3;
/** Fewest dashes in a ring, so a peer at a very low zoom still
 * reads as marching rather than as two ticks and a gap. */
const MARCH_RING_MIN_DASHES = 8;

/** The part of a `Graphics` these helpers actually use.
 *
 * Naming the narrow surface, rather than taking `Graphics` whole,
 * is what lets the dash geometry be tested without a WebGL context:
 * a recorder implementing these five methods is a valid argument,
 * and a real `Graphics` still satisfies it structurally. */
export interface MarchCanvas {
  clear(): unknown;
  moveTo(x: number, y: number): unknown;
  lineTo(x: number, y: number): unknown;
  arc(
    cx: number,
    cy: number,
    radius: number,
    start: number,
    end: number,
  ): unknown;
  stroke(style: StrokeStyle): unknown;
}

/** Wire-preview line — straight dashed line from `(x0, y0)` to
 * `(x1, y1)`, with the dash pattern shifted by `offsetPx` so the
 * dashes appear to march toward the cursor. Node-editor convention
 * (Blender, Unreal Blueprint, Houdini, …). */
export function drawMarchingLine(
  g: MarchCanvas,
  x0: number,
  y0: number,
  x1: number,
  y1: number,
  offsetPx: number,
  color: number,
  scale: number,
): void {
  g.clear();
  const dx = x1 - x0;
  const dy = y1 - y0;
  const length = Math.hypot(dx, dy);
  if (length === 0) return;
  const ux = dx / length;
  const uy = dy / length;
  // Screen pixels, expressed in the world units this paints into.
  const dash = MARCH_DASH_PX / scale;
  const period = (MARCH_DASH_PX + MARCH_GAP_PX) / scale;
  // Phase advances each frame so dashes shift toward (x1, y1) —
  // i.e. toward the cursor / the peer you're about to click. The
  // first iteration's dash starts in negative territory so a new
  // dash slides in from behind the source as the previous one
  // moves out, keeping the line continuous off the armed peer.
  const walked = offsetPx / scale;
  const phase = ((walked % period) + period) % period;
  let dist = phase - period;
  while (dist < length) {
    const a = Math.max(0, dist);
    const b = Math.min(length, dist + dash);
    if (b > a) {
      g.moveTo(x0 + ux * a, y0 + uy * a);
      g.lineTo(x0 + ux * b, y0 + uy * b);
    }
    dist += period;
  }
  g.stroke({
    color,
    width: MARCH_WIRE_WIDTH / scale,
    cap: "round",
    alpha: 0.85,
  });
}

/** Armed-peer ring — short arcs around a circle just outside
 * `containedRadius`, the whole ring rotated by an angle derived
 * from `offsetPx` so the dashes march around the circumference.
 *
 * `containedRadius` is the world half-width of the thing being
 * ringed. The ring sits outside the focus ring that same body would
 * wear (`haloRadius`), by a screen-pixel gap, so the two rings hold
 * one visual distance apart however far the view is zoomed and a
 * node that is both armed and selected reads as one thing. Arming a
 * node selects it, so that is the ordinary case rather than the
 * exception. Dash and gap are screen pixels too, so the dash *count*
 * follows the circumference rather than being fixed: that is what
 * keeps the marching period identical to `drawMarchingLine`'s at
 * every zoom, which is the whole reason the two read as one
 * animation. */
export function drawArmedRing(
  g: MarchCanvas,
  cx: number,
  cy: number,
  containedRadius: number,
  offsetPx: number,
  color: number,
  scale: number,
): void {
  g.clear();
  const radius = haloRadius(containedRadius, scale) +
    MARCH_RING_GAP_PX / scale;
  const circumferencePx = 2 * Math.PI * radius * scale;
  const period = MARCH_DASH_PX + MARCH_GAP_PX;
  const dashes = Math.max(
    MARCH_RING_MIN_DASHES,
    Math.round(circumferencePx / period),
  );
  const step = (Math.PI * 2) / dashes;
  const arcAngle = step * (MARCH_DASH_PX / period);
  // Radians that advance at a constant screen-pixel rate, so the
  // ring marches at the wire's speed rather than at a speed the
  // zoom decides.
  const phase = offsetPx / (radius * scale);
  for (let i = 0; i < dashes; i++) {
    const start = i * step + phase;
    // One sub-path per dash. Consecutive `arc()` calls append to a
    // single open polyline — `ShapePath._ensurePoly` returns early
    // while one is live — so without this `moveTo` every gap is
    // rendered as a straight chord across it, and the ring reads as
    // a faceted polygon instead of a dashed circle.
    g.moveTo(cx + Math.cos(start) * radius, cy + Math.sin(start) * radius);
    g.arc(cx, cy, radius, start, start + arcAngle);
  }
  g.stroke({
    color,
    width: MARCH_RING_WIDTH / scale,
    cap: "round",
    alpha: 0.9,
  });
}

// ─────────────────────── node outlines ───────────────────────

/** The part of a `Graphics` the dashed node outline uses.
 *
 * Same reason as {@link MarchCanvas}: naming the four methods lets a recorder
 * stand in for a `Graphics` this suite cannot construct, and the path
 * arithmetic becomes ordinary testable arithmetic. */
export interface RectCanvas {
  moveTo(x: number, y: number): unknown;
  lineTo(x: number, y: number): unknown;
  arcTo(
    x1: number,
    y1: number,
    x2: number,
    y2: number,
    radius: number,
  ): unknown;
  stroke(style: StrokeStyle): unknown;
}

/** Half-width of a node's body, in world units, so a node is 60 across.
 *
 * It lives here rather than beside the projection because it is the number
 * every node outline is measured against, and because a module that pulls in
 * no rendering context can be read by the arithmetic that has to agree with
 * it. Every peer is drawn at exactly this; a session end may not be, which is
 * what `looseEndStyle` decides. */
export const NODE_RADIUS = 30;

/** Corner rounding of a node's body, at full size. */
const NODE_CORNER = 5;

/** Dash length and gap of a node outline, in WORLD units.
 *
 * World rather than screen, unlike the marching overlays above, because this
 * is the node's own body rather than chrome about it: it stands in the place
 * a peer's solid outline would occupy, and the two have to keep the same
 * weight at every zoom or the placeholder would stop reading as the same
 * kind of shape. */
const NODE_DASH = 6;
const NODE_GAP = 4;

/** Stroke a rounded square centered on the origin as a dashed line.
 *
 * Pixi's stroke has no dash pattern, so the path is walked and drawn one
 * segment at a time. Only the four straight runs are dashed; the corner arcs
 * are drawn whole, which keeps the corners crisp at any zoom and costs four
 * short solid pieces the eye reads as part of the pattern.
 *
 * This is how the stage says "a place a peer will attach": a session end
 * nobody has attributed occupies a node's footprint without claiming to be
 * one. */
export function strokeDashedRoundRect(
  g: RectCanvas,
  radius: number,
  corner: number,
  stroke: StrokeStyle,
): void {
  const run = radius * 2 - corner * 2;
  // Each side runs corner-to-corner; `along` walks it in dash+gap
  // steps, and the last dash is clipped rather than overshooting.
  const side = (
    x0: number,
    y0: number,
    dx: number,
    dy: number,
  ): void => {
    for (let along = 0; along < run; along += NODE_DASH + NODE_GAP) {
      const end = Math.min(along + NODE_DASH, run);
      g.moveTo(x0 + dx * along, y0 + dy * along);
      g.lineTo(x0 + dx * end, y0 + dy * end);
    }
  };
  const r = radius;
  side(-r + corner, -r, 1, 0); // top, left to right
  side(r, -r + corner, 0, 1); // right, top to bottom
  side(r - corner, r, -1, 0); // bottom, right to left
  side(-r, r - corner, 0, -1); // left, bottom to top
  // The four corner arcs, whole. Each opens its own sub-path, or Pixi
  // appends it to the last dash and renders a chord across the gap.
  g.moveTo(-r + corner, -r);
  g.arcTo(-r, -r, -r, -r + corner, corner);
  g.moveTo(r, -r + corner);
  g.arcTo(r, -r, r - corner, -r, corner);
  g.moveTo(r - corner, r);
  g.arcTo(r, r, r, r - corner, corner);
  g.moveTo(-r, r - corner);
  g.arcTo(-r, r, -r + corner, r, corner);
  g.stroke(stroke);
}

/** The part of a `Graphics` a node's focus ring uses. */
export interface HaloCanvas {
  clear(): unknown;
  circle(cx: number, cy: number, radius: number): unknown;
  stroke(style: StrokeStyle): unknown;
}

// ───────────────── selection marks, in screen pixels ─────────────────
//
// A mark that says an entity is selected is saying something about the reader's
// own state ("this is the thing you picked"), not about the world, so it is
// anchored in world coordinates and measured in screen ones — the same split
// the marching-ants helpers make above, and for the same reason. Selection
// matters most when zoomed out, because that is where a reader is picking one
// thing out of a crowd, and a mark that shrinks with the thing it marks is
// faintest exactly there.
//
// The body a mark rings is a world thing and still scales with the camera. Only
// the mark's own geometry is compensated: the gap it holds off that body, its
// stroke weights, and how far a second ring sits inside the first.
const HALO_GAP_PX = 1;
const HALO_WIDTH_PX = 2.5;
const HALO_INNER_GAP_PX = 4;
const HALO_INNER_WIDTH_PX = 1;
const HALO_HOVER_INSET_PX = 2;
const HALO_HOVER_WIDTH_PX = 1.5;

/** How far out the focus ring around a body of half-width `containedRadius`
 *  sits: just past the square's diagonal corners, plus a screen-pixel gap at
 *  the given camera `scale`.
 *
 *  Exported rather than kept private because `CLAIM_LEAN` argues its daylight
 *  in terms of a claim's ring and a peer's ring not meeting, and
 *  `claim-placement.test.ts` measures that argument against this function. No
 *  placement code calls it: the lean is a fraction chosen once against the
 *  rings, not arithmetic the solver redoes. A second spelling of the radius
 *  would make that argument a claim about a different circle.
 *
 *  `scale` is required rather than defaulted, because that argument holds at one
 *  camera scale and the caller is the only one who knows which. Pass 1 to ask
 *  what the ring measures at 100% zoom, which is where the lean was chosen: the
 *  rings hold their screen size as the view zooms out while the bodies shrink,
 *  so two rings drawn with daylight between them at 100% do close on each other
 *  further out. That is the trade the constant screen size buys, and it is the
 *  same trade `drawArmedRing` already makes. */
export function haloRadius(containedRadius: number, scale: number): number {
  return containedRadius * Math.SQRT2 + HALO_GAP_PX / scale;
}

/**
 * The focus ring around a node, in whichever tier applies.
 *
 * A circle rather than the node's own rounded square, so the focus state
 * differs in shape and not merely in stroke weight, and sized to pass just
 * outside the square's diagonal corners. Hover hides once the node is
 * selected; the anchor adds a second inner ring.
 *
 * It takes the radius of the body it rings, because the two node kinds are not
 * the same size: a claim is half a peer's width and its ring has to hug it.
 * That is also why this lives here rather than being written once per sprite —
 * selecting an end and selecting a peer are meant to look like one act, and a
 * sameness held by copy-paste is a sameness that drifts.
 *
 * `scale` is the camera's, and every part of the ring that is not the body's own
 * size is divided by it, so the mark holds one screen size at any zoom.
 */
export function drawNodeHalo(
  g: HaloCanvas,
  containedRadius: number,
  tier: HaloTier,
  hovered: boolean,
  accent: number,
  scale: number,
): void {
  g.clear();
  const radius = haloRadius(containedRadius, scale);
  if (tier !== "none") {
    g.circle(0, 0, radius);
    g.stroke({ color: accent, width: HALO_WIDTH_PX / scale, alpha: 0.95 });
    if (tier === "anchor") {
      g.circle(0, 0, radius - HALO_INNER_GAP_PX / scale);
      g.stroke({
        color: accent,
        width: HALO_INNER_WIDTH_PX / scale,
        alpha: 0.85,
      });
    }
    return;
  }
  if (hovered) {
    g.circle(0, 0, radius - HALO_HOVER_INSET_PX / scale);
    g.stroke({
      color: accent,
      width: HALO_HOVER_WIDTH_PX / scale,
      alpha: 0.45,
    });
  }
}

/** The part of a `Graphics` the activity mark uses: a filled ring, and the
 *  arcs the split `both` dot is built from. */
export interface ActivityCanvas {
  circle(cx: number, cy: number, radius: number): unknown;
  moveTo(x: number, y: number): unknown;
  arc(
    cx: number,
    cy: number,
    radius: number,
    start: number,
    end: number,
  ): unknown;
  closePath(): unknown;
  fill(style: { color: number }): unknown;
}

/** Where the mark sits relative to the body's own corner, and how big it is.
 *  One set of numbers, because it is one mark. */
const ACTIVITY_INSET = 2;
const ACTIVITY_RING_RADIUS = 5;
const ACTIVITY_RADIUS = 3.5;

/**
 * The corner mark that says bytes are moving through this node, for a body of
 * the given half-width. The outer ring is drawn in the node-stroke color so
 * the mark reads against whatever fill sits under it, and `both` splits the
 * dot in half, sending over receiving.
 *
 * Both node kinds paint it, and that is the point. Who a node is and whether
 * traffic is flowing through it are two separate questions, and an
 * unattributed end has only the first one open. Drawing the mark on peers
 * alone would render the missing answer to "who" as an absence of traffic, at
 * exactly the node where a reader most wants to see it: that traffic is the
 * evidence that will eventually name the end.
 *
 * Like `drawNodeHalo`, it takes the radius of the body it marks, so a claim's
 * mark rides its own half-sized corner. The mark itself stays the same size on
 * both, though: its size measures nothing, and one fact drawn smaller would
 * read as a lesser fact.
 */
export function drawNodeActivity(
  g: ActivityCanvas,
  containedRadius: number,
  activity: PeerActivity,
  colors: ThemedColors,
): void {
  if (activity === "idle") return;
  const cx = containedRadius - ACTIVITY_INSET;
  const cy = -containedRadius + ACTIVITY_INSET;
  g.circle(cx, cy, ACTIVITY_RING_RADIUS);
  g.fill({ color: colors.peerStroke });
  const r = ACTIVITY_RADIUS;
  if (activity !== "both") {
    g.circle(cx, cy, r);
    g.fill({
      color: activity === "sending" ? colors.messageInFlight : colors.positive,
    });
    return;
  }
  // Two half-discs sharing the ring's center: the upper one sending, the
  // lower receiving, so a node doing both says so without a third color.
  g.moveTo(cx - r, cy);
  g.arc(cx, cy, r, Math.PI, 0);
  g.closePath();
  g.fill({ color: colors.messageInFlight });
  g.moveTo(cx + r, cy);
  g.arc(cx, cy, r, 0, Math.PI);
  g.closePath();
  g.fill({ color: colors.positive });
}

/** The part of a `Graphics` an unattributed end's body uses — the dashed
 *  outline's four methods plus the two the faint fill needs. */
export interface NodeBodyCanvas extends RectCanvas {
  roundRect(
    x: number,
    y: number,
    width: number,
    height: number,
    radius: number,
  ): unknown;
  fill(style: { color: number; alpha: number }): unknown;
}

/** How an unattributed end's body is drawn. The two readings differ only in
 *  size and weight, because they are the same thing in two relationships. */
export type LooseEndStyle = {
  radius: number;
  corner: number;
  fillAlpha: number;
  strokeAlpha: number;
  strokeWidth: number;
};

/** An end standing on its own: a peer's full footprint, because that is what
 *  it is holding — a place a peer will attach. */
export const LOOSE_END_ALONE: LooseEndStyle = {
  radius: NODE_RADIUS,
  corner: NODE_CORNER,
  fillAlpha: 0.22,
  strokeAlpha: 0.9,
  strokeWidth: 2,
};

/** An end whose claim names a peer this stage draws.
 *
 * The layout sits it on its own session's edge, partway to that peer, so this
 * shape stands in open space a node's width or so short of a peer that is
 * twice its size. Every number here says the same thing: it is less than a
 * peer. Half the width so the pair reads as somebody and a claim
 * about them rather than as two peers arguing; a lighter outline and a fainter
 * fill so the eye settles on the peer and takes the claim as the thing
 * attached to it.
 *
 * Half rather than three quarters because at three quarters the two squares
 * are near enough in size to read as siblings, and the picture would be
 * saying the claim is a peer's equal, which is the one thing it is not. */
export const LOOSE_END_CLAIMING: LooseEndStyle = {
  radius: NODE_RADIUS * 0.5,
  corner: NODE_CORNER * 0.5,
  fillAlpha: 0.18,
  strokeAlpha: 0.7,
  strokeWidth: 1.5,
};

/** Which of the two readings an end takes: `claiming` is true when its claim
 *  names a peer the stage draws, which is the one question that separates
 *  them. The selector lives here, beside the two it chooses between, because
 *  the drawing is not its only reader — a hit test has to measure the body
 *  that was actually painted. */
export function looseEndStyle(claiming: boolean): LooseEndStyle {
  return claiming ? LOOSE_END_CLAIMING : LOOSE_END_ALONE;
}

/** Paint one unattributed end's body: a faint fill under a dashed outline,
 *  both centered on the origin, in whichever of the two readings applies.
 *
 *  The fill is translucent on purpose and nothing opaque is painted under it,
 *  so a session's line shows through the body it reaches. Both halves of that
 *  were decided rather than overlooked: the see-through body is what makes an
 *  end read as provisional next to a solid peer, and a wire running to the
 *  center of it is accepted rather than stopped at the edge. A backdrop behind
 *  the fill, or a shortened wire, would each undo one of them. */
export function drawLooseEndBody(
  g: NodeBodyCanvas,
  style: LooseEndStyle,
  fillColor: number,
  strokeColor: number,
): void {
  g.roundRect(
    -style.radius,
    -style.radius,
    style.radius * 2,
    style.radius * 2,
    style.corner,
  );
  g.fill({ color: fillColor, alpha: style.fillAlpha });
  strokeDashedRoundRect(g, style.radius, style.corner, {
    color: strokeColor,
    width: style.strokeWidth,
    alpha: style.strokeAlpha,
  });
}

// ─────────────────────── label backgrounds ───────────────────────

/** Rounded-rect pill behind a Text, sized to its measured bounds plus the
 * padding its `LabelPill` carries. Used by peer labels, session-end labels,
 * edge chips and message previews for a soft chip background against the
 * canvas.
 *
 * It takes the whole pill rather than two numbers because the padding is also
 * what the layout reserves room for, and a call site free to pass its own two
 * numbers is a call site that can disagree with the solver. */
export function layoutPillBackground(
  bg: Graphics,
  text: Text,
  colors: ThemedColors,
  pill: LabelPill,
): void {
  const w = text.width + pill.padX * 2;
  const h = text.height + pill.padY * 2;
  bg.clear()
    .roundRect(-w / 2, -h / 2, w, h, 3)
    .fill({ color: colors.labelBg, alpha: colors.labelBgAlpha })
    .stroke({
      color: colors.labelBorder,
      width: 0.5,
      alpha: colors.labelBorderAlpha,
    });
}
