/**
 * Interruptions the reader actually finished. `hasSomethingToCommit`
 * is the one rule a buttonless move, a lost capture, and a `finished`
 * end all ask; the answer differs by state.
 */

import { assert, assertEquals } from "@std/assert";
import { dummyHit } from "../gesture-resolver.ts";
import { hasSomethingToCommit } from "../pointer-machine.ts";
import { IDLE_MACHINE } from "../types.ts";
import { dispatch, gctx, snap } from "./harness.ts";

// ───────────────── Interruptions the reader actually finished ─────────

/**
 * A surface hears that the reader finished a gesture it could not see in three
 * ways: a pointermove carrying `buttons: 0`, a lost pointer capture, and a
 * `finished` end from the window watch in `gesture-router.ts`.
 * `hasSomethingToCommit` is the one rule all three ask, and these pin it per
 * state, because the answer differs by state and every one of them was previously
 * answered "cancel".
 *
 * It answers about the STATE only. Whether the reader finished the gesture at all
 * is the watch's `GestureEndReason`, pinned in `gesture-surface.test.ts`; a
 * `pointercancel` finishes nothing however promising the state looks.
 *
 * What the wrong answer looked like: a fast marquee selected nothing. The button
 * comes up mid-motion, a buttonless move reaches the window before the surface's
 * own pointerup, the watch reported an interruption, and the drag was cancelled
 * with its whole selection still only in the preview. Speed decided whether it
 * happened, so it read as random.
 *
 * The wiring from these to a real surface is browser-only — `use-surface-pointer`
 * is a hook, and Deno has no DOM — so what is checked here is the decision, and
 * the flick itself was measured in a browser: with one buttonless move ahead of
 * the release, a marquee over a peer went from selecting nothing to selecting the
 * same three entities a normal release does.
 *
 * Validated by injection: answering "pressed" instead of "dragging" fails both of
 * the first two. Answering a bare `false` — the old behavior — does not compile,
 * because the parameter goes unread, so it proves nothing and is not the check.
 */
Deno.test("a drag the reader finished out of sight has something to commit", () => {
	const { state } = dispatch(IDLE_MACHINE, [
		{
			kind: "pointer-down",
			surface: "stage-empty",
			snapshot: snap({ clientX: 100, clientY: 100 }),
			ctx: gctx({ hit: dummyHit("stage-empty") }),
		},
		{
			kind: "pointer-move",
			snapshot: snap({ clientX: 140, clientY: 140 }),
			hit: dummyHit("stage-empty"),
		},
	]);
	assertEquals(state.fsm.kind, "dragging");
	assert(
		hasSomethingToCommit(state),
		"a drag in flight has something to commit and was thrown away",
	);
});

Deno.test("a press that never dragged has nothing to commit", () => {
	// Nothing is in flight to commit, and ending it would fire a click at wherever
	// the pointer was when the news arrived — which may be nowhere near what was
	// pressed, since this path is reached precisely when we missed the events in
	// between.
	const { state } = dispatch(IDLE_MACHINE, [{
		kind: "pointer-down",
		surface: "stage-peer",
		snapshot: snap(),
		ctx: gctx({ hit: dummyHit("stage-peer") }),
	}]);
	assertEquals(state.fsm.kind, "pressed");
	assertEquals(hasSomethingToCommit(state), false);
});

Deno.test("an idle machine has nothing to commit", () => {
	// The ordinary case, and why the rule is safe to ask on every path: a normal
	// release commits through the surface's own pointerup first, so the watch's
	// report lands here and does nothing.
	assertEquals(hasSomethingToCommit(IDLE_MACHINE), false);
});
