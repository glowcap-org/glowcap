/**
 * Canonical render-layer types.
 *
 * Stage.tsx is a React host, so importing types
 * from it pulls in Pixi + React for any consumer that just wants a
 * `StageSelection` shape. This module is the single home for those
 * pure-data types (selection, visibility, the modifier→mode helper)
 * so the renderer, the timeline panels, the inspector,
 * and `app-state.ts` can depend on them without dragging the host in.
 */

import type { EntityRef } from "../interactions/types.ts";

/** A node's role in the messages in flight at the current playhead. Drives
 * the activity mark on the stage and the chip in the Inspector.
 *
 * A node, not a peer: a message on a session whose far end nobody has
 * attributed names that end's stage id, so an unattributed end carries this
 * too. Traffic and identity are separate questions. */
export type PeerActivity = "idle" | "sending" | "receiving" | "both";

/** The part of a message this rule reads. Structural, so the fold below can
 *  live beside the type it produces without this module taking on the
 *  engine's entity types. */
type InFlight = { messageInFlight: { from: string; to: string } };

/**
 * What one message says about the two nodes it names: its source is sending
 * and its destination is receiving. THE statement of the rule, both readers
 * below fold over this rather than spelling it again, so a node's chip in the
 * Inspector cannot disagree with the mark on the node it names.
 */
const ROLES = [
	["from", "sending"],
	["to", "receiving"],
] as const;

/** Add one direction to what a node was already doing. Two of them is
 *  `both`. The same one twice changes nothing. */
function withRole(
	was: PeerActivity | undefined,
	add: "sending" | "receiving",
): PeerActivity {
	if (was === undefined || was === "idle") return add;
	return was === add ? was : "both";
}

/**
 * Every node's activity, from the messages in flight: a message's source is
 * sending and its destination is receiving.
 *
 * Fills and returns `into`, so the per-frame caller owns the buffer. The
 * Inspector asks about one node instead and calls `nodeActivityIn`, which
 * folds by the same rule. One statement of what sending and receiving mean,
 * read two ways, so the chip in the panel cannot disagree with the mark on
 * the node it names.
 */
export function foldActivityByNode(
	messages: Iterable<InFlight>,
	into: Map<string, PeerActivity>,
): Map<string, PeerActivity> {
	into.clear();
	for (const m of messages) {
		for (const [end, role] of ROLES) {
			const id = m.messageInFlight[end];
			into.set(id, withRole(into.get(id), role));
		}
	}
	return into;
}

/** What one node is doing, for a caller that has one node rather than a
 *  frame's worth of them. The same fold, narrowed to the one node it was
 *  asked about, so it needs no map to hold the rest. */
export function nodeActivityIn(
	messages: Iterable<InFlight>,
	nodeId: string,
): PeerActivity {
	let activity: PeerActivity = "idle";
	for (const m of messages) {
		for (const [end, role] of ROLES) {
			if (m.messageInFlight[end] === nodeId) {
				activity = withRole(activity, role);
			}
		}
	}
	return activity;
}

/** How strongly a node, edge, or dot is ringed. "Anchor is a strict subset of
 *  selected". The two booleans collapse into one tier. "anchor" paints the
 *  selected outer ring plus a second inner ring, so under multi-select the
 *  user can see WHICH selected entity the Inspector follows. Single-select is
 *  "anchor" too. The inner ring reads fine when only one thing is selected. */
export type HaloTier = "none" | "selected" | "anchor";

/**
 * What one entity is picked, or nothing.
 *
 * An `EntityRef`, because the four kinds a reader can pick on the stage are the
 * four the rest of the app already names, and this file spelled them out a
 * second time, in a union that had to hold the same four and its own copy of the
 * note about what an endpoint is. `EntityKind` enumerates them, so the alias
 * refuses exactly what the union refused.
 *
 * The name stays, because "the stage's current selection" is worth saying in one
 * word and reads better than `EntityRef | null` at every use.
 */
export type StageSelection = EntityRef | null;

export type StageHover = StageSelection;

/** Per-layer visibility toggled from the left-panel `Layers`
 * segmented control. Applied to each layer's `.visible`. */
export type StageVisibility = {
	peers: boolean;
	connections: boolean;
	messages: boolean;
	labels: boolean;
};

// The selection-gesture grammar (`SelectMode`,
// `selectModeFromModifiers`) lives in the interaction layer, every
// surface speaks it, and is re-exported here for render-local
// importers.
export { type SelectMode, selectModeFromModifiers } from "../interactions/types.ts";
