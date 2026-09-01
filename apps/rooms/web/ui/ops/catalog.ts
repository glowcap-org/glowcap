// Every operations capability the page knows, in one voice.
//
// The same capability wears several faces on this surface: the bundle toggle
// that includes it, the short name a notice calls it by, and the value
// modal's ask. Each used to keep its own list, and four lists about one fact drift;
// this table is the one they all read, keyed by the `OpsCap` vocabulary the
// store already speaks.

import type { OpsCap } from "../types.ts";

export interface OpsCapFace {
	/** The capability-set toggle's row label and value-modal title. */
	label: string;
	/** The toggle's DOM id, which the browser proofs press. */
	toggleId: string;
	/** The capability's short name, as a toast about losing it says it. */
	short: string;
	/** The knob that mints it on the server, named in the value modal. */
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
		short: "Listeners",
		flag: "--admin-listeners",
		how: "Paste it here to fetch the capability on this directory's session.",
		lead: "Holding it lists this server's live listeners and brings them up or down.",
	},
	diagnostics: {
		label: "Inspect this directory",
		toggleId: "opsDiagnosticsToggle",
		short: "Inspect",
		flag: "--diagnostics",
		how: "Paste it here to fetch the capability on this directory's session.",
		lead: "Holding it lists what this directory currently holds.",
	},
	irc: {
		label: "IRC gateway",
		toggleId: "opsIrcToggle",
		short: "IRC",
		flag: "--irc",
		how: "Paste it here to fetch the capability on this directory's session.",
		lead: "Holding it bridges IRC channels into this directory as ordinary rooms.",
	},
	operator: {
		label: "Rooms operator",
		toggleId: "opsOperatorToggle",
		short: "Operator",
		flag: "--operator",
		how: "Paste it here to fetch the capability on this directory's session.",
		lead: "Holding it inventories and changes this directory's issued authorities, names, and live sessions.",
	},
	peering: {
		label: "Directory peering",
		toggleId: "opsPeeringToggle",
		short: "Peering",
		flag: "--peering",
		how: "Paste it here to fetch the capability on this directory's session.",
		lead: "Holding it lists a durable room from another directory here for this directory connection.",
	},
	viz: {
		label: "Protocol visualizer",
		toggleId: "opsVizToggle",
		short: "Visualizer",
		flag: "--viz",
		how: "Paste it here to present it to the live timeline endpoint.",
		lead: "Holding it publishes this session's connections, direct messages included, to the timeline.",
	},
};
