/**
 * Timeline view helpers: clamp, zoom, pan, and wheel.
 *
 * `maxWidth` separates "how far can windowEnd go" (Live mode wants
 * Infinity for pan-into-future) from "how wide can the window get"
 * (Live mode wants `duration / 0.15`).
 */

import { assertEquals } from "@std/assert";
import { applyWheel, clampView, pan, type TimelineView, zoomAround } from "./state.ts";

const BASE_VIEW: TimelineView = {
	windowStart: 0,
	windowEnd: 100,
	expandedLanes: new Set(["ruler"]),
	expandedCategories: new Set(),
};

Deno.test("clampView: windowStart never goes negative", () => {
	// Time can't go below zero — pan-left always bottoms out at
	// the origin, even when called with a negative windowStart.
	const negStart: TimelineView = {
		...BASE_VIEW,
		windowStart: -50,
		windowEnd: 50,
	};
	const clamped = clampView(negStart, 100, 100, Number.POSITIVE_INFINITY);
	assertEquals(clamped.windowStart, 0);
	assertEquals(clamped.windowEnd, 100); // width preserved
});

Deno.test("clampView: maxWidth defaults to duration", () => {
	// Old single-bound semantics: width capped at duration.
	const wide: TimelineView = { ...BASE_VIEW, windowStart: 0, windowEnd: 500 };
	const clamped = clampView(wide, 100);
	assertEquals(clamped.windowEnd - clamped.windowStart, 100);
});

Deno.test("zoomAround: zoom-out grows width up to maxWidth (Live shape)", () => {
	// Live-mode shape: maxWidth=300 (1-week-ish cap),
	// panMaxT=Infinity (pan-right unbounded). Aggressive zoom-out
	// → width hits the 300 ceiling.
	const zoomedOut = zoomAround(
		BASE_VIEW,
		50,
		0.01,
		100,
		300,
		Number.POSITIVE_INFINITY,
	);
	assertEquals(zoomedOut.windowEnd - zoomedOut.windowStart, 300);
});

Deno.test(
	"zoomAround: a duration-only bound caps width at duration",
	() => {
		// Default maxWidth = duration, panMaxT = duration. Zoom-out
		// is clamped because windowEnd can't exceed duration — Play /
		// Build's historical "can't zoom past 1×".
		const zoomedOut = zoomAround(BASE_VIEW, 50, 0.01, 100);
		assertEquals(zoomedOut.windowEnd - zoomedOut.windowStart, 100);
	},
);

Deno.test("pan-right in Play / Build at 1× is a no-op", () => {
	// Window already covers the doc, and panMaxT=duration caps
	// the right edge → pan-right snaps back to [0, duration].
	const panned = pan(BASE_VIEW, 1000, 100);
	assertEquals(panned.windowStart, 0);
	assertEquals(panned.windowEnd, 100);
});

Deno.test("pan-right when zoomed-in slides within [0, panMaxT]", () => {
	// Width=50 < duration=100 → window can slide. Pan-right by 30:
	// [0, 50] → [30, 80]. Pan-right past the panMaxT clamps at
	// [50, 100].
	const v50: TimelineView = { ...BASE_VIEW, windowStart: 0, windowEnd: 50 };
	const slid = pan(v50, 30, 100);
	assertEquals(slid.windowStart, 30);
	assertEquals(slid.windowEnd, 80);
	const clamped = pan(v50, 1000, 100);
	assertEquals(clamped.windowStart, 50);
	assertEquals(clamped.windowEnd, 100);
});

Deno.test(
	"pan-right with panMaxT=Infinity drifts unbounded (Live shape)",
	() => {
		// Live mode: pan-right is unbounded. Pan from any width or
		// zoom level just slides windowStart up; windowEnd grows in
		// lockstep. windowStart never goes negative on a pan-LEFT
		// (see separate test), so the only floor is the t=0 origin.
		const v100: TimelineView = {
			...BASE_VIEW,
			windowStart: 0,
			windowEnd: 100,
		};
		const drifted = pan(v100, 500, 100, 100, Number.POSITIVE_INFINITY);
		assertEquals(drifted.windowStart, 500);
		assertEquals(drifted.windowEnd, 600);
	},
);

Deno.test("pan-left in Live mode bottoms out at windowStart=0", () => {
	// Live: panMaxT=Infinity, but `windowStart >= 0` is the hard
	// left floor — time never goes negative.
	const v100: TimelineView = {
		...BASE_VIEW,
		windowStart: 100,
		windowEnd: 200,
	};
	const left = pan(v100, -500, 100, 100, Number.POSITIVE_INFINITY);
	assertEquals(left.windowStart, 0);
	assertEquals(left.windowEnd, 100); // width preserved
});

Deno.test(
	"applyWheel: zoom-out saturates at maxWidth (Live-mode shape)",
	() => {
		// Simulate Live mode: duration=100 (captured), maxWidth=300
		// (zoom-out floor), panMaxT=Infinity (pan unbounded right).
		// Repeated wheel zoom-out asymptotes at maxWidth without
		// ever clipping width because panMaxT doesn't squeeze it.
		const liveMaxWidth = 300;
		let v: TimelineView = { ...BASE_VIEW, gutterWidth: 50 };
		for (let i = 0; i < 100; i++) {
			v = applyWheel(
				{ deltaX: 0, deltaY: 200, shiftKey: false },
				v,
				100,
				100,
				300,
				liveMaxWidth,
				Number.POSITIVE_INFINITY,
			);
		}
		const width = v.windowEnd - v.windowStart;
		assertEquals(
			Math.abs(width - liveMaxWidth) < 1e-6,
			true,
			`expected width≈${liveMaxWidth}, got ${width}`,
		);
	},
);
