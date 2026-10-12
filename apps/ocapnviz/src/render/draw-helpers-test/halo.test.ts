/**
 * The node focus ring: selected, anchor, and hover.
 *
 * The body a ring hugs is a world thing. The ring's own geometry is a
 * statement about the reader's state, so it is measured in screen
 * pixels.
 */

import { assert, assertEquals } from "@std/assert";
import type { HaloTier } from "../types.ts";
import { drawNodeHalo, type HaloCanvas, LOOSE_END_ALONE, LOOSE_END_CLAIMING, looseEndStyle } from "../draw-helpers.ts";
import { at } from "./harness.ts";

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
	// Inspector follows, and the answer must not be a different ring. It is the
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
		const ring = at(
			halo(radius, "selected", false, scale).rings,
			0,
			"ring",
		);
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
	// the camera pulls back. The inner ring would drift out through the outer.
	const radius = 30;
	const anchorInsets = new Set<string>();
	const hoverInsets = new Set<string>();
	for (const scale of [0.02, 0.25, 1, 4, 20]) {
		const anchor = halo(radius, "anchor", false, scale).rings;
		const outer = at(anchor, 0, "outer");
		const inner = at(anchor, 1, "inner");
		anchorInsets.add(
			`${((outer.radius - inner.radius) * scale).toFixed(4)}|${(inner.width * scale).toFixed(4)}`,
		);
		const hover = at(halo(radius, "none", true, scale).rings, 0, "hover");
		hoverInsets.add(
			`${((outer.radius - hover.radius) * scale).toFixed(4)}|${(hover.width * scale).toFixed(4)}`,
		);
	}
	assertEquals(
		anchorInsets.size,
		1,
		`anchor inset drifted: ${[...anchorInsets]}`,
	);
	assertEquals(
		hoverInsets.size,
		1,
		`hover inset drifted: ${[...hoverInsets]}`,
	);
});
