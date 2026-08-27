/**
 * Pointer state machine — implements § 5 of the interaction model.
 *
 * Pure reducer: `(state, event) → { state, effects }`. The host
 * adapter (use-surface-pointer) attaches DOM listeners, feeds events
 * in, and dispatches the returned effects.
 *
 * Per-host instances: each surface adapter owns its own
 * `PointerMachineState`. By the `setPointerCapture` invariant, at
 * most one host's foreground state is non-idle at any time.
 *
 * The reducer is total — every `(state.fsm, event)` pair has exactly
 * one transition. Asserted by the F3 property test.
 */

import { resolveGesture } from "./gesture-resolver.ts";
import {
	DRAG_THRESHOLD_PX,
	type Effect,
	type FsmForeground,
	type PointerEvent_,
	type PointerMachineState,
	type ResolvedGesture,
} from "./types.ts";

// ─────────────────────── Reducer entrypoint ──────────────────────────

export function pointerReducer(
	state: PointerMachineState,
	event: PointerEvent_,
): { state: PointerMachineState; effects: Effect[] } {
	switch (event.kind) {
		case "pointer-down":
			return onPointerDown(event);
		case "pointer-move":
			return onPointerMove(state, event);
		case "pointer-up":
			return onPointerUp(state, event);
		case "space-down":
			return onSpaceDown(state);
		case "space-up":
			return onSpaceUp(state, event);
		case "cancel":
			return onCancel(state);
		default:
			return assertNever(event);
	}
}

// ─────────────────────── pointer-down ────────────────────────────────

function onPointerDown(
	event: Extract<PointerEvent_, { kind: "pointer-down" }>,
): { state: PointerMachineState; effects: Effect[] } {
	const resolved = resolveGesture(event.ctx);
	return {
		state: {
			fsm: {
				kind: "pressed",
				surface: event.surface,
				resolved,
				start: event.snapshot,
				ctxAtDown: event.ctx,
			},
			hover: { surface: event.surface, hit: event.ctx.hit },
		},
		effects: [],
	};
}

// ─────────────────────── pointer-move ────────────────────────────────

function onPointerMove(
	state: PointerMachineState,
	event: Extract<PointerEvent_, { kind: "pointer-move" }>,
): { state: PointerMachineState; effects: Effect[] } {
	// Hover update is independent of fsm.
	const hover = event.hit ? { surface: event.hit.surface, hit: event.hit } : null;

	switch (state.fsm.kind) {
		case "idle":
			return { state: { ...state, hover }, effects: [] };
		case "pressed": {
			const dx = event.snapshot.clientX - state.fsm.start.clientX;
			const dy = event.snapshot.clientY - state.fsm.start.clientY;
			const overThreshold = Math.hypot(dx, dy) > DRAG_THRESHOLD_PX;
			if (!overThreshold) {
				return { state: { ...state, hover }, effects: [] };
			}
			// Transition to dragging. The drag starts at the press and has ALREADY
			// moved to here, so both are reported: `drag-start` at the origin, then
			// the move that crossed the threshold.
			//
			// Emitting only the start loses this position, and a consumer that tracks
			// the pointer from `drag-move` alone never hears where the drag went. That
			// is invisible while more moves follow, and it is the whole gesture when
			// none do: a browser coalesces pointer moves as it pleases, so a fast
			// flick can cross the threshold and be released with exactly one move
			// between. The marquee then committed the degenerate rect it had painted
			// at the press and selected nothing, and because delivery timing decided
			// it, it read as random. A pan lost its first step the same way.
			//
			// What this holds is that the effects a gesture produces do not depend on
			// how the browser chose to batch it — one big move and two small ones
			// leave the same trail.
			return {
				state: {
					fsm: {
						kind: "dragging",
						surface: state.fsm.surface,
						resolved: state.fsm.resolved,
						start: state.fsm.start,
						current: event.snapshot,
					},
					hover,
				},
				effects: [
					{
						kind: "drag-start",
						verb: state.fsm.resolved,
						at: state.fsm.start,
					},
					{
						kind: "drag-move",
						verb: state.fsm.resolved,
						at: event.snapshot,
					},
				],
			};
		}
		case "dragging":
			return {
				state: {
					fsm: { ...state.fsm, current: event.snapshot },
					hover,
				},
				effects: [{
					kind: "drag-move",
					verb: state.fsm.resolved,
					at: event.snapshot,
				}],
			};
		case "paused-pan": {
			// Pan delta relative to the LAST snapshot (not panOrigin).
			const dx = event.snapshot.clientX - state.fsm.current.clientX;
			const dy = event.snapshot.clientY - state.fsm.current.clientY;
			return {
				state: {
					fsm: { ...state.fsm, current: event.snapshot },
					hover,
				},
				effects: [{
					kind: "pan-step",
					surface: state.fsm.resume.surface,
					delta: { dx, dy },
				}],
			};
		}
		default:
			return assertNever(state.fsm);
	}
}

// ─────────────────────── pointer-up ──────────────────────────────────

function onPointerUp(
	state: PointerMachineState,
	event: Extract<PointerEvent_, { kind: "pointer-up" }>,
): { state: PointerMachineState; effects: Effect[] } {
	switch (state.fsm.kind) {
		case "idle":
			// Spurious up (no down was tracked here). Ignore; keep hover.
			return { state, effects: [] };
		case "pressed": {
			// No-drag release. Re-resolve with ctxAtUp (D); emit click.
			const reResolved = resolveGesture(event.ctxAtUp);
			const fsm: FsmForeground = { kind: "idle" };
			return {
				state: {
					fsm,
					hover: state.hover,
				},
				effects: [{
					kind: "click",
					verb: reResolved,
					hit: event.ctxAtUp.hit,
					at: event.snapshot,
				}],
			};
		}
		case "dragging":
			return {
				state: {
					fsm: { kind: "idle" },
					hover: state.hover,
				},
				effects: [{
					kind: "drag-end",
					verb: state.fsm.resolved,
					at: event.snapshot,
				}],
			};
		case "paused-pan":
			// Pointer-up always commits the drag, regardless of Space
			// still held. Doc § 5.3 fix.
			return {
				state: {
					fsm: { kind: "idle" },
					hover: state.hover,
				},
				effects: [{
					kind: "drag-end",
					verb: state.fsm.resume.resolved,
					at: event.snapshot,
				}],
			};
		default:
			return assertNever(state.fsm);
	}
}

// ─────────────────────── space-down ──────────────────────────────────

function onSpaceDown(
	state: PointerMachineState,
): { state: PointerMachineState; effects: Effect[] } {
	switch (state.fsm.kind) {
		case "idle":
			// Space without active pointer: pan only takes effect on next
			// pointer-down. No state change here.
			return { state, effects: [] };
		case "pressed": {
			// Pause an in-flight press; pan begins on next pointer-move.
			// No drag-pause yet — there was no drag in flight.
			return {
				state: {
					fsm: {
						kind: "paused-pan",
						resume: {
							surface: state.fsm.surface,
							resolved: state.fsm.resolved,
							start: state.fsm.start,
						},
						panOrigin: state.fsm.start,
						current: state.fsm.start,
					},
					hover: state.hover,
				},
				effects: [],
			};
		}
		case "dragging":
			return {
				state: {
					fsm: {
						kind: "paused-pan",
						resume: {
							surface: state.fsm.surface,
							resolved: state.fsm.resolved,
							start: state.fsm.start,
						},
						panOrigin: state.fsm.current,
						current: state.fsm.current,
					},
					hover: state.hover,
				},
				effects: [{
					kind: "drag-pause",
					verb: state.fsm.resolved,
					at: state.fsm.current,
				}],
			};
		case "paused-pan":
			// Already paused; no-op.
			return { state, effects: [] };
		default:
			return assertNever(state.fsm);
	}
}

// ─────────────────────── space-up ────────────────────────────────────

function onSpaceUp(
	state: PointerMachineState,
	event: Extract<PointerEvent_, { kind: "space-up" }>,
): { state: PointerMachineState; effects: Effect[] } {
	if (state.fsm.kind !== "paused-pan") {
		// Space released without an active pause — no-op.
		return { state, effects: [] };
	}
	const paused = state.fsm;
	if (event.pointerHeld) {
		// Resume the drag (Figma-convert). The drag origin "carries"
		// — the current cursor position becomes the new origin so the
		// marquee continues without geometric distortion.
		return {
			state: {
				fsm: {
					kind: "dragging",
					surface: paused.resume.surface,
					resolved: paused.resume.resolved,
					start: paused.current, // new origin = where the cursor is
					current: paused.current,
				},
				hover: state.hover,
			},
			effects: [{
				kind: "drag-resume",
				verb: paused.resume.resolved,
				carriedOrigin: paused.current,
			}],
		};
	}
	// Button was already released — commit the drag as drag-end.
	return {
		state: {
			fsm: { kind: "idle" },
			hover: state.hover,
		},
		effects: [{
			kind: "drag-end",
			verb: paused.resume.resolved,
			at: paused.current,
		}],
	};
}

// ─────────────────────── cancel ──────────────────────────────────────

function onCancel(
	state: PointerMachineState,
): { state: PointerMachineState; effects: Effect[] } {
	switch (state.fsm.kind) {
		case "idle":
		case "pressed":
			// No drag in flight; just return to idle.
			return {
				state: { fsm: { kind: "idle" }, hover: state.hover },
				effects: [],
			};
		case "dragging":
			return {
				state: { fsm: { kind: "idle" }, hover: state.hover },
				effects: [{ kind: "drag-cancel", verb: state.fsm.resolved }],
			};
		case "paused-pan":
			return {
				state: { fsm: { kind: "idle" }, hover: state.hover },
				effects: [{
					kind: "drag-cancel",
					verb: state.fsm.resume.resolved,
				}],
			};
		default:
			return assertNever(state.fsm);
	}
}

// ─────────────────────── in-flight gesture ───────────────────────────

/** A pan, as a resolved gesture. `paused-pan` is Space panning over
 *  a gesture that is waiting, so what is in flight is the pan. */
const PAN_IN_FLIGHT: ResolvedGesture = {
	tier: "space-pan",
	verb: { kind: "pan-surface" },
};

/**
 * What this surface is doing right now, or `null` when it is idle.
 *
 * The FSM is the authority on this, and it is the only layer that
 * can be: what a gesture *is* was decided by `resolveGesture` at the
 * pointer-down, from facts that have since moved on. Releasing Space
 * during a pan leaves a pan running, while releasing it during a
 * marquee that Space interrupted puts the marquee back — the same
 * key event, two outcomes, told apart by what the press resolved to.
 * A reader that re-derives from the live key or pointer state cannot
 * tell those apart and will be wrong about one of them.
 */
export function inFlightGesture(
	state: PointerMachineState,
): ResolvedGesture | null {
	switch (state.fsm.kind) {
		case "idle":
			return null;
		case "pressed":
		case "dragging":
			return state.fsm.resolved;
		case "paused-pan":
			return PAN_IN_FLIGHT;
		default:
			return assertNever(state.fsm);
	}
}

/**
 * Whether this state has anything in flight worth committing.
 *
 * Only a drag does. That is what makes a gesture the reader finished out of the
 * surface's sight worth ending rather than cancelling: a surface hears about such
 * a finish three ways — a pointermove carrying `buttons: 0`, a lost pointer
 * capture, and a `finished` end from the window watch in `gesture-router.ts` —
 * and cancelling them instead is what threw away a marquee's whole selection on a
 * fast drag, because a buttonless move reaches the window while the button is
 * coming up mid-motion, well before the surface's own pointerup arrives.
 *
 * A press that never crossed the threshold holds nothing, and ending it would
 * fire a click at wherever the pointer happened to be when the news arrived,
 * which may be nowhere near what was pressed. A paused pan holds nothing either:
 * a pan is applied as it goes.
 *
 * This is half the question. The other half is whether the reader finished the
 * gesture at all, and that one belongs to the `GestureEndReason` the watch hands
 * over: a `pointercancel` or a window blur is the system taking the gesture back,
 * and it cancels however promising the state looks.
 */
export function hasSomethingToCommit(state: PointerMachineState): boolean {
	return state.fsm.kind === "dragging";
}

// ─────────────────────── helpers ─────────────────────────────────────

function assertNever(x: never): never {
	throw new Error(`unhandled discriminant: ${JSON.stringify(x)}`);
}
