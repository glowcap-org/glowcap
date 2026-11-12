/**
 * Space mid-press: converting a drag into a pan and back, and the
 * two invariants that conversion has to keep (pause then resume/end,
 * and a pan-step that is not also a drag-move).
 */

import { assert, assertEquals } from "@std/assert";
import { dummyHit } from "../gesture-resolver-test/harness.ts";
import { IDLE_MACHINE, pointerReducer } from "../pointer-machine.ts";
import { dispatch, gctx, snap } from "./harness.ts";

// ─────────────────────── Space mid-press (Figma-convert) ──────────────

Deno.test("pressed plus space-down moves to paused-pan and emits no drag-pause because no drag is in flight", () => {
	const { state } = dispatch(IDLE_MACHINE, [{
		kind: "pointer-down",
		surface: "stage-empty",
		snapshot: snap(),
		ctx: gctx({ hit: dummyHit("stage-empty") }),
	}]);
	const r = pointerReducer(state, { kind: "space-down" });
	assertEquals(r.state.fsm.kind, "paused-pan");
	assertEquals(r.effects, []);
});

Deno.test("dragging plus space-down moves to paused-pan and emits drag-pause", () => {
	const { state } = dispatch(IDLE_MACHINE, [
		{
			kind: "pointer-down",
			surface: "stage-empty",
			snapshot: snap({ clientX: 0, clientY: 0 }),
			ctx: gctx({ hit: dummyHit("stage-empty") }),
		},
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 50, clientY: 0 }),
			hit: dummyHit("stage-empty"),
		},
	]);
	const r = pointerReducer(state, { kind: "space-down" });
	assertEquals(r.state.fsm.kind, "paused-pan");
	assertEquals(r.effects[0]!.kind, "drag-pause");
});

Deno.test("paused-pan plus pointer-move emits a pan-step with surface and delta", () => {
	const { state } = dispatch(IDLE_MACHINE, [
		{
			kind: "pointer-down",
			surface: "stage-empty",
			snapshot: snap({ clientX: 0, clientY: 0 }),
			ctx: gctx({ hit: dummyHit("stage-empty") }),
		},
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 50, clientY: 0 }),
			hit: dummyHit("stage-empty"),
		},
		{ kind: "space-down" },
	]);
	const r = pointerReducer(state, {
		kind: "pointer-move",
		snapshot: snap({ clientX: 60, clientY: 5 }),
		hit: dummyHit("stage-empty"),
	});
	assertEquals(r.effects.length, 1);
	const eff = r.effects[0]!;
	assert(eff.kind === "pan-step");
	assertEquals(eff.surface, "stage-empty");
	assertEquals(eff.delta, { dx: 10, dy: 5 });
});

Deno.test("paused-pan plus space-up with the button held returns to dragging and emits drag-resume with carriedOrigin", () => {
	// Drag, pan, release space while still holding pointer.
	const { state } = dispatch(IDLE_MACHINE, [
		{
			kind: "pointer-down",
			surface: "stage-empty",
			snapshot: snap({ clientX: 0, clientY: 0 }),
			ctx: gctx({ hit: dummyHit("stage-empty") }),
		},
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 50, clientY: 0 }),
			hit: dummyHit("stage-empty"),
		},
		{ kind: "space-down" },
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 60, clientY: 5 }),
			hit: dummyHit("stage-empty"),
		},
	]);
	const r = pointerReducer(state, {
		kind: "space-up",
		pointerHeld: true,
	});
	assertEquals(r.state.fsm.kind, "dragging");
	const eff = r.effects[0]!;
	assert(eff.kind === "drag-resume");
	// Carried origin = the cursor position at space-up
	assertEquals(eff.carriedOrigin.clientX, 60);
	assertEquals(eff.carriedOrigin.clientY, 5);
});

Deno.test("paused-pan plus space-up with the button released goes idle and emits drag-end", () => {
	const { state } = dispatch(IDLE_MACHINE, [
		{
			kind: "pointer-down",
			surface: "stage-empty",
			snapshot: snap({ clientX: 0, clientY: 0 }),
			ctx: gctx({ hit: dummyHit("stage-empty") }),
		},
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 50, clientY: 0 }),
			hit: dummyHit("stage-empty"),
		},
		{ kind: "space-down" },
	]);
	const r = pointerReducer(state, {
		kind: "space-up",
		pointerHeld: false,
	});
	assertEquals(r.state.fsm.kind, "idle");
	assertEquals(r.effects[0]!.kind, "drag-end");
});

Deno.test("paused-pan plus pointer-up goes idle and emits drag-end, even if space is still held", () => {
	const { state } = dispatch(IDLE_MACHINE, [
		{
			kind: "pointer-down",
			surface: "stage-empty",
			snapshot: snap({ clientX: 0, clientY: 0 }),
			ctx: gctx({ hit: dummyHit("stage-empty") }),
		},
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 50, clientY: 0 }),
			hit: dummyHit("stage-empty"),
		},
		{ kind: "space-down" },
	]);
	const r = pointerReducer(state, {
		kind: "pointer-up",
		snapshot: snap({ clientX: 60, clientY: 5 }),
		ctxAtUp: gctx({ hit: dummyHit("stage-empty") }),
	});
	assertEquals(r.state.fsm.kind, "idle");
	assertEquals(r.effects[0]!.kind, "drag-end");
});
// ─────────────────────── drag-pause → resume/end/cancel ──────────

Deno.test("drag-pause is followed by drag-resume (space-up + button held)", () => {
	const { effects } = dispatch(IDLE_MACHINE, [
		{
			kind: "pointer-down",
			surface: "stage-empty",
			snapshot: snap({ clientX: 0, clientY: 0 }),
			ctx: gctx({ hit: dummyHit("stage-empty") }),
		},
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 50, clientY: 0 }),
			hit: dummyHit("stage-empty"),
		},
		{ kind: "space-down" }, // drag-pause
		{ kind: "space-up", pointerHeld: true }, // drag-resume
	]);
	const kinds = effects.map((e) => e.kind);
	// Drag-start, drag-pause, drag-resume. One resume per pause
	assert(kinds.includes("drag-pause"));
	assert(kinds.includes("drag-resume"));
	const pauses = kinds.filter((k) => k === "drag-pause").length;
	const resumes = kinds.filter((k) => k === "drag-resume").length;
	assertEquals(pauses, resumes);
});

Deno.test("drag-pause is followed by drag-end (space-up + button released)", () => {
	const { effects } = dispatch(IDLE_MACHINE, [
		{
			kind: "pointer-down",
			surface: "stage-empty",
			snapshot: snap({ clientX: 0, clientY: 0 }),
			ctx: gctx({ hit: dummyHit("stage-empty") }),
		},
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 50, clientY: 0 }),
			hit: dummyHit("stage-empty"),
		},
		{ kind: "space-down" },
		{ kind: "space-up", pointerHeld: false },
	]);
	const kinds = effects.map((e) => e.kind);
	assert(kinds.includes("drag-pause"));
	assert(kinds.includes("drag-end"));
});

// ─────────────────────── paused-pan only emits pan-step on move ──

Deno.test("pointer-move while paused-pan emits only pan-step (no drag-move)", () => {
	const { state } = dispatch(IDLE_MACHINE, [
		{
			kind: "pointer-down",
			surface: "stage-empty",
			snapshot: snap({ clientX: 0, clientY: 0 }),
			ctx: gctx({ hit: dummyHit("stage-empty") }),
		},
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 50, clientY: 0 }),
			hit: dummyHit("stage-empty"),
		},
		{ kind: "space-down" },
	]);
	const r = pointerReducer(state, {
		kind: "pointer-move",
		snapshot: snap({ clientX: 60, clientY: 0 }),
		hit: dummyHit("stage-empty"),
	});
	assertEquals(r.effects.length, 1);
	assertEquals(r.effects[0]!.kind, "pan-step");
});
