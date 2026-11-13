import { assertEquals } from "@std/assert";
import { clampInto, containsTime, intersect } from "./range.ts";

Deno.test("containsTime treats the range as half-open, [start, end)", () => {
	const r = { start: 2, end: 5 };
	assertEquals(containsTime(r, 1), false);
	assertEquals(containsTime(r, 2), true);
	assertEquals(containsTime(r, 4.999), true);
	assertEquals(containsTime(r, 5), false);
});

Deno.test("intersect of overlapping ranges", () => {
	assertEquals(
		intersect({ start: 2, end: 7 }, { start: 5, end: 10 }),
		{ start: 5, end: 7 },
	);
});

Deno.test("intersect of disjoint ranges produces an empty result", () => {
	const r = intersect({ start: 0, end: 5 }, { start: 8, end: 10 });
	assertEquals(r, { start: 8, end: 5 });
});

Deno.test("intersect of a fully contained range returns the inner", () => {
	assertEquals(
		intersect({ start: 0, end: 10 }, { start: 2, end: 5 }),
		{ start: 2, end: 5 },
	);
});

Deno.test("clampInto leaves an inner range fully within the outer unchanged", () => {
	assertEquals(
		clampInto({ start: 3, end: 5 }, { start: 0, end: 10 }),
		{ start: 3, end: 5 },
	);
});

Deno.test("clampInto clamps the end when the inner exceeds the outer end", () => {
	assertEquals(
		clampInto({ start: 3, end: 15 }, { start: 0, end: 10 }),
		{ start: 3, end: 10 },
	);
});

Deno.test("clampInto clamps the start when the inner exceeds the outer start", () => {
	assertEquals(
		clampInto({ start: -5, end: 5 }, { start: 0, end: 10 }),
		{ start: 0, end: 5 },
	);
});

Deno.test("clampInto collapses to outer.end when the inner is disjoint past the outer", () => {
	// Saturating clamp keeps the entity visible at the parent's
	// boundary so children never disappear when stored intent drifts
	// outside the parent's effective span.
	assertEquals(
		clampInto({ start: 20, end: 30 }, { start: 0, end: 10 }),
		{ start: 10, end: 10 },
	);
});

Deno.test("clampInto collapses to outer.start when the inner is disjoint before the outer", () => {
	assertEquals(
		clampInto({ start: -30, end: -10 }, { start: 0, end: 10 }),
		{ start: 0, end: 0 },
	);
});
