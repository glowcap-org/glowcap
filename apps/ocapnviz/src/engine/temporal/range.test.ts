import { assertEquals } from "@std/assert";
import { clampInto, containsTime, intersect, isEmpty, rangeOf } from "./range.ts";

Deno.test("isEmpty when end <= start", () => {
	assertEquals(isEmpty(rangeOf(2, 5)), false);
	assertEquals(isEmpty(rangeOf(5, 5)), true);
	assertEquals(isEmpty(rangeOf(5, 3)), true);
});

Deno.test("containsTime — half-open [start, end)", () => {
	const r = rangeOf(2, 5);
	assertEquals(containsTime(r, 1), false);
	assertEquals(containsTime(r, 2), true);
	assertEquals(containsTime(r, 4.999), true);
	assertEquals(containsTime(r, 5), false);
});

Deno.test("intersect — overlapping ranges", () => {
	assertEquals(
		intersect(rangeOf(2, 7), rangeOf(5, 10)),
		rangeOf(5, 7),
	);
});

Deno.test("intersect — disjoint ranges produce an empty result", () => {
	const r = intersect(rangeOf(0, 5), rangeOf(8, 10));
	assertEquals(isEmpty(r), true);
});

Deno.test("intersect — fully-contained returns the inner", () => {
	assertEquals(
		intersect(rangeOf(0, 10), rangeOf(2, 5)),
		rangeOf(2, 5),
	);
});

Deno.test("clampInto — inner fully within outer is unchanged", () => {
	assertEquals(
		clampInto(rangeOf(3, 5), rangeOf(0, 10)),
		rangeOf(3, 5),
	);
});

Deno.test("clampInto — inner exceeds outer end clamps end", () => {
	assertEquals(
		clampInto(rangeOf(3, 15), rangeOf(0, 10)),
		rangeOf(3, 10),
	);
});

Deno.test("clampInto — inner exceeds outer start clamps start", () => {
	assertEquals(
		clampInto(rangeOf(-5, 5), rangeOf(0, 10)),
		rangeOf(0, 5),
	);
});

Deno.test("clampInto — inner disjoint past outer collapses to outer.end", () => {
	// Saturating clamp keeps the entity visible at the parent's
	// boundary so children never disappear when stored intent drifts
	// outside the parent's effective span.
	assertEquals(
		clampInto(rangeOf(20, 30), rangeOf(0, 10)),
		rangeOf(10, 10),
	);
});

Deno.test("clampInto — inner disjoint before outer collapses to outer.start", () => {
	assertEquals(
		clampInto(rangeOf(-30, -10), rangeOf(0, 10)),
		rangeOf(0, 0),
	);
});
