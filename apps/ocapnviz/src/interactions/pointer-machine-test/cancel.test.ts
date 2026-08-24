/**
 * Cancel: a drag in flight emits drag-cancel; a press that never
 * dragged emits nothing.
 */

import { assertEquals } from "@std/assert";
import { dummyHit } from "../gesture-resolver.ts";
import { pointerReducer } from "../pointer-machine.ts";
import { IDLE_MACHINE } from "../types.ts";
import { dispatch, gctx, snap } from "./harness.ts";

// ─────────────────────── Cancel ───────────────────────────────────────

Deno.test("dragging + cancel → idle; drag-cancel", () => {
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
	const r = pointerReducer(state, { kind: "cancel" });
	assertEquals(r.state.fsm.kind, "idle");
	assertEquals(r.effects[0]!.kind, "drag-cancel");
});

Deno.test("pressed + cancel → idle; no effect", () => {
	const { state } = dispatch(IDLE_MACHINE, [{
		kind: "pointer-down",
		surface: "stage-peer",
		snapshot: snap(),
		ctx: gctx({ hit: dummyHit("stage-peer") }),
	}]);
	const r = pointerReducer(state, { kind: "cancel" });
	assertEquals(r.state.fsm.kind, "idle");
	assertEquals(r.effects, []);
});
