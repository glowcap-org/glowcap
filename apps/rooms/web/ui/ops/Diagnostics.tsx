// The diagnostics pane of the Operations modal, drawn only while this tab
// holds the inspect capability (the Advanced toggle is how it is taken).
//
// One well holding what the directory currently holds, as inspect sees it:
// kind, name, and the directory's own note about each. The kinds read as a
// quiet first column so the names carry the line, and a directory holding
// nothing says so instead of drawing an empty grid.

import { usePeer } from "../peer.ts";
import type { DiagnosticRow } from "../types.ts";
import { OpsHead } from "./Head.tsx";

export function DiagnosticsPane({ rows }: { rows: readonly DiagnosticRow[] | null }) {
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
		</div>
	);
}
