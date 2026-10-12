/**
 * Matrix tests for the inheritance + effective resolver pair.
 * Each test names the layered state (stored / intrinsic /
 * effective) so a regression names what shifted, not just a
 * number.
 */

import { assertEquals } from "@std/assert";
import { explicitBound, implicitBound } from "./bound.ts";
import { effectiveOf } from "./effective.ts";
import { intrinsicOf } from "./inheritance.ts";
import { rangeOf } from "./range.ts";
import type { TimeSpan } from "./time-span.ts";
import { WORLD_EFFECTIVE, WORLD_INTRINSIC } from "./world.ts";

const span = (
	start: { value: number; explicit: boolean },
	duration: { value: number; explicit: boolean },
): TimeSpan => ({ start, duration });

/* ---------- peer (parent = world) ---------- */

Deno.test("peer: both implicit → spans the world", () => {
	const v = span(implicitBound(0), implicitBound(0));
	const i = intrinsicOf(v, WORLD_INTRINSIC);
	assertEquals(i, { start: 0, end: Number.POSITIVE_INFINITY });
	assertEquals(effectiveOf(i, WORLD_EFFECTIVE), i);
});

Deno.test("peer: explicit start, implicit duration → start to ∞", () => {
	const v = span(explicitBound(2), implicitBound(0));
	const i = intrinsicOf(v, WORLD_INTRINSIC);
	assertEquals(i, { start: 2, end: Number.POSITIVE_INFINITY });
});

Deno.test("peer: implicit start, explicit duration → 0 + duration", () => {
	const v = span(implicitBound(0), explicitBound(8));
	const i = intrinsicOf(v, WORLD_INTRINSIC);
	assertEquals(i, { start: 0, end: 8 });
});

Deno.test("peer: both explicit → as authored", () => {
	const v = span(explicitBound(3), explicitBound(10));
	const i = intrinsicOf(v, WORLD_INTRINSIC);
	assertEquals(i, { start: 3, end: 13 });
});

/* ---------- session (parent = peer overlap, here a finite range) ---------- */

const peerOverlap = rangeOf(2, 12);

Deno.test("session: both implicit → spans peer overlap", () => {
	const v = span(implicitBound(0), implicitBound(0));
	const i = intrinsicOf(v, peerOverlap);
	assertEquals(i, { start: 2, end: 12 });
});

Deno.test("session: explicit start inside overlap, implicit duration → start to overlap end", () => {
	const v = span(explicitBound(5), implicitBound(0));
	const i = intrinsicOf(v, peerOverlap);
	assertEquals(i, { start: 5, end: 12 });
});

Deno.test("session: explicit start before overlap → effective clamps start", () => {
	const v = span(explicitBound(0), implicitBound(0));
	const i = intrinsicOf(v, peerOverlap);
	assertEquals(i, { start: 0, end: 12 });
	// Effective clamp using peer-overlap as the *effective* context too.
	assertEquals(effectiveOf(i, peerOverlap), { start: 2, end: 12 });
});

Deno.test("session: explicit duration past overlap end → effective clamps end", () => {
	const v = span(explicitBound(5), explicitBound(20));
	const i = intrinsicOf(v, peerOverlap);
	assertEquals(i, { start: 5, end: 25 });
	assertEquals(effectiveOf(i, peerOverlap), { start: 5, end: 12 });
});

/* ---------- message (parent = session; duration ALWAYS explicit) ---------- */

const session = rangeOf(3, 10);

Deno.test("message: implicit start, explicit duration → starts where session starts", () => {
	const v = span(implicitBound(0), explicitBound(2));
	const i = intrinsicOf(v, session);
	assertEquals(i, { start: 3, end: 5 });
	assertEquals(effectiveOf(i, session), { start: 3, end: 5 });
});

Deno.test("message: explicit start past session end → effective collapses to empty at end", () => {
	const v = span(explicitBound(15), explicitBound(2));
	const i = intrinsicOf(v, session);
	assertEquals(i, { start: 15, end: 17 });
	const eff = effectiveOf(i, session);
	// Both ends clamp into [3, 10]; start = max(15, 3) = 15 but end = min(17, 10) = 10.
	// start > end → degenerate range; treat as empty.
	assertEquals(eff.start >= eff.end, true);
});

Deno.test("message: arrival past session end → effective end clamped, stored preserved", () => {
	const v = span(explicitBound(7), explicitBound(5));
	const i = intrinsicOf(v, session);
	assertEquals(i, { start: 7, end: 12 });
	assertEquals(effectiveOf(i, session), { start: 7, end: 10 });
	// intrinsic untouched, Inspector can show stored=5ms,
	// effective=3ms with "session <id>" as reason.
});

/* ---------- empty parent context ---------- */

Deno.test("any entity in an empty context → effective is empty", () => {
	const empty = rangeOf(5, 5);
	const v = span(explicitBound(2), explicitBound(8));
	const i = intrinsicOf(v, empty);
	const eff = effectiveOf(i, empty);
	assertEquals(eff.start >= eff.end, true);
});
