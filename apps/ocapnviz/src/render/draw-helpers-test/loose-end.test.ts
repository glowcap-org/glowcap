/**
 * An unattributed end's body.
 *
 * A loose end whose claim names a peer the stage already draws is sat
 * on its own session's edge, two thirds of the way to that peer. That
 * is a fact about position, decided in `claim-placement.ts`,
 * and the drawing answers it: the pair has to read as somebody and a
 * claim about them rather than as two peers. What can be checked
 * without a canvas is the arithmetic of the two weights, and that the
 * selector hands each reading its own. That a claim draws ABOVE every
 * peer is a `zIndex` on a Pixi container, and nothing here can see it.
 */

import { assert, assertAlmostEquals } from "@std/assert";
import {
	drawLooseEndBody,
	LOOSE_END_ALONE,
	LOOSE_END_CLAIMING,
	NODE_RADIUS,
	type NodeBodyCanvas,
} from "../draw-helpers.ts";
import { at, RectRecorder } from "./harness.ts";

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
	// halve the dash. It halves how many fit. Three to a side is the floor
	// where a reader still sees a dashed square rather than a corner mark and a
	// smudge, and it is what stops the claim's outline from quietly becoming a
	// solid one as the shape shrinks.
	const g = drawn(LOOSE_END_CLAIMING);
	assert(
		g.dashes().length >= 12,
		`a claim's outline has ${g.dashes().length} dashes, under three a side`,
	);
});
