/**
 * Pointer-machine test fixtures: a snapshot, a gesture context, and
 * a reducer run. Every family below drives the same machine.
 */

import {
	type Effect,
	type GestureContext,
	type Hit,
	NO_MODIFIERS,
	type PointerEvent_,
	type PointerMachineState,
	type PointerSnapshot,
} from "../types.ts";
import { pointerReducer } from "../pointer-machine.ts";

export function snap(opts: Partial<PointerSnapshot> = {}): PointerSnapshot {
	return {
		clientX: 100,
		clientY: 100,
		buttons: 1,
		modifiers: NO_MODIFIERS,
		timestampMs: 1000,
		...opts,
	};
}

export function gctx(
	opts: Partial<GestureContext> & { hit: Hit },
): GestureContext {
	return {
		modifiers: NO_MODIFIERS,
		spaceHeld: false,
		activeTool: "select",
		...opts,
	};
}

export function dispatch(
	state: PointerMachineState,
	events: PointerEvent_[],
): { state: PointerMachineState; effects: Effect[] } {
	let s = state;
	const all: Effect[] = [];
	for (const e of events) {
		const r = pointerReducer(s, e);
		s = r.state;
		all.push(...r.effects);
	}
	return { state: s, effects: all };
}
