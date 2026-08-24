// The diagnostics pane of the Operations page, drawn only while this tab
// holds the inspect capability (the Capabilities toggle is how it is taken).
//
// One well holding what the directory currently holds, as inspect sees it:
// kind, name, and the directory's own note about each. The kinds read as a
// quiet first column so the names carry the line, and a directory holding
// nothing says so instead of drawing an empty grid.

import { usePeer } from "../peer.ts";
import type { DiagnosticRow, TroubleRow } from "../types.ts";
import { OpsHead } from "./Head.tsx";

export function DiagnosticsPane(
	{ rows, trouble }: { rows: readonly DiagnosticRow[] | null; trouble: readonly TroubleRow[] },
) {
	const peer = usePeer();

	// The modal draws one pane per held capability; see the listeners pane.
	if (rows === null) return null;

	return (
		<div className="ops-pane">
			<OpsHead refresh={() => peer.refreshOpsCap("diagnostics")}>
				What this directory currently holds, as the inspect capability sees it.
			</OpsHead>
			<div className="group well">
				{rows.length === 0
					? <p className="ops-empty">The directory holds nothing right now.</p>
					: (
						<table className="ops-table">
							<thead>
								<tr>
									<th>Kind</th>
									<th>Name</th>
									<th>On this directory</th>
								</tr>
							</thead>
							<tbody>
								{rows.map((row, at) => (
									<tr key={row.kind + row.name + String(at)}>
										<td className="ops-kind">{row.kind}</td>
										<td>{row.name}</td>
										<td className="ops-note">
											{row.kind === "link"
												? (
													<>
														<span className="ops-kicker">Swiss number</span>
														<code>{row.note}</code>
													</>
												)
												: row.note}
										</td>
									</tr>
								))}
							</tbody>
						</table>
					)}
			</div>
			{
				/* The page's own trouble journal, beside the directory's holdings:
				   failures with no reader-facing surface of their own land here
				   instead of dying in the console, newest first, repeats folded
				   into a count. Drawn even when empty, so an operator checking on
				   the page learns "nothing" instead of nothing. */
			}
			<p className="well-title overline">This page</p>
			<div className="group well" id="pageTrouble">
				{trouble.length === 0
					? <p className="ops-empty">Nothing has gone wrong on this page.</p>
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
		</div>
	);
}
