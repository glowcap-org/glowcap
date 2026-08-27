// The directory pane: what this directory holds, and the authority to change
// it.
//
// Two capabilities fill this one address. Inspect lists what the directory
// holds; operator lists the same things as the aggregates it can retire, plus
// the ones inspect never sees. So a tab holding operator is shown the
// operator's inventories alone, because drawing the read-only table beside
// them would be the same rooms twice with only one of the two able to act.
// A tab holding only inspect is shown the table.
//
// The page's own trouble journal belongs to the address rather than to either
// capability, so it stands under whichever half drew.

import type { DiagnosticRow, RoomsOperatorState, TroubleRow } from "../types.ts";
import { DiagnosticsPane } from "./Diagnostics.tsx";
import { OpsLoading } from "./Loading.tsx";
import { OperatorPane } from "./Operator.tsx";

export function DirectoryPane(
	{ operatorHeld, operator, inspectHeld, rows, trouble }: {
		operatorHeld: boolean;
		operator: RoomsOperatorState | null;
		inspectHeld: boolean;
		rows: readonly DiagnosticRow[] | null;
		trouble: readonly TroubleRow[];
	},
) {
	return (
		<>
			{operatorHeld
				? (operator === null ? <OpsLoading what="operator state" /> : <OperatorPane state={operator} />)
				: inspectHeld
				? (rows === null ? <OpsLoading what="what this directory holds" /> : <DiagnosticsPane rows={rows} />)
				: null}
			{
				/* Failures with no reader-facing surface of their own land here
				   instead of dying in the console, newest first, repeats folded
				   into a count. Drawn even when empty, so an operator checking on
				   the page learns "nothing" instead of nothing. */
			}
			<section className="ops-section">
				<h3 className="well-title overline">This page</h3>
				<div className="group well" id="pageTrouble">
					{trouble.length === 0
						? <p className="empty">Nothing has gone wrong on this page.</p>
						: (
							<ul className="ops-trouble">
								{trouble.map((row, at) => (
									<li key={row.source + row.reason + String(at)}>
										<span className="ops-kind">{row.source}</span>
										<span className="ops-note">{row.reason}</span>
										{row.count > 1 && <span className="ops-trouble-count">×{row.count}</span>}
									</li>
								))}
							</ul>
						)}
				</div>
			</section>
		</>
	);
}
