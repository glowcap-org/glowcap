// Every operations capability the page knows, in one voice.
//
// The same capability wears several faces on this surface: the bundle toggle
// that includes it, the short name a notice calls it by, and the value
// modal's ask. Four lists about one fact would drift, so this table is the one they all read, keyed by the `OpsCap` vocabulary the
// store already speaks.

import type { OpsCap } from "../types.ts";
import {
	opsDiagnosticsLabel,
	opsDiagnosticsLead,
	opsDiagnosticsShort,
	opsHowSession,
	opsHowTrace,
	opsIrcLabel,
	opsIrcLead,
	opsIrcShort,
	opsListenersLabel,
	opsListenersLead,
	opsListenersShort,
	opsOperatorLabel,
	opsOperatorLead,
	opsOperatorShort,
	opsPeeringLabel,
	opsPeeringLead,
	opsPeeringShort,
	opsTraceLabel,
	opsTraceLead,
	opsTraceShort,
} from "../../../lib/text/ops.ts";

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
		label: opsListenersLabel,
		toggleId: "opsListenersToggle",
		short: opsListenersShort,
		flag: "--admin-listeners",
		how: opsHowSession,
		lead: opsListenersLead,
	},
	diagnostics: {
		label: opsDiagnosticsLabel,
		toggleId: "opsDiagnosticsToggle",
		short: opsDiagnosticsShort,
		flag: "--diagnostics",
		how: opsHowSession,
		lead: opsDiagnosticsLead,
	},
	irc: {
		label: opsIrcLabel,
		toggleId: "opsIrcToggle",
		short: opsIrcShort,
		flag: "--irc",
		how: opsHowSession,
		lead: opsIrcLead,
	},
	operator: {
		label: opsOperatorLabel,
		toggleId: "opsOperatorToggle",
		short: opsOperatorShort,
		flag: "--operator",
		how: opsHowSession,
		lead: opsOperatorLead,
	},
	peering: {
		label: opsPeeringLabel,
		toggleId: "opsPeeringToggle",
		short: opsPeeringShort,
		flag: "--peering",
		how: opsHowSession,
		lead: opsPeeringLead,
	},
	trace: {
		label: opsTraceLabel,
		toggleId: "opsTraceToggle",
		short: opsTraceShort,
		flag: "--trace",
		how: opsHowTrace,
		lead: opsTraceLead,
	},
};
