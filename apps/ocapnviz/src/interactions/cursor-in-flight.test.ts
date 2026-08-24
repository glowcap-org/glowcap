/**
 * The cursor while a gesture is running, driven through the two real
 * authorities it answers to: the pointer FSM and the keyboard.
 *
 * The defect these pin: releasing Space mid-drag reverted the cursor to a
 * plain arrow while the canvas was still panning under the user's hand. The
 * pan itself was right, and `pointer-machine.ts` owns it. What was wrong is
 * that the cursor asked the keyboard, which cannot answer.
 *
 * It cannot answer because a key press does not decide what a gesture is.
 * `resolveGesture` does, at the pointer-down, and from then on the FSM holds
 * it. Releasing Space during a pan leaves a pan running. Releasing it during a
 * marquee that Space interrupted puts the marquee back. Same key event, two
 * outcomes, and the only difference is what the press resolved to. So these
 * tests drive the real FSM and read the cursor off what it says, and both
 * outcomes appear below.
 *
 * The sibling table in `cursor.test.ts` covers the resting ladder — hover,
 * tools, refusals, previews. Pure: no DOM, no React.
 */

import { assertEquals } from "@std/assert";
import { type CSSCursor, type CursorContext, cursorFor } from "./cursor.ts";
import { pointerReducer } from "./pointer-machine.ts";
import { dummyHit } from "./gesture-resolver.ts";
import {
	type BuilderTool,
	type GestureContext,
	IDLE_MACHINE,
	type ModifierSet,
	NO_MODIFIERS,
	type PointerEvent_,
	type PointerMachineState,
	type PointerSnapshot,
} from "./types.ts";
import {
	type HeldGestures,
	isClaimed,
	NO_HELD_GESTURES,
	resolveKeyDown,
	resolveKeyUp,
} from "../state/keyboard-input.ts";
import { recordingBindings } from "../state/keyboard-shortcuts.fixture.ts";

// ── Driving the two real authorities ────────────────────────────

/** Press a key through the real keyboard authority. */
function press(held: HeldGestures, key: string, overStage = true) {
	return resolveKeyDown(
		held,
		{ key, cmd: false, shift: false, alt: false },
		{ overStage },
		recordingBindings().b,
	).held;
}

function snap(x = 0, y = 0): PointerSnapshot {
	return {
		clientX: x,
		clientY: y,
		buttons: 1,
		modifiers: NO_MODIFIERS,
		timestampMs: 0,
	};
}

function gctx(spaceHeld: boolean): GestureContext {
	return {
		hit: dummyHit("stage-empty"),
		modifiers: NO_MODIFIERS,
		spaceHeld,
		activeTool: "select",
	};
}

const down = (spaceHeld: boolean): PointerEvent_ => ({
	kind: "pointer-down",
	surface: "stage-empty",
	snapshot: snap(),
	ctx: gctx(spaceHeld),
});

const moveTo = (x: number): PointerEvent_ => ({
	kind: "pointer-move",
	snapshot: snap(x),
	hit: dummyHit("stage-empty"),
});

/** Run events through the real pointer FSM. */
function run(
	state: PointerMachineState,
	events: PointerEvent_[],
): PointerMachineState {
	let s = state;
	for (const ev of events) s = pointerReducer(s, ev).state;
	return s;
}

/** What the app reads off a held-gesture set to build the cursor's context —
 *  the same two lines `App` runs, so the keyboard authority is under test
 *  here and not paraphrased. */
function modifiers(held: HeldGestures): ModifierSet {
	return {
		shift: isClaimed(held, "shift"),
		alt: isClaimed(held, "alt"),
		cmd: false,
	};
}

function cursor(
	fsm: PointerMachineState,
	over?: { held?: HeldGestures; tool?: BuilderTool },
): CSSCursor {
	const held = over?.held ?? NO_HELD_GESTURES;
	const ctx: CursorContext = {
		modifiers: modifiers(held),
		spaceHeld: isClaimed(held, "space-pan"),
		activeTool: over?.tool ?? "select",
		toolState: null,
	};
	return cursorFor(ctx, fsm);
}

const IDLE = IDLE_MACHINE;

// ── The reported bug, and its mirror ─────────────────────────────

Deno.test("Space released mid-pan: the cursor keeps grabbing", () => {
	// Space first, so the press itself resolves to a pan. There is no
	// other gesture underneath it, so releasing Space leaves the pan
	// running and the cursor must go on saying so.
	const held = press(NO_HELD_GESTURES, " ");
	const panning = run(IDLE, [down(true), moveTo(40)]);
	assertEquals(cursor(panning, { held }), "grabbing");

	// Space up. The FSM is not in `paused-pan`, so nothing changes:
	// the gesture always was the pan.
	const afterKeyUp = run(panning, [{ kind: "space-up", pointerHeld: true }]);
	const released = resolveKeyUp(held, " ");
	assertEquals(cursor(afterKeyUp, { held: released }), "grabbing");

	// The button ends it, and only then does the cursor go back to
	// describing the surface under the pointer — empty stage with nothing
	// running, which is the ordinary arrow.
	const done = run(afterKeyUp, [
		{ kind: "pointer-up", snapshot: snap(40), ctxAtUp: gctx(false) },
	]);
	assertEquals(cursor(done, { held: released }), "default");
});

Deno.test("Space released mid-marquee: the cursor returns to the marquee", () => {
	// The mirror case, and the one a keyboard-side answer gets wrong.
	// The press resolved to a marquee, so Space only interrupts it.
	const marquee = run(IDLE, [down(false), moveTo(40)]);
	assertEquals(cursor(marquee), "crosshair");

	// Space down pauses the marquee and pans, so the cursor says pan.
	const held = press(NO_HELD_GESTURES, " ");
	const paused = run(marquee, [{ kind: "space-down" }]);
	assertEquals(cursor(paused, { held }), "grabbing");

	// Space up resumes the marquee. The pan has ended even though the
	// button is still down, so the cursor must stop saying pan.
	const resumed = run(paused, [{ kind: "space-up", pointerHeld: true }]);
	assertEquals(
		cursor(resumed, { held: resolveKeyUp(held, " ") }),
		"crosshair",
	);
});

// ── The rest of the ladder ───────────────────────────────────────

Deno.test("a pan offered is grab; a pan running is grabbing", () => {
	const held = press(NO_HELD_GESTURES, " ");
	// Offered: the key is down and the pointer is over the stage, but no press
	// has resolved to anything yet.
	const hovering = run(IDLE, [moveTo(0)]);
	assertEquals(cursor(hovering, { held }), "grab");
	// Running: the press resolved, and the FSM holds the pan from here.
	assertEquals(cursor(run(IDLE, [down(true)]), { held }), "grabbing");
});

Deno.test("a gesture running outranks a modifier the user is holding", () => {
	// The preview describes what a release would do; the gesture is
	// what is happening, and it already resolved.
	const held = press(press(NO_HELD_GESTURES, " "), "Shift");
	assertEquals(cursor(run(IDLE, [down(true)]), { held }), "grabbing");
});

Deno.test("a preview ends with its key, because it speaks about the key", () => {
	const hovering = run(IDLE, [moveTo(0)]);
	const shift = press(NO_HELD_GESTURES, "Shift");
	assertEquals(cursor(hovering, { held: shift }), "copy");
	assertEquals(cursor(hovering, { held: press(shift, "Alt") }), "no-drop");
	assertEquals(
		cursor(hovering, { held: resolveKeyUp(shift, "Shift") }),
		"default",
	);
});

Deno.test("the Hand tool's own drag reads as a pan", () => {
	// Not a claim at all: the tool grants the affordance, and the FSM
	// resolves the press to the same pan verb.
	const panning = run(IDLE, [{
		kind: "pointer-down",
		surface: "stage-empty",
		snapshot: snap(),
		ctx: { ...gctx(false), activeTool: "hand" },
	}]);
	assertEquals(cursor(panning, { tool: "hand" }), "grabbing");
});

Deno.test("off every surface there is no next click to describe", () => {
	// The pointer leaving the host clears the FSM's hover, and the cursor goes
	// back to the plain arrow rather than keeping the last surface's answer.
	const away = run(run(IDLE, [moveTo(0)]), [{
		kind: "pointer-move",
		snapshot: snap(0),
		hit: null,
	}]);
	assertEquals(cursor(away), "default");
});
