/**
 * Layer interactivity — implements § 7 of the interaction model.
 *
 * Single source of truth for "which Pixi sprite layers accept
 * pointer events right now", driven by `Stage`'s `gestureCtx`.
 *
 * Pure. The truth table in § 7 maps each `(spaceHeld, activeTool)`
 * combination to a `LayerEventModes`. Wheel routing is independent
 * (the `use-surface-wheel` hook listens on host `<div>`s and is
 * unaffected by Pixi sprite event modes).
 */

import type { BuilderTool } from "./types.ts";

/** One of Pixi's `EventMode` values that we actually use. */
export type EventMode = "static" | "none";

export type LayerEventModes = {
	peers: EventMode;
	edges: EventMode;
	messages: EventMode;
};

export function layerInteractivity(ctx: {
	spaceHeld: boolean;
	activeTool: BuilderTool;
}): LayerEventModes {
	// P1 — Space wins. While held, the whole stage is pointer-
	// transparent so the global pan layer receives every event.
	if (ctx.spaceHeld) {
		return { peers: "none", edges: "none", messages: "none" };
	}
	switch (ctx.activeTool) {
		case "hand":
		case "add-peer":
			// Hand pans; Add Peer creates on the empty stage. Both want
			// empty-stage hits, so all entity layers fall silent.
			return { peers: "none", edges: "none", messages: "none" };
		case "open-session":
		case "send-message":
			// Two-click tools target peers ONLY. Edges and messages
			// are pointer-transparent so clicks fall through to peers
			// beneath them.
			return { peers: "static", edges: "none", messages: "none" };
		case "select":
			// Everything live.
			return { peers: "static", edges: "static", messages: "static" };
		default:
			return assertNever(ctx.activeTool);
	}
}

function assertNever(x: never): never {
	throw new Error(`unhandled discriminant: ${JSON.stringify(x)}`);
}
