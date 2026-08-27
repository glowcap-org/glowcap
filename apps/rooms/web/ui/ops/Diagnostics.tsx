// What this directory holds, as the inspect capability sees it: kind, name,
// and the directory's own note about each.
//
// The kinds read as a quiet first column so the names carry the line, and a
// directory holding nothing says so instead of drawing an empty grid. Nothing
// here acts, because inspect cannot: a tab that also holds operator is shown
// the operator's own inventories instead, where every row can be retired.

import { useRoomsSession } from "../controller/session.ts";
import type { DiagnosticRow } from "../types.ts";
import { OpsHead } from "./Head.tsx";

export function DiagnosticsPane({ rows }: { rows: readonly DiagnosticRow[] }) {
	const session = useRoomsSession();
	return (
		<div className="ops-pane">
			<OpsHead refresh={() => session.refreshOpsCap("diagnostics")}>
				What this directory currently holds, as the inspect capability sees it.
			</OpsHead>
			<div className="group well">
				{rows.length === 0
					? <p className="empty">The directory holds nothing right now.</p>
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
										<td className="ops-note">{row.note}</td>
									</tr>
								))}
							</tbody>
						</table>
					)}
			</div>
		</div>
	);
}
