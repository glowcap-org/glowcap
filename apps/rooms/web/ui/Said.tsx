// A refusal or warning that still belongs to the control it answers.
//
// Toasts leave. These stay with the field, the bell, or the meter they describe,
// in the same danger and warning ink the page notices use, so a reader who has
// seen one of those colours already knows what this is.

import type { ReactNode } from "react";

/** Failure stays with a field that would not take the value. Warning stays with
 * a control whose standing condition the reader can still act on. */
export type SaidKind = "failure" | "warning";

export function Said(
	{ kind, id, children }: { kind: SaidKind; id?: string; children?: ReactNode },
) {
	const empty = children == null || children === "";
	return (
		<p id={id} className="said" data-kind={kind} role={empty ? undefined : "alert"}>
			{empty ? "" : children}
		</p>
	);
}
