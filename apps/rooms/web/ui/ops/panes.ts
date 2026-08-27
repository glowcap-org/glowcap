// The destinations under /ops, and which capabilities fill each one.
//
// A pane is an address, not a capability. Most are one of each, but the
// directory is two: inspecting what it holds and changing what it holds are
// separately minted authorities over the same subject, and a reader who takes
// the second is not visiting somewhere else. So the pane opens when either is
// held and draws as much as this tab can reach, which is what makes the
// operator capability read as a step up rather than a second page listing the
// same rooms.

import { OPS_CAPS, type OpsCap, type OpsHeld } from "../types.ts";

export interface OpsPaneFace {
	/** The pane's own word: its DOM ids, and the capability the store
	 * remembers when this pane is the one being looked at. */
	id: string;
	/** The address segment under /ops. */
	path: string;
	/** The destination's name in pane navigation. */
	label: string;
	/** Holding any one of these opens the pane. */
	caps: readonly OpsCap[];
}

export const OPS_PANES: readonly OpsPaneFace[] = [
	{ id: "listeners", path: "admin-listeners", label: "Listeners", caps: ["listeners"] },
	{ id: "directory", path: "directory", label: "Directory", caps: ["diagnostics", "operator"] },
	{ id: "irc", path: "irc", label: "IRC", caps: ["irc"] },
	{ id: "peering", path: "peering", label: "Peering", caps: ["peering"] },
	{ id: "viz", path: "viz", label: "Visualizer", caps: ["viz"] },
];

/** The address a capability's own word resolves to. `/ops/diagnostics` and
 * `/ops/operator` were addresses of their own before the directory pane, so
 * they still answer rather than becoming a bookmark that leads nowhere. */
export function paneOf(segment: string): OpsPaneFace | null {
	for (const pane of OPS_PANES) if (pane.path === segment) return pane;
	for (const cap of OPS_CAPS) {
		if (cap !== segment) continue;
		for (const pane of OPS_PANES) if (pane.caps.includes(cap)) return pane;
	}
	return null;
}

/** The pane that draws a capability, for a landing that remembers one. */
export function paneForCap(cap: OpsCap): OpsPaneFace {
	for (const pane of OPS_PANES) if (pane.caps.includes(cap)) return pane;
	throw new Error(`no operations pane draws ${cap}`);
}

/** Every capability of this pane this tab holds, in the pane's own order. */
export function paneCapsHeld(pane: OpsPaneFace, held: OpsHeld): readonly OpsCap[] {
	return pane.caps.filter((cap) => held[cap]);
}
