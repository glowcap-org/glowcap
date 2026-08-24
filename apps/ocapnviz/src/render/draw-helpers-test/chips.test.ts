/**
 * Edge chips share a corridor.
 *
 * Several sessions between one pair fan into lanes
 * `SESSION_BUNDLE_SPACING` apart ACROSS the corridor. A chip is around
 * a hundred units wide and twenty tall, so thirty of separation clears
 * the height and not the width: a bundle running up the page stacked
 * its chips on top of one another. Each chip now also walks ALONG the
 * corridor by however far out of the middle its lane rides, which puts
 * the separation on the axis with room for it.
 */

import { assert, assertEquals } from "@std/assert";
import { curveBetween, type SessionCurve } from "../../engine/session-geometry.ts";
import { EDGE_CHIP_LABEL, pillSize } from "../stage-labels.ts";
import { positionEdgeLabel } from "../edge-stroke.ts";

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
	return Math.abs(p.x - q.x) < CHIP_WIDTH &&
		Math.abs(p.y - q.y) < CHIP_HEIGHT;
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
			`at ${deg}° the two chips landed at ${JSON.stringify(chips[0])} and ${JSON.stringify(chips[1])}`,
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
