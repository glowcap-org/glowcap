/**
 * `spanScreenRect` is the single source of truth for "where on the
 * canvas does this t-range live?" — paint and hit-test both rely on
 * its clamp policy, stamp promotion, and edge-clamp flags agreeing
 * with each other. These tests exercise the six branch dimensions
 * directly so a future change to the clamp math gets caught here
 * before it diverges paint from hit-test integration tests.
 */
import { assertEquals } from "@std/assert";
import { SPAN_MIN_PILL_PX, spanScreenRect } from "./span-geometry.ts";

// 1px per unit of t, so t and px are interchangeable in these tests.
const tToPx = (t: number) => t;
const PLOT_X = 100;
const PLOT_WIDTH = 200;
// Plot band is [100, 300].

Deno.test("spanScreenRect: span fully inside the plot is unclamped", () => {
	const r = spanScreenRect({
		startT: 120,
		endT: 180,
		tToPx,
		plotX: PLOT_X,
		plotWidth: PLOT_WIDTH,
	});
	assertEquals(r, {
		left: 120,
		right: 180,
		isStamp: false,
		leftClamped: false,
		rightClamped: false,
	});
});

Deno.test("spanScreenRect: sub-minimum span promotes to a left-anchored stamp", () => {
	const r = spanScreenRect({
		startT: 150,
		endT: 152, // raw width 2 < SPAN_MIN_PILL_PX
		tToPx,
		plotX: PLOT_X,
		plotWidth: PLOT_WIDTH,
	});
	assertEquals(r, {
		left: 150,
		right: 150 + SPAN_MIN_PILL_PX,
		isStamp: true,
		leftClamped: false,
		rightClamped: false,
	});
});

Deno.test("spanScreenRect: open-ended span clamps right to plotRight and flags rightClamped", () => {
	const r = spanScreenRect({
		startT: 150,
		endT: Number.POSITIVE_INFINITY,
		tToPx,
		plotX: PLOT_X,
		plotWidth: PLOT_WIDTH,
	});
	assertEquals(r, {
		left: 150,
		right: 300,
		isStamp: false,
		leftClamped: false,
		rightClamped: true,
	});
});

Deno.test("spanScreenRect: start before plotX sets leftClamped", () => {
	const r = spanScreenRect({
		startT: 50, // unclamped < plotX (100)
		endT: 180,
		tToPx,
		plotX: PLOT_X,
		plotWidth: PLOT_WIDTH,
	});
	assertEquals(r, {
		left: 100,
		right: 180,
		isStamp: false,
		leftClamped: true,
		rightClamped: false,
	});
});

Deno.test("spanScreenRect: end past plotRight sets rightClamped", () => {
	const r = spanScreenRect({
		startT: 120,
		endT: 500, // unclamped > plotRight (300)
		tToPx,
		plotX: PLOT_X,
		plotWidth: PLOT_WIDTH,
	});
	assertEquals(r, {
		left: 120,
		right: 300,
		isStamp: false,
		leftClamped: false,
		rightClamped: true,
	});
});

Deno.test("spanScreenRect: span fully outside the plot returns null", () => {
	const before = spanScreenRect({
		startT: 0,
		endT: 50, // ends before plotX
		tToPx,
		plotX: PLOT_X,
		plotWidth: PLOT_WIDTH,
	});
	assertEquals(before, null);

	const after = spanScreenRect({
		startT: 400, // starts past plotRight
		endT: 500,
		tToPx,
		plotX: PLOT_X,
		plotWidth: PLOT_WIDTH,
	});
	assertEquals(after, null);
});
