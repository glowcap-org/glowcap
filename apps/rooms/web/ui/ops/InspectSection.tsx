// One inventory as the inspect capability sees it: a titled section listing
// `name` and `note` rows with nothing to press. The Diagnostics page draws one
// per kind, and the operator page draws the work budgets with it, the one
// inventory the operator's own rows do not hold.

import type { DiagnosticRow } from "../../../lib/room/client.ts";
import type { OpsInspectSection } from "../../../lib/text/ops.ts";
import { SectionTitle } from "./Section.tsx";

export function InspectSection(
	{ id, title, lead, empty, rows }: OpsInspectSection & { id?: string; rows: readonly DiagnosticRow[] },
) {
	return (
		<section className="ops-section" id={id}>
			<SectionTitle count={rows.length}>{title}</SectionTitle>
			<div className="group well">
				{lead !== "" && <p className="hint">{lead}</p>}
				{rows.length === 0 ? <p className="empty">{empty}</p> : (
					<ul className="entries">
						{rows.map((row, at) => (
							<li className="entry" key={row.name + String(at)}>
								<div className="entry-head">
									<span className="entry-name">{row.name}</span>
								</div>
								{row.note !== "" && <p className="entry-meta">{row.note}</p>}
							</li>
						))}
					</ul>
				)}
			</div>
		</section>
	);
}
