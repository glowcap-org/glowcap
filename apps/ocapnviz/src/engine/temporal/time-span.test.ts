import { assertEquals } from "@std/assert";
import {
	clearDuration,
	clearEnd,
	clearStart,
	markDerived,
	moveBy,
	resize,
	setDuration,
	setEnd,
	setSpanEndAt,
	setSpanStartAt,
	setStart,
	type TimeSpan,
	translateSpan,
} from "./time-span.ts";
import { implicitBound } from "./bound.ts";

/** A fresh span with both sides implicit, the fixture every verb starts from. */
const implicitTimeSpan = (): TimeSpan => ({ start: implicitBound(), duration: implicitBound() });

Deno.test("setStart marks explicit with value", () => {
	const v = setStart(implicitTimeSpan(), 7);
	assertEquals(v.start, { value: 7, explicit: true });
	assertEquals(v.duration.explicit, false);
});

Deno.test("clearStart drops explicit, preserves value", () => {
	const v = clearStart(setStart(implicitTimeSpan(), 7));
	assertEquals(v.start, { value: 7, explicit: false });
});

Deno.test("setDuration clamps negative to 0", () => {
	const v = setDuration(implicitTimeSpan(), -5);
	assertEquals(v.duration, { value: 0, explicit: true });
});

Deno.test("setDuration accepts zero (point-in-time)", () => {
	const v = setDuration(implicitTimeSpan(), 0);
	assertEquals(v.duration, { value: 0, explicit: true });
});

Deno.test("clearDuration drops explicit, preserves value", () => {
	const v = clearDuration(setDuration(implicitTimeSpan(), 9));
	assertEquals(v.duration, { value: 9, explicit: false });
});

Deno.test("setEnd computes duration from intrinsic start", () => {
	const base = setStart(implicitTimeSpan(), 3);
	const v = setEnd(base, 10, /* intrinsicStart */ 3);
	assertEquals(v.duration, { value: 7, explicit: true });
});

Deno.test("setEnd clamps to 0 when end is before intrinsic start", () => {
	const v = setEnd(implicitTimeSpan(), 2, /* intrinsicStart */ 5);
	assertEquals(v.duration, { value: 0, explicit: true });
});

Deno.test("clearEnd is an alias for clearDuration", () => {
	const base = setDuration(implicitTimeSpan(), 4);
	assertEquals(clearEnd(base).duration.explicit, false);
});

Deno.test("moveBy shifts start, leaves duration untouched", () => {
	const base = setDuration(setStart(implicitTimeSpan(), 5), 10);
	const moved = moveBy(base, /* delta */ 2, /* intrinsicStart */ 5);
	assertEquals(moved.start, { value: 7, explicit: true });
	assertEquals(moved.duration, { value: 10, explicit: true });
});

Deno.test("resize is an alias for setDuration", () => {
	const v = resize(implicitTimeSpan(), 6);
	assertEquals(v.duration, { value: 6, explicit: true });
});

Deno.test("ops do not mutate input (returned object is fresh)", () => {
	const base = implicitTimeSpan();
	const after = setStart(base, 1);
	assertEquals(base.start.explicit, false);
	assertEquals(after.start.explicit, true);
});

Deno.test("every authoring op strips the derived marker", () => {
	// The provenance contract: a span built by ANY authoring op is
	// user intent, so it must not carry the projection's derived
	// marker — a marker slipping through would let projection
	// clobber the user's edit on the next tick. Structural: the ops
	// build fresh objects; this test keeps that structure honest.
	const derived = markDerived({
		start: { value: 5, explicit: true },
		duration: { value: 10, explicit: true },
	});
	const results: [string, TimeSpan][] = [
		["setStart", setStart(derived, 7)],
		["clearStart", clearStart(derived)],
		["setDuration", setDuration(derived, 3)],
		["clearDuration", clearDuration(derived)],
		["setEnd", setEnd(derived, 20, 5)],
		["clearEnd", clearEnd(derived)],
		["moveBy", moveBy(derived, 2, 5)],
		["resize", resize(derived, 6)],
		["translateSpan", translateSpan(derived, 2, 5, 15)],
		["translateSpan (open)", translateSpan(derived, 2, 5, Infinity)],
		["setSpanEndAt", setSpanEndAt(5, 20)],
		["setSpanStartAt", setSpanStartAt(derived, 3, 15)],
		["setSpanStartAt (open)", setSpanStartAt(derived, 3, Infinity)],
	];
	for (const [name, span] of results) {
		assertEquals(
			span.derived,
			undefined,
			`${name} must produce an authored span`,
		);
	}
});
