/**
 * Marching-overlay geometry.
 *
 * These helpers paint into a `Graphics`, which needs a WebGL
 * context this suite has no way to make. They take a `MarchCanvas`
 * instead — the five methods they actually call — so a recorder can
 * stand in and the geometry itself becomes ordinary testable
 * arithmetic.
 *
 * Two properties, both of which the ring got wrong on screen:
 *
 *  1. Every arc opens its own sub-path. Pixi's `ShapePath` returns
 *     early from `_ensurePoly` while a polyline is live, so back-to-
 *     back `arc()` calls append to one polygon and each intended gap
 *     is rendered as a straight chord across it. The ring looked
 *     faceted rather than dashed.
 *  2. Screen-pixel quantities stay screen pixels at every zoom.
 *     Stroke width, dash length, and the ring's gap were world
 *     units painted into a container the viewport then multiplied,
 *     so they were only correct at 1:1.
 */
import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import type { HaloTier, PeerActivity } from "./types.ts";
import { themedColors } from "./palette.ts";
import { curveBetween, type SessionCurve } from "../engine/session-geometry.ts";
import { EDGE_CHIP_LABEL, pillSize } from "./stage-labels.ts";
import {
  type ActivityCanvas,
  type CurveCanvas,
  drawArmedRing,
  drawLooseEndBody,
  drawMarchingLine,
  drawNodeActivity,
  drawNodeHalo,
  type HaloCanvas,
  haloRadius,
  LOOSE_END_ALONE,
  LOOSE_END_CLAIMING,
  looseEndStyle,
  type MarchCanvas,
  NODE_RADIUS,
  type NodeBodyCanvas,
  positionEdgeLabel,
  type RectCanvas,
  strokeCurve,
  strokeDashedCurve,
  strokeDashedRoundRect,
} from "./draw-helpers.ts";

type Call =
  | { op: "clear" }
  | { op: "moveTo"; x: number; y: number }
  | { op: "lineTo"; x: number; y: number }
  | {
    op: "arc";
    cx: number;
    cy: number;
    radius: number;
    start: number;
    end: number;
  }
  | { op: "stroke"; width: number };

class Recorder implements MarchCanvas {
  readonly calls: Call[] = [];
  clear() {
    this.calls.push({ op: "clear" });
  }
  moveTo(x: number, y: number) {
    this.calls.push({ op: "moveTo", x, y });
  }
  lineTo(x: number, y: number) {
    this.calls.push({ op: "lineTo", x, y });
  }
  arc(cx: number, cy: number, radius: number, start: number, end: number) {
    this.calls.push({ op: "arc", cx, cy, radius, start, end });
  }
  stroke(style: { width: number }) {
    this.calls.push({ op: "stroke", width: style.width });
  }
  arcs(): Extract<Call, { op: "arc" }>[] {
    return this.calls.filter((c) => c.op === "arc");
  }
  arc_(i: number): Extract<Call, { op: "arc" }> {
    return at(this.arcs(), i, "arc");
  }
  moves(): Extract<Call, { op: "moveTo" }>[] {
    return this.calls.filter((c) => c.op === "moveTo");
  }
  move_(i: number): Extract<Call, { op: "moveTo" }> {
    return at(this.moves(), i, "moveTo");
  }
  lines(): Extract<Call, { op: "lineTo" }>[] {
    return this.calls.filter((c) => c.op === "lineTo");
  }
  line_(i: number): Extract<Call, { op: "lineTo" }> {
    return at(this.lines(), i, "lineTo");
  }
  strokeWidth(): number {
    const s = this.calls.find((c) => c.op === "stroke");
    assert(s, "expected a stroke");
    return s.width;
  }
}

function at<T>(xs: T[], i: number, what: string): T {
  const x = xs[i];
  assert(x !== undefined, `expected a ${what} at index ${i}, saw ${xs.length}`);
  return x;
}

/** Every dash is drawn at the same screen size whatever the zoom,
 * so a run at scale s is only comparable to a run at scale 1 after
 * dividing world lengths back out by s. */
const ZOOMS = [0.25, 1, 2, 4];

Deno.test("armed ring: every arc opens its own sub-path", () => {
  const g = new Recorder();
  drawArmedRing(g, 100, 50, 30, 0, 0xffffff, 1);

  const arcs = g.arcs();
  assert(arcs.length > 4, `expected several dashes, got ${arcs.length}`);

  for (let i = 0; i < g.calls.length; i++) {
    const c = at(g.calls, i, "call");
    if (c.op !== "arc") continue;
    assert(i > 0, "an arc is the very first call");
    const prev = at(g.calls, i - 1, "call");
    assert(
      prev.op === "moveTo",
      `arc at ${i} continues an open path instead of starting one; ` +
        `its gap will render as a chord`,
    );
    // ...and it opens at the arc's own start point, so the moveTo
    // is a real pen-up rather than a stray segment of its own.
    assertAlmostEquals(prev.x, c.cx + Math.cos(c.start) * c.radius, 1e-9);
    assertAlmostEquals(prev.y, c.cy + Math.sin(c.start) * c.radius, 1e-9);
  }
});

Deno.test("armed ring: stroke, gap, and dash are screen pixels at every zoom", () => {
  const contained = 30;
  for (const scale of ZOOMS) {
    const g = new Recorder();
    drawArmedRing(g, 0, 0, contained, 0, 0xffffff, scale);

    // Stroke: painted into a world container the viewport scales by
    // `scale`, so the world width must be the reciprocal.
    assertAlmostEquals(g.strokeWidth() * scale, 2, 1e-9, `stroke @${scale}`);

    // Gap: a constant screen distance outside the FOCUS ring the same body
    // wears, so the two rings a node can show at once hold their spacing at
    // every zoom. Measured from there rather than from the body's half-width:
    // a square body's corners reach a factor of root two further, so a gap
    // measured off the half-width put the ring through the corners at any zoom
    // past 0.5 while claiming to sit outside the body.
    const first = g.arc_(0);
    const focus = haloRadius(contained, scale);
    assertAlmostEquals(
      (first.radius - focus) * scale,
      3,
      1e-9,
      `gap @${scale}`,
    );
    assert(
      first.radius > contained * Math.SQRT2,
      `ring cuts the corners of the body it rings @${scale}`,
    );

    // Dash: arc length on screen. A closed ring must hold a whole
    // number of dashes, so the period is the circumference divided
    // by a rounded count, and the dash inherits that rounding. The
    // most it can cost is half a period spread over the count —
    // 6% at the eight-dash floor, under 1% by the time a ring is
    // big enough on screen to look round.
    const dashPx = (first.end - first.start) * first.radius * scale;
    assertAlmostEquals(dashPx, 6, 6 * 0.5 / g.arcs().length, `dash @${scale}`);
  }
});

Deno.test("armed ring: dash count follows the circumference, with a floor", () => {
  const counts = ZOOMS.map((scale) => {
    const g = new Recorder();
    drawArmedRing(g, 0, 0, 30, 0, 0xffffff, scale);
    return g.arcs().length;
  });

  // Zooming in shows more dashes of the same size, never the same
  // dashes stretched.
  for (let i = 1; i < counts.length; i++) {
    assert(
      at(counts, i, "count") > at(counts, i - 1, "count"),
      `dash count did not grow with zoom: ${counts.join(", ")}`,
    );
  }

  // A ring small enough on screen to round down to a couple of
  // dashes still reads as marching rather than as two ticks.
  const tiny = new Recorder();
  drawArmedRing(tiny, 0, 0, 30, 0, 0xffffff, 0.01);
  assert(
    tiny.arcs().length >= 8,
    `tiny ring collapsed to ${tiny.arcs().length} dashes`,
  );
});

Deno.test("armed ring: the march advances at a constant screen rate", () => {
  // One frame's worth of offset must rotate the ring by the same
  // number of screen pixels whatever the zoom, or the animation
  // speeds up as you zoom in.
  const contained = 30;
  const offsetPx = 3;
  for (const scale of ZOOMS) {
    const at0 = new Recorder();
    const at1 = new Recorder();
    drawArmedRing(at0, 0, 0, contained, 0, 0xffffff, scale);
    drawArmedRing(at1, 0, 0, contained, offsetPx, 0xffffff, scale);
    const r = at0.arc_(0).radius;
    const advancedPx = (at1.arc_(0).start - at0.arc_(0).start) * r * scale;
    assertAlmostEquals(advancedPx, offsetPx, 1e-9, `march @${scale}`);
  }
});

Deno.test("wire preview: dash, gap, and stroke are screen pixels at every zoom", () => {
  for (const scale of ZOOMS) {
    const g = new Recorder();
    // A long line so the walk produces plenty of whole dashes.
    drawMarchingLine(g, 0, 0, 400, 0, 0, 0xffffff, scale);

    assertAlmostEquals(g.strokeWidth() * scale, 2, 1e-9, `stroke @${scale}`);

    const moves = g.moves();
    assert(
      moves.length === g.lines().length && moves.length > 3,
      `dashes @${scale}`,
    );

    // Take an interior dash: the first and last are clipped by the
    // ends of the line.
    const i = 2;
    const dashPx = (g.line_(i).x - g.move_(i).x) * scale;
    assertAlmostEquals(dashPx, 6, 1e-9, `dash @${scale}`);
    const periodPx = (g.move_(i + 1).x - g.move_(i).x) * scale;
    assertAlmostEquals(periodPx, 10, 1e-9, `period @${scale}`);
  }
});

Deno.test("wire preview and armed ring march to the same period", () => {
  // They are drawn as one system; a viewer reads them together, so
  // a zoom that changed one and not the other would be visible.
  for (const scale of ZOOMS) {
    const line = new Recorder();
    drawMarchingLine(line, 0, 0, 400, 0, 0, 0xffffff, scale);
    const linePeriodPx = (line.move_(3).x - line.move_(2).x) * scale;

    const ring = new Recorder();
    drawArmedRing(ring, 0, 0, 30, 0, 0xffffff, scale);
    const ringPeriodPx = (ring.arc_(1).start - ring.arc_(0).start) *
      ring.arc_(0).radius * scale;

    // Same whole-dash rounding as above: the line can start a dash
    // anywhere, the ring has to come back to where it began.
    assertAlmostEquals(
      ringPeriodPx,
      linePeriodPx,
      linePeriodPx * 0.5 / ring.arcs().length,
      `period @${scale}`,
    );
  }
});

// ─────────────────────── dashed node outline ───────────────────────
//
// The outline that says "a place a peer will attach". Its two properties
// are the ones a reader judges it by: it has to close (a gap where a corner
// should be reads as a broken shape, not a dashed one), and its dashes have
// to be the same size all the way round, because a side that ran out of
// room mid-dash and stretched the last one would read as a different weight
// on that side.

type RectCall =
  | { op: "moveTo"; x: number; y: number }
  | { op: "lineTo"; x: number; y: number }
  | { op: "arcTo"; x1: number; y1: number; x2: number; y2: number; r: number }
  | { op: "stroke"; width: number };

class RectRecorder implements RectCanvas {
  readonly calls: RectCall[] = [];
  moveTo(x: number, y: number) {
    this.calls.push({ op: "moveTo", x, y });
  }
  lineTo(x: number, y: number) {
    this.calls.push({ op: "lineTo", x, y });
  }
  arcTo(x1: number, y1: number, x2: number, y2: number, r: number) {
    this.calls.push({ op: "arcTo", x1, y1, x2, y2, r });
  }
  stroke(style: { width: number }) {
    this.calls.push({ op: "stroke", width: style.width });
  }
  strokeWidthOf(): number {
    const s = this.calls.find((c) => c.op === "stroke");
    assert(s, "expected a stroke");
    return s.width;
  }
  /** The dashes, as (start, end) pairs — every `lineTo` and the `moveTo`
   *  that opened it. */
  dashes(): { x0: number; y0: number; x1: number; y1: number }[] {
    const out: { x0: number; y0: number; x1: number; y1: number }[] = [];
    for (let i = 1; i < this.calls.length; i++) {
      const c = at(this.calls, i, "call");
      const prev = at(this.calls, i - 1, "call");
      if (c.op !== "lineTo") continue;
      assert(prev.op === "moveTo", `dash at ${i} continues an open path`);
      out.push({ x0: prev.x, y0: prev.y, x1: c.x, y1: c.y });
    }
    return out;
  }
}

const STROKE = { color: 0xffffff, width: 2, alpha: 0.9 };

Deno.test("dashed node outline: every dash opens its own sub-path", () => {
  // Same hazard the armed ring has: consecutive segments appended to one
  // live polyline turn each intended gap into a drawn chord, and the
  // outline stops reading as dashed at all.
  const g = new RectRecorder();
  strokeDashedRoundRect(g, 30, 5, STROKE);
  assert(g.dashes().length > 8, `expected dashes, got ${g.dashes().length}`);
  for (let i = 1; i < g.calls.length; i++) {
    const c = at(g.calls, i, "call");
    if (c.op !== "arcTo") continue;
    assert(
      at(g.calls, i - 1, "call").op === "moveTo",
      `corner arc at ${i} continues an open path; its gap renders as a chord`,
    );
  }
});

Deno.test("dashed node outline: dashes never overrun the corners", () => {
  // Each side is walked corner to corner and the last dash is clipped
  // rather than allowed to overshoot, so no dash crosses into the arc that
  // is drawn whole. A dash past the corner would double-draw it at a
  // different angle, which reads as a bent, thickened corner. The radius is
  // chosen so the run is NOT a whole number of dash periods: at a size the
  // last dash happens to land inside, the clip never fires and the test
  // would pass without exercising it.
  const r = 32;
  const corner = 5;
  const g = new RectRecorder();
  strokeDashedRoundRect(g, r, corner, STROKE);
  for (const d of g.dashes()) {
    for (const [x, y] of [[d.x0, d.y0], [d.x1, d.y1]]) {
      assert(
        Math.abs(x!) <= r + 1e-9 && Math.abs(y!) <= r + 1e-9,
        `dash point (${x}, ${y}) outside the ${r}-radius square`,
      );
      // On a side, one coordinate is pinned to the edge and the other
      // stays inside the straight run between the two corner arcs.
      const onEdge = Math.abs(Math.abs(x!) - r) < 1e-9 ||
        Math.abs(Math.abs(y!) - r) < 1e-9;
      assert(onEdge, `dash point (${x}, ${y}) is not on an edge`);
      const along = Math.abs(Math.abs(x!) - r) < 1e-9 ? y! : x!;
      assert(
        Math.abs(along) <= r - corner + 1e-9,
        `dash point (${x}, ${y}) runs into a corner arc`,
      );
    }
  }
});

Deno.test("dashed node outline: all four sides carry the same cadence", () => {
  // A square has four equal runs, so a correct walk produces the same
  // number of dashes on each and the same length for every dash but the
  // clipped last one of a side. Different cadences per side would read as
  // different line weights on a shape the eye takes in at once.
  const g = new RectRecorder();
  // Same not-a-whole-number-of-periods radius as above, so the clipped last
  // dash of each side is present and its four copies have to agree too.
  strokeDashedRoundRect(g, 32, 5, STROKE);
  const lengths = g.dashes().map((d) => Math.hypot(d.x1 - d.x0, d.y1 - d.y0));
  assert(lengths.length % 4 === 0, `sides differ: ${lengths.length} dashes`);
  const perSide = lengths.length / 4;
  for (let i = 0; i < perSide; i++) {
    const first = at(lengths, i, "dash");
    for (let side = 1; side < 4; side++) {
      assertAlmostEquals(
        at(lengths, side * perSide + i, "dash"),
        first,
        1e-9,
        `dash ${i} on side ${side}`,
      );
    }
  }
  // Every dash is the full length except a side's last, which is clipped.
  for (let i = 0; i < perSide - 1; i++) {
    assertAlmostEquals(at(lengths, i, "dash"), 6, 1e-9, `dash ${i}`);
  }
});

Deno.test("dashed node outline: the outline scales with the node it draws", () => {
  // The placeholder stands where a peer's body would, so its outline is
  // world units like the peer's solid one: at twice the radius it has more
  // dashes of the same size, not the same dashes stretched.
  const small = new RectRecorder();
  const big = new RectRecorder();
  strokeDashedRoundRect(small, 30, 5, STROKE);
  strokeDashedRoundRect(big, 60, 5, STROKE);
  assert(
    big.dashes().length > small.dashes().length,
    `dash count did not grow with the node`,
  );
  assertAlmostEquals(small.strokeWidthOf(), big.strokeWidthOf(), 1e-9);
});

// ─────────────────── an unattributed end's body ───────────────────
//
// A loose end whose claim names a peer the stage already draws is sat on its
// own session's edge, two thirds of the way to that peer. That is a fact
// about position, decided in `keyframe-layout-system.ts`, and the drawing
// answers it: the pair has to read as somebody and a claim about them rather
// than as two peers. What can be checked without a canvas is the arithmetic
// of the two weights, and that the selector hands each reading its own. That
// a claim draws ABOVE every peer is a `zIndex` on a Pixi container, and
// nothing here can see it.

class BodyRecorder extends RectRecorder implements NodeBodyCanvas {
  readonly rects: { x: number; y: number; w: number; h: number }[] = [];
  readonly fills: { color: number; alpha: number }[] = [];
  roundRect(x: number, y: number, w: number, h: number, _radius: number) {
    this.rects.push({ x, y, w, h });
  }
  fill(style: { color: number; alpha: number }) {
    this.fills.push(style);
  }
  /** Half the width of the body actually painted. */
  half(): number {
    const r = at(this.rects, 0, "roundRect");
    assertAlmostEquals(r.w, r.h, 1e-9, "the body is not square");
    return r.w / 2;
  }
  fillAlpha(): number {
    return at(this.fills, 0, "fill").alpha;
  }
}

function drawn(style: typeof LOOSE_END_ALONE): BodyRecorder {
  const g = new BodyRecorder();
  drawLooseEndBody(g, style, 0x64748b, 0xffffff);
  return g;
}

Deno.test("an end standing alone occupies a peer's own footprint", () => {
  // It is holding a place a peer will attach to, so it is that place's size.
  const g = drawn(LOOSE_END_ALONE);
  assertAlmostEquals(g.half(), NODE_RADIUS, 1e-9);
  assert(g.dashes().length > 8, "the outline is not dashed");
});

Deno.test("a claim is drawn as the lesser of the two shapes", () => {
  // A claim sits a node's width or so from a peer twice its size, and it must
  // not read as a second peer standing there. It gives way in all three of the
  // dimensions a viewer judges at a glance, so the peer stays the shape the
  // eye settles on and the claim reads as the thing attached to it.
  const alone = drawn(LOOSE_END_ALONE);
  const claiming = drawn(LOOSE_END_CLAIMING);
  assert(claiming.half() < alone.half(), "a claim is not smaller");
  assert(
    claiming.fillAlpha() < alone.fillAlpha(),
    "a claim's fill is not fainter",
  );
  assert(
    claiming.strokeWidthOf() < alone.strokeWidthOf(),
    "a claim's outline is not lighter",
  );
});

Deno.test("a claim's outline still reads as dashed at half a node", () => {
  // The dash is a fixed length in world units, so halving the body does not
  // halve the dash — it halves how many fit. Three to a side is the floor
  // where a reader still sees a dashed square rather than a corner mark and a
  // smudge, and it is what stops the claim's outline from quietly becoming a
  // solid one as the shape shrinks.
  const g = drawn(LOOSE_END_CLAIMING);
  assert(
    g.dashes().length >= 12,
    `a claim's outline has ${g.dashes().length} dashes, under three a side`,
  );
});

// ─────────────────── the node focus ring ───────────────────

class HaloRecorder implements HaloCanvas {
  readonly rings: { radius: number; width: number; alpha: number }[] = [];
  #pending: number | null = null;
  clear() {
    this.rings.length = 0;
    this.#pending = null;
  }
  circle(_cx: number, _cy: number, radius: number) {
    this.#pending = radius;
  }
  stroke(style: { width?: number; alpha?: number }) {
    assert(this.#pending !== null, "a stroke with no circle under it");
    this.rings.push({
      radius: this.#pending,
      width: style.width ?? 0,
      alpha: style.alpha ?? 1,
    });
    this.#pending = null;
  }
}

function halo(
  radius: number,
  tier: HaloTier,
  hovered: boolean,
  scale = 1,
): HaloRecorder {
  const g = new HaloRecorder();
  drawNodeHalo(g, radius, tier, hovered, 0x3b82f6, scale);
  return g;
}

Deno.test("the focus ring hugs the body it rings, whatever its size", () => {
  // A claim is half a peer's width, so a ring sized off a peer would float
  // clear of the claim it is meant to point at. One helper, two radii, and
  // each ring sits just outside its own body's diagonal corners.
  for (const style of [LOOSE_END_ALONE, LOOSE_END_CLAIMING]) {
    const g = halo(style.radius, "selected", false);
    const ring = at(g.rings, 0, "ring");
    assert(
      ring.radius > style.radius * Math.SQRT2 &&
        ring.radius < style.radius * Math.SQRT2 + 4,
      `a ${style.radius} body got a ring of ${ring.radius}`,
    );
  }
});

Deno.test("the anchor ring is the selected ring plus one inside it", () => {
  // Under multi-select the reader has to see which of the selected things the
  // Inspector follows, and the answer must not be a different ring — it is the
  // same ring with a second one inside.
  const selected = halo(30, "selected", false);
  const anchor = halo(30, "anchor", false);
  assertEquals(selected.rings.length, 1);
  assertEquals(anchor.rings.length, 2);
  assertEquals(at(anchor.rings, 0, "ring"), at(selected.rings, 0, "ring"));
  assert(
    at(anchor.rings, 1, "ring").radius < at(anchor.rings, 0, "ring").radius,
    "the anchor's second ring is not inside the first",
  );
});

Deno.test("hover rings only while nothing is selected", () => {
  // Selection is the stronger statement, so a hover ring under it would be a
  // second, weaker answer to the same question.
  assertEquals(halo(30, "none", true).rings.length, 1);
  assertEquals(halo(30, "none", false).rings.length, 0);
  const hoveredAndSelected = halo(30, "selected", true);
  assertEquals(hoveredAndSelected.rings.length, 1);
  assertEquals(
    at(hoveredAndSelected.rings, 0, "ring"),
    at(halo(30, "selected", false).rings, 0, "ring"),
  );
});

Deno.test("the two readings are chosen in one place", () => {
  // The renderer paints the body and the marquee measures it, and a second
  // spelling of "which of the two is this" is two answers waiting to
  // disagree. Both ask here.
  assertEquals(looseEndStyle(true), LOOSE_END_CLAIMING);
  assertEquals(looseEndStyle(false), LOOSE_END_ALONE);
});

// ─────────────────── the activity mark ───────────────────

const COLORS = themedColors("light");

class ActivityRecorder implements ActivityCanvas {
  readonly discs: { cx: number; cy: number; radius: number; color: number }[] =
    [];
  readonly halves: { cx: number; cy: number; radius: number; color: number }[] =
    [];
  #circle: { cx: number; cy: number; radius: number } | null = null;
  #arc: { cx: number; cy: number; radius: number } | null = null;
  circle(cx: number, cy: number, radius: number) {
    this.#circle = { cx, cy, radius };
  }
  moveTo(_x: number, _y: number) {}
  arc(cx: number, cy: number, radius: number, _start: number, _end: number) {
    this.#arc = { cx, cy, radius };
  }
  closePath() {}
  fill(style: { color: number }) {
    if (this.#circle) {
      this.discs.push({ ...this.#circle, color: style.color });
      this.#circle = null;
      return;
    }
    assert(this.#arc !== null, "a fill with no shape under it");
    this.halves.push({ ...this.#arc, color: style.color });
    this.#arc = null;
  }
}

function activity(radius: number, what: PeerActivity): ActivityRecorder {
  const g = new ActivityRecorder();
  drawNodeActivity(g, radius, what, COLORS);
  return g;
}

Deno.test("an idle node is not marked at all", () => {
  // "Nothing is in flight here" is the resting state of every node on the
  // stage, so marking it would put a mark on almost everything and the mark
  // would stop meaning anything.
  const g = activity(NODE_RADIUS, "idle");
  assertEquals(g.discs.length, 0);
  assertEquals(g.halves.length, 0);
});

Deno.test("the activity mark rides the body's own corner", () => {
  // A claim is half a peer's width. A mark placed off a peer's radius would
  // float out in open space beside the claim, or land on the peer it claims,
  // and either way it would be marking the wrong node.
  for (const style of [LOOSE_END_ALONE, LOOSE_END_CLAIMING]) {
    const ring = at(activity(style.radius, "sending").discs, 0, "ring");
    assert(
      ring.cx > 0 && ring.cx < style.radius &&
        ring.cy < 0 && ring.cy > -style.radius,
      `a ${style.radius} body put its mark at (${ring.cx}, ${ring.cy})`,
    );
    assertEquals(ring.cx, -ring.cy, "the mark is not on the corner diagonal");
  }
});

Deno.test("the mark is the same size on a peer and on a claim", () => {
  // It reports one fact — bytes are moving here — and the same fact drawn
  // smaller would read as a lesser one. Only the corner it sits on moves.
  const peer = activity(LOOSE_END_ALONE.radius, "receiving");
  const claim = activity(LOOSE_END_CLAIMING.radius, "receiving");
  assertEquals(
    at(peer.discs, 0, "ring").radius,
    at(claim.discs, 0, "ring").radius,
  );
  assertEquals(
    at(peer.discs, 1, "dot").radius,
    at(claim.discs, 1, "dot").radius,
  );
});

Deno.test("the mark sits inside its own ring, in the direction's color", () => {
  // The ring is what makes the dot legible over whatever fill is under it, so
  // a dot that outgrew it would read against the node instead.
  for (
    const [what, color] of [
      ["sending", COLORS.messageInFlight],
      ["receiving", COLORS.positive],
    ] as const
  ) {
    const g = activity(NODE_RADIUS, what);
    const ring = at(g.discs, 0, "ring");
    const dot = at(g.discs, 1, "dot");
    assertEquals(ring.color, COLORS.peerStroke);
    assertEquals(dot.color, color);
    assert(dot.radius < ring.radius, "the dot is not inside its ring");
    assertEquals(dot.cx, ring.cx);
    assertEquals(dot.cy, ring.cy);
  }
});

Deno.test("a node doing both says so in one mark, not two", () => {
  // Two marks would need two corners, and a reader would have to find both to
  // learn one thing. The dot splits instead: sending above, receiving below,
  // sharing the ring's center.
  const g = activity(NODE_RADIUS, "both");
  assertEquals(g.discs.length, 1, "the split dot drew a whole disc");
  assertEquals(g.halves.length, 2);
  const ring = at(g.discs, 0, "ring");
  const upper = at(g.halves, 0, "upper half");
  const lower = at(g.halves, 1, "lower half");
  assertEquals(upper.color, COLORS.messageInFlight);
  assertEquals(lower.color, COLORS.positive);
  for (const half of [upper, lower]) {
    assertEquals(half.cx, ring.cx);
    assertEquals(half.cy, ring.cy);
    assert(half.radius < ring.radius, "a half is not inside the ring");
  }
});

// ───────────────────── edge chips share a corridor ─────────────────────
// Several sessions between one pair fan into lanes `SESSION_BUNDLE_SPACING`
// apart ACROSS the corridor. A chip is around a hundred units wide and twenty
// tall, so thirty of separation clears the height and not the width: a bundle
// running up the page stacked its chips on top of one another. Each chip now
// also walks ALONG the corridor by however far out of the middle its lane
// rides, which puts the separation on the axis with room for it.

/** The point `positionEdgeLabel` puts a chip at. */
function chipAt(curve: SessionCurve): { x: number; y: number } {
  const at = { x: 0, y: 0 };
  positionEdgeLabel({
    position: {
      set: (x: number, y: number) => {
        at.x = x;
        at.y = y;
      },
    },
  }, curve);
  return at;
}

/** The bundle's lanes between two points, as the renderer builds them. */
function laneChips(
  a: { x: number; y: number },
  b: { x: number; y: number },
  size: number,
): Array<{ x: number; y: number }> {
  return Array.from(
    { length: size },
    (_, index) => chipAt(curveBetween("a", a, "b", b, { index, size })),
  );
}

/** The chip a session's edge actually carries, measured from the metrics the
 *  renderer sets it in rather than from a remembered size. `capnp ·
 *  pancake-next` is the widest of the four codec-and-version pairs, so it is
 *  the pair that has to clear.
 *
 *  Read through `pillSize` on purpose: raising `EDGE_CHIP_LABEL.fontPx` or its
 *  padding grows the chips this file separates, and the angle sweep below then
 *  fails on the stride that no longer clears them, instead of passing over
 *  chips that now overlap on screen. */
const WIDEST_CHIP = "capnp · pancake-next";
const CHIP = pillSize(WIDEST_CHIP.length, EDGE_CHIP_LABEL, true);
const CHIP_WIDTH = CHIP.width;
const CHIP_HEIGHT = CHIP.height;

/** Whether two chips centered at these points would paint over each other. */
function chipsCollide(
  p: { x: number; y: number },
  q: { x: number; y: number },
): boolean {
  return Math.abs(p.x - q.x) < CHIP_WIDTH && Math.abs(p.y - q.y) < CHIP_HEIGHT;
}

Deno.test("a lone session's chip sits on its own apex", () => {
  // The common case, and the one that must not move: a single session draws a
  // straight curve whose control point is the chord midpoint, so there is no
  // lane to read back and the chip keeps the plain perpendicular offset.
  const curve = curveBetween("a", { x: -200, y: 0 }, "b", { x: 200, y: 0 }, {
    index: 0,
    size: 1,
  });
  const at = chipAt(curve);
  assertEquals(at.x, 0);
  assert(at.y < 0, "the chip should sit above the wire, not on it");
  assertEquals(Math.abs(at.y), 14);
});

Deno.test("a pair of chips clears at every corridor angle", () => {
  // The defect in one assertion. A vertical corridor puts the lanes' thirty
  // units of separation on the horizontal axis, where a chip needs its whole
  // width, so the chips landed on top of one another. Every angle is
  // checked because a fix that only worked on one axis would be the same bug
  // rotated, and because the two separations are at right angles and partly
  // cancel on the page — the shallow angles are where the first attempt at
  // this still collided.
  //
  // At 100% zoom, which is the only zoom a world-unit stride and a
  // screen-sized chip agree at; `stage-labels.ts` says why one solve cannot
  // hold every zoom.
  for (let deg = 0; deg < 180; deg += 5) {
    const rad = (deg / 180) * Math.PI;
    const r = 175;
    const a = { x: -Math.cos(rad) * r, y: -Math.sin(rad) * r };
    const b = { x: Math.cos(rad) * r, y: Math.sin(rad) * r };
    const chips = laneChips(a, b, 2);
    assert(
      !chipsCollide(chips[0]!, chips[1]!),
      `at ${deg}° the two chips landed at ${JSON.stringify(chips[0])} and ${
        JSON.stringify(chips[1])
      }`,
    );
  }
});

Deno.test("a bundle's chips separate whichever end its session listed first", () => {
  // Which lane a chip rides is read off the curve's own bow rather than an
  // index handed in, and the bow's direction is canonical while `a` and `b`
  // are not: two sessions on one pair may list their ends either way round.
  // A direction that flipped with the listing would walk two lanes the same
  // way and land them on one point, so the lanes have to clear each other
  // even when consecutive ones are built in opposite orders.
  const p = { x: 0, y: -260 };
  const q = { x: 0, y: 260 };
  const chips = [0, 1, 2].map((index) =>
    index % 2 === 0
      ? chipAt(curveBetween("a", p, "b", q, { index, size: 3 }))
      : chipAt(curveBetween("b", q, "a", p, { index, size: 3 }))
  );
  for (let i = 0; i < chips.length; i++) {
    for (let j = i + 1; j < chips.length; j++) {
      assert(
        !chipsCollide(chips[i]!, chips[j]!),
        `lanes ${i} and ${j} collided once their sessions listed ends differently: ${
          JSON.stringify(chips[i])
        } and ${JSON.stringify(chips[j])}`,
      );
    }
  }
});

Deno.test("a big bundle keeps its chips on their own wire, and apart", () => {
  // The walk is bounded, so a bundle wide enough to want more of the edge than
  // there is does not fling a chip past the node it runs to. Bounded by a
  // curve that keeps rising rather than by a limit, so two lanes past the
  // bound still land in two places — a clamp would stack exactly the chips
  // this exists to separate.
  const a = { x: -400, y: 0 };
  const b = { x: 400, y: 0 };
  const chips = laneChips(a, b, 9);
  const seen = new Set<string>();
  for (const chip of chips) {
    assert(
      Math.abs(chip.x) < 400,
      `a chip walked to ${chip.x.toFixed(0)}, off the end of an 800-unit edge`,
    );
    const key = chip.x.toFixed(6);
    assert(!seen.has(key), `two lanes of nine landed on ${key}`);
    seen.add(key);
  }
});

Deno.test("a focus ring holds one screen size at every zoom", () => {
  // Selection matters most zoomed out, because that is where a reader is picking
  // one thing out of a crowd. The body a ring hugs is a world thing and shrinks
  // with the camera; the ring's own geometry is a statement about the reader's
  // state, so it is measured in screen pixels and divided by the camera scale.
  //
  // Measured as screen pixels at each zoom: the gap the ring holds off the
  // body's diagonal corners, and the weight it is stroked with. Both are the
  // same number at every scale, which is the whole claim.
  const radius = 30;
  const diagonal = radius * Math.SQRT2;
  const seen = new Set<string>();
  for (const scale of [0.02, 0.25, 1, 4, 20]) {
    const ring = at(halo(radius, "selected", false, scale).rings, 0, "ring");
    const gapPx = (ring.radius - diagonal) * scale;
    const widthPx = ring.width * scale;
    seen.add(`${gapPx.toFixed(4)}|${widthPx.toFixed(4)}`);
  }
  assertEquals(
    seen.size,
    1,
    `the ring's screen geometry changed with the zoom: ${[...seen].join(" ")}`,
  );
});

Deno.test("the anchor and hover rings hold their screen inset too", () => {
  // The whole selection vocabulary has to read as one thing at any zoom, so a
  // ring that compensates while the ring inside it does not would come apart as
  // the camera pulls back — the inner ring would drift out through the outer.
  const radius = 30;
  const anchorInsets = new Set<string>();
  const hoverInsets = new Set<string>();
  for (const scale of [0.02, 0.25, 1, 4, 20]) {
    const anchor = halo(radius, "anchor", false, scale).rings;
    const outer = at(anchor, 0, "outer");
    const inner = at(anchor, 1, "inner");
    anchorInsets.add(
      `${((outer.radius - inner.radius) * scale).toFixed(4)}|${
        (inner.width * scale).toFixed(4)
      }`,
    );
    const hover = at(halo(radius, "none", true, scale).rings, 0, "hover");
    hoverInsets.add(
      `${((outer.radius - hover.radius) * scale).toFixed(4)}|${
        (hover.width * scale).toFixed(4)
      }`,
    );
  }
  assertEquals(
    anchorInsets.size,
    1,
    `anchor inset drifted: ${[...anchorInsets]}`,
  );
  assertEquals(hoverInsets.size, 1, `hover inset drifted: ${[...hoverInsets]}`);
});

// ───────────────────── session line tips ──────────────────────────────

/**
 * A session line's tips are round, and on a dashed line only its tips are.
 *
 * Where a line meets a peer the node body hides its end. Where it meets a
 * session end nobody has attributed, the body is see-through and the tip shows
 * through it, so a flat one reads as a line that was cut rather than one that
 * arrives.
 *
 * Two things make that work on a dashed line, and both were wrong first time.
 * Each dash is one sub-path however many curve samples it spans, or every
 * internal joint takes a cap and the line renders as beads. And a dash the curve
 * cut short is dropped, because a round cap on a sliver is a dot sitting off the
 * end of the line — which is exactly what it looked like on screen.
 */
type CurveCall =
  | { op: "moveTo"; x: number; y: number }
  | { op: "lineTo"; x: number; y: number }
  | { op: "quad" }
  | { op: "stroke"; cap: string | undefined };

class CurveRecorder implements CurveCanvas {
  readonly calls: CurveCall[] = [];
  moveTo(x: number, y: number) {
    this.calls.push({ op: "moveTo", x, y });
  }
  lineTo(x: number, y: number) {
    this.calls.push({ op: "lineTo", x, y });
  }
  quadraticCurveTo() {
    this.calls.push({ op: "quad" });
  }
  stroke(style: { cap?: string }) {
    this.calls.push({ op: "stroke", cap: style.cap });
  }
  /** The sub-paths, grouped by the stroke that painted them. A sub-path is one
   *  dash: the `moveTo` that opened it and every point after. */
  passes(): {
    cap: string | undefined;
    dashes: { x: number; y: number }[][];
  }[] {
    const out: ReturnType<CurveRecorder["passes"]> = [];
    let dashes: { x: number; y: number }[][] = [];
    let dash: { x: number; y: number }[] | null = null;
    for (const c of this.calls) {
      if (c.op === "moveTo") {
        if (dash) dashes.push(dash);
        dash = [{ x: c.x, y: c.y }];
      } else if (c.op === "lineTo") {
        assert(dash, "a lineTo with no sub-path open");
        dash.push({ x: c.x, y: c.y });
      } else if (c.op === "stroke") {
        if (dash) dashes.push(dash);
        dash = null;
        out.push({ cap: c.cap, dashes });
        dashes = [];
      }
    }
    return out;
  }
}

/** A straight run, written out rather than solved: what these tests measure is
 *  which dashes get a round cap, and a literal keeps the bundle solver out of
 *  it. Control point at the midpoint is the degenerate (straight) case. */
const A_CURVE: SessionCurve = {
  ax: 0,
  ay: 0,
  cx: 200,
  cy: 0,
  bx: 400,
  by: 0,
};

const LINE = { color: 0x336699, width: 4, alpha: 1 };

Deno.test("a solid session line has round tips", () => {
  const g = new CurveRecorder();
  strokeCurve(g, A_CURVE, LINE);
  const passes = g.passes();
  assertEquals(passes.length, 1);
  assertEquals(at(passes, 0, "pass").cap, "round");
});

Deno.test("a dashed session line is round at its tips and flat between", () => {
  const g = new CurveRecorder();
  strokeDashedCurve(g, A_CURVE, [12, 6], LINE);
  const passes = g.passes();
  assertEquals(passes.length, 2, "one pass for the middle, one for the tips");
  const middle = at(passes, 0, "pass");
  const tips = at(passes, 1, "pass");
  assert(
    middle.dashes.length > 1,
    `expected dashes between the tips, got ${middle.dashes.length}`,
  );
  assertEquals(middle.cap, undefined);
  assertEquals(tips.cap, "round");
  assertEquals(tips.dashes.length, 2);
});

Deno.test("each dash is one sub-path, so no internal joint takes a cap", () => {
  // The bead failure: a dash spanning a sample boundary used to be two
  // sub-paths, and the round pass then capped the middle of a dash.
  const g = new CurveRecorder();
  // A curve long enough that a 12-unit dash must cross the 24 sample points.
  strokeDashedCurve(
    g,
    { ax: 0, ay: 0, cx: 60, cy: 0, bx: 120, by: 0 },
    [12, 6],
    LINE,
  );
  for (const pass of g.passes()) {
    for (const dash of pass.dashes) {
      assert(dash.length >= 2, "a sub-path with nothing in it");
      // Every point of one dash advances along the run, so the sub-path is one
      // dash rather than two that happen to be adjacent.
      for (let i = 1; i < dash.length; i++) {
        assert(
          at(dash, i, "point").x > at(dash, i - 1, "point").x - 1e-9,
          "a dash doubled back on itself",
        );
      }
    }
  }
});

Deno.test("the round tips are the line's own ends", () => {
  const g = new CurveRecorder();
  strokeDashedCurve(g, A_CURVE, [12, 6], LINE);
  const passes = g.passes();
  const tips = at(passes, 1, "pass");
  const head = at(tips.dashes, 0, "tip");
  const tail = at(tips.dashes, 1, "tip");
  assertAlmostEquals(at(head, 0, "point").x, A_CURVE.ax, 1e-9);
  assertAlmostEquals(at(head, 0, "point").y, A_CURVE.ay, 1e-9);
  const tailEnd = at(tail, tail.length - 1, "point");
  assert(
    tailEnd.x <= A_CURVE.bx + 1e-9,
    `the tail tip ended past the curve: ${tailEnd.x} > ${A_CURVE.bx}`,
  );
  // And every middle dash lies between them along the run.
  const headEnd = at(head, head.length - 1, "point");
  const tailStart = at(tail, 0, "point");
  for (const dash of at(passes, 0, "pass").dashes) {
    const from = at(dash, 0, "point");
    const to = at(dash, dash.length - 1, "point");
    assert(
      from.x >= headEnd.x - 1e-9 && to.x <= tailStart.x + 1e-9,
      `a middle dash (${from.x}..${to.x}) fell outside the tips ` +
        `(${headEnd.x}..${tailStart.x})`,
    );
  }
});

Deno.test("a dash the curve cut short is dropped, not rounded into a dot", () => {
  // What it looked like on screen: the line reached a session end nobody had
  // attributed, the pattern ran out a hair past the last full dash, and the
  // round cap turned that hair into a dot floating inside the end's body.
  //
  // The run is 25 units with a 12-on/6-off pattern: dashes at 0..12 and 18..25,
  // leaving a 7-unit tail — longer than the 4-wide line, so it stays. Widen the
  // line past the tail and it must go.
  const cut: SessionCurve = { ax: 0, ay: 0, cx: 12.5, cy: 0, bx: 25, by: 0 };
  const kept = new CurveRecorder();
  strokeDashedCurve(kept, cut, [12, 6], { ...LINE, width: 4 });
  const keptTips = at(kept.passes(), 0, "pass");
  assertEquals(
    keptTips.dashes.length,
    2,
    "a tail longer than the line is a dash",
  );

  const dropped = new CurveRecorder();
  strokeDashedCurve(dropped, cut, [12, 6], { ...LINE, width: 9 });
  const droppedPasses = dropped.passes();
  assertEquals(
    droppedPasses.length,
    1,
    "one pass: both remaining dashes are tips",
  );
  assertEquals(
    at(droppedPasses, 0, "pass").dashes.length,
    1,
    "the sliver tail should have been dropped, leaving one dash",
  );
});
