/**
 * Hover tracking: pointer-move updates hover in every fsm state,
 * and a null hit clears it.
 */

import { assert, assertEquals } from "@std/assert";
import { dummyHit } from "../gesture-resolver-test/harness.ts";
import { IDLE_MACHINE, pointerReducer } from "../pointer-machine.ts";
import { dispatch, snap } from "./harness.ts";

// ─────────────────────── Hover tracking ───────────────────────────────

Deno.test("pointer-move updates hover regardless of fsm state", () => {
	const r = pointerReducer(IDLE_MACHINE, {
		kind: "pointer-move",
		snapshot: snap(),
		hit: dummyHit("stage-peer", { peerId: "hovered" }),
	});
	assert(r.state.hover !== null);
	assertEquals(r.state.hover.surface, "stage-peer");
});

Deno.test("a pointer-move with a null hit clears the hover", () => {
	const { state } = dispatch(IDLE_MACHINE, [{
		kind: "pointer-move",
		snapshot: snap(),
		hit: dummyHit("stage-peer"),
	}]);
	assert(state.hover !== null);
	const r = pointerReducer(state, {
		kind: "pointer-move",
		snapshot: snap(),
		hit: null,
	});
	assertEquals(r.state.hover, null);
});
