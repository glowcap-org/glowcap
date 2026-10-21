/**
 * A session line's tips are round, and on a dashed line only its tips are.
 *
 * Where a line meets a peer the node body hides its end. Where it meets a
 * session end nobody has attributed, the body is see-through and the tip shows
 * through it, so a flat one reads as a line that was cut rather than one that
 * arrives.
 *
 * Two things make that work on a dashed line. Each dash is one sub-path however
 * many curve samples it spans, or every internal joint takes a cap and the line
 * renders as beads. And a dash the curve cut short is dropped, because a round
 * cap on a sliver is a dot sitting off the end of the line.
 */

import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import type { SessionCurve } from "../../engine/session-geometry.ts";
import { type CurveCanvas, strokeCurve, strokeDashedCurve } from "../edge-stroke.ts";
import { at } from "./harness.ts";

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
	// The bead failure: a dash spanning a sample boundary must not become two
	// sub-paths, or the round pass caps the middle of a dash.
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
	// leaving a 7-unit tail, longer than the 4-wide line, so it stays. Widen the
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
