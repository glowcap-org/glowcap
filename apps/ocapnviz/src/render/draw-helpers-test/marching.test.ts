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

import { assert, assertAlmostEquals } from "@std/assert";
import { drawArmedRing, drawMarchingLine, haloRadius, type MarchCanvas } from "../draw-helpers.ts";
import { at } from "./harness.ts";

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
		assertAlmostEquals(
			g.strokeWidth() * scale,
			2,
			1e-9,
			`stroke @${scale}`,
		);

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
		assertAlmostEquals(
			dashPx,
			6,
			6 * 0.5 / g.arcs().length,
			`dash @${scale}`,
		);
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

		assertAlmostEquals(
			g.strokeWidth() * scale,
			2,
			1e-9,
			`stroke @${scale}`,
		);

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
