/**
 * The activity mark on a node that is sending, receiving, or both.
 */

import { assert, assertEquals } from "@std/assert";
import type { PeerActivity } from "../types.ts";
import { themedColors } from "../palette.ts";
import {
	type ActivityCanvas,
	drawNodeActivity,
	LOOSE_END_ALONE,
	LOOSE_END_CLAIMING,
	NODE_RADIUS,
} from "../draw-helpers.ts";
import { at } from "./harness.ts";

const COLORS = themedColors("light");

class ActivityRecorder implements ActivityCanvas {
	readonly discs: {
		cx: number;
		cy: number;
		radius: number;
		color: number;
	}[] = [];
	readonly halves: {
		cx: number;
		cy: number;
		radius: number;
		color: number;
	}[] = [];
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
		assertEquals(
			ring.cx,
			-ring.cy,
			"the mark is not on the corner diagonal",
		);
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
