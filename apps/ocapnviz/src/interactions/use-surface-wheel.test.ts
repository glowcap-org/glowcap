import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import { type WheelInput, wheelToEffect } from "./wheel-helpers.ts";

const TL = "timeline-overview" as const;
const STAGE = "stage-empty" as const;

function ev(over: Partial<WheelInput>): WheelInput {
	return {
		deltaX: 0,
		deltaY: 0,
		shiftKey: false,
		ctrlKey: false,
		metaKey: false,
		offsetX: 100,
		offsetY: 100,
		...over,
	};
}

// ─────────────────────── linear policy (Timeline) ─────────────────────

Deno.test("linear: when |deltaX| > |deltaY|, the wheel pans horizontally with dx=deltaX", () => {
	const r = wheelToEffect(ev({ deltaX: 50, deltaY: 10 }), TL, "linear");
	assertEquals(r.kind, "pan-step");
	if (r.kind === "pan-step") assertEquals(r.delta, { dx: 50, dy: 0 });
});

Deno.test("linear: shift plus deltaY pans horizontally with dx=deltaY", () => {
	const r = wheelToEffect(
		ev({ deltaY: 30, shiftKey: true }),
		TL,
		"linear",
	);
	if (r.kind === "pan-step") assertEquals(r.delta.dx, 30);
});

Deno.test("linear: a vertical deltaY without shift zooms around the cursor", () => {
	const r = wheelToEffect(ev({ deltaY: -100 }), TL, "linear");
	assertEquals(r.kind, "zoom-step");
	if (r.kind === "zoom-step") {
		assertEquals(r.pivotX, 100);
		assert(r.factor > 1);
	}
});

Deno.test("linear: a positive deltaY gives a factor below 1 (zoom out)", () => {
	const r = wheelToEffect(ev({ deltaY: 100 }), TL, "linear");
	if (r.kind === "zoom-step") assert(r.factor < 1);
});

Deno.test("linear: zero deltas give a near-identity zoom (factor about 1)", () => {
	const r = wheelToEffect(ev({}), TL, "linear");
	if (r.kind === "zoom-step") assertAlmostEquals(r.factor, 1, 1e-6);
});

// ─────────────────────── spatial policy (Stage) ───────────────────────
//
// Spatial = "zoom on vertical scroll, that's it". No auto-pan from
// wheel or trackpad, pan requires Spacebar / Hand tool. This is
// the predictable contract for a workspace canvas where the user's
// "what is the wheel for?" expectation should be one answer.

Deno.test("spatial: a vertical wheel zooms around the cursor", () => {
	const r = wheelToEffect(ev({ deltaY: -100 }), STAGE, "spatial");
	assertEquals(r.kind, "zoom-step");
	if (r.kind === "zoom-step") {
		assert(r.factor > 1, `expected factor > 1, got ${r.factor}`);
		assertEquals(r.pivotX, 100);
	}
});

Deno.test("spatial: a positive deltaY gives a factor below 1 (zoom out)", () => {
	const r = wheelToEffect(ev({ deltaY: 100 }), STAGE, "spatial");
	if (r.kind === "zoom-step") assert(r.factor < 1);
});

Deno.test("spatial: a trackpad with incidental deltaX STILL zooms (deltaX is ignored)", () => {
	// Trackpad gestures often carry small unintended horizontal
	// components. Spatial ignores them entirely to avoid surprise.
	const r = wheelToEffect(
		ev({ deltaX: 30, deltaY: 15 }),
		STAGE,
		"spatial",
	);
	assertEquals(r.kind, "zoom-step");
	if (r.kind === "zoom-step") assert(r.factor < 1); // positive deltaY = zoom out
});

Deno.test("spatial: a pure horizontal swipe (deltaY=0) gives a near-identity zoom (a no-op)", () => {
	const r = wheelToEffect(ev({ deltaX: 40, deltaY: 0 }), STAGE, "spatial");
	// No deltaY → zoomDelta = 0 → factor = 1 → no-op
	if (r.kind === "zoom-step") assertAlmostEquals(r.factor, 1, 1e-6);
});

Deno.test("spatial: shift plus vertical zooms fast and does not pan", () => {
	const slow = wheelToEffect(ev({ deltaY: -10 }), STAGE, "spatial");
	const fast = wheelToEffect(
		ev({ deltaY: -10, shiftKey: true }),
		STAGE,
		"spatial",
	);
	// Both should zoom (kind = zoom-step), shift should be more aggressive.
	assertEquals(slow.kind, "zoom-step");
	assertEquals(fast.kind, "zoom-step");
	if (slow.kind === "zoom-step" && fast.kind === "zoom-step") {
		assert(
			fast.factor > slow.factor,
			`fast zoom ${fast.factor} should exceed slow ${slow.factor}`,
		);
	}
});

Deno.test("spatial: zero deltas give a near-identity zoom (a no-op)", () => {
	const r = wheelToEffect(ev({}), STAGE, "spatial");
	if (r.kind === "zoom-step") assertAlmostEquals(r.factor, 1, 1e-6);
});

// ─────────────────────── Cross-policy contrast ────────────────────────

Deno.test("contrast: for a trackpad swipe, spatial zooms and linear pans horizontally", () => {
	const input = ev({ deltaX: 50, deltaY: 5 });
	const spatial = wheelToEffect(input, STAGE, "spatial");
	const linear = wheelToEffect(input, TL, "linear");
	assertEquals(spatial.kind, "zoom-step"); // ignores deltaX
	assertEquals(linear.kind, "pan-step"); // |deltaX| > |deltaY| → x-pan
});
