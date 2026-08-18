// Every operations capability the page knows, in one voice.
//
// The same capability wears several faces on this surface: the Advanced
// toggle that takes it, the tab that names its pane, and the take modal's
// ask. Each used to keep its own list, and four lists about one fact drift;
// this table is the one they all read, keyed by the `OpsCap` vocabulary the
// store already speaks.

import type { OpsCap } from "../types.ts";

export interface OpsCapFace {
	/** The Advanced toggle's row label, and the take modal's title. */
	label: string;
	/** The toggle's DOM id, which the browser proofs press. */
	toggleId: string;
	/** The pane's name in the Operations tab bar. */
	pane: string;
	/** The knob that mints it on the server, named in the take modal's ask. */
	flag: string;
	/** How the pasted swiss is redeemed. */
	how: string;
	/** What holding the capability does. */
	lead: string;
}

export const OPS_CATALOG: Record<OpsCap, OpsCapFace> = {
	listeners: {
		label: "Administer listeners",
		toggleId: "opsListenersToggle",
		pane: "Listeners",
		flag: "--admin-listeners",
		how: "Paste it here to fetch the capability on this directory's session.",
		lead: "Holding it lists this server's live listeners and brings them up or down.",
	},
	diagnostics: {
		label: "Inspect this directory",
		toggleId: "opsDiagnosticsToggle",
		pane: "Diagnostics",
		flag: "--diagnostics",
		how: "Paste it here to fetch the capability on this directory's session.",
		lead: "Holding it lists what this directory currently holds.",
	},
	viz: {
		label: "Protocol visualizer",
		toggleId: "opsVizToggle",
		pane: "Visualizer",
		flag: "--viz",
		how: "Paste it here to present it to the live timeline endpoint.",
		lead: "Holding it publishes this tab's own sessions, direct messages included, to the timeline.",
	},
};
