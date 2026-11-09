// Every operations capability the page knows, in one voice.
//
// The same capability wears several faces on this surface: the bundle toggle
// that includes it, the short name a notice calls it by, and the value
// modal's ask. Four lists about one fact would drift, so this table is the one they all read, keyed by the `OperationsCapability` vocabulary the
// store already speaks.

import { BOOT_CAPS, type OperationsCapability } from "../application_data.ts";
import {
	opsDiagnosticsLabel,
	opsDiagnosticsLead,
	opsDiagnosticsShort,
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
	/** The option that mints it on the server, named in the value modal. */
	flag: string;
	/** What holding the capability does. */
	lead: string;
}

/** The server option that mints one capability, from the name the server's table owns. */
const mintOption = (cap: { readonly name: string }): string => `--capabilities=${cap.name}`;

export const OPS_CATALOG: Record<OperationsCapability, OpsCapFace> = {
	listeners: {
		label: opsListenersLabel,
		toggleId: "opsListenersToggle",
		short: opsListenersShort,
		flag: mintOption(BOOT_CAPS.adminListeners),
		lead: opsListenersLead,
	},
	diagnostics: {
		label: opsDiagnosticsLabel,
		toggleId: "opsDiagnosticsToggle",
		short: opsDiagnosticsShort,
		flag: mintOption(BOOT_CAPS.diagnostics),
		lead: opsDiagnosticsLead,
	},
	irc: {
		label: opsIrcLabel,
		toggleId: "opsIrcToggle",
		short: opsIrcShort,
		flag: mintOption(BOOT_CAPS.irc),
		lead: opsIrcLead,
	},
	operator: {
		label: opsOperatorLabel,
		toggleId: "opsOperatorToggle",
		short: opsOperatorShort,
		flag: mintOption(BOOT_CAPS.operator),
		lead: opsOperatorLead,
	},
	peering: {
		label: opsPeeringLabel,
		toggleId: "opsPeeringToggle",
		short: opsPeeringShort,
		flag: mintOption(BOOT_CAPS.peering),
		lead: opsPeeringLead,
	},
	trace: {
		label: opsTraceLabel,
		toggleId: "opsTraceToggle",
		short: opsTraceShort,
		flag: mintOption(BOOT_CAPS.trace),
		lead: opsTraceLead,
	},
};
