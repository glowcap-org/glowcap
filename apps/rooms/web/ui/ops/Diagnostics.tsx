// What this directory holds, as the inspect capability sees it.
//
// The same inventories the operator pane lists, in the same order and under
// the same names, because they are the same directory and a reader who has
// seen one page should recognize the other. What differs is that nothing here
// acts: inspect is the right to see, and the server never sends it the handle
// an act would take. So this pane has no buttons rather than disabled ones:
// a control a reader cannot ever use is worse than no control, and there is
// no state in which these would become pressable.
//
// The server sends one flat list of `kind, name, note` rows. Grouping is by
// kind alone. Occupants keep a section of their own rather than folding into
// the rooms above them, because the rows carry no link back to their room and
// inventing one by reading the note's prose would make a join out of a
// sentence.

import { useRoomsSession } from "../controller/session.ts";
import type { DiagnosticRow } from "../types.ts";
import { OpsHead } from "./Head.tsx";
import { SectionTitle } from "./Section.tsx";
import {
	inspectBootstrap,
	inspectLead,
	inspectLinks,
	inspectModerators,
	inspectOccupants,
	inspectRegistrations,
	inspectRooms,
	inspectSessions,
	inspectTrouble,
	type OpsInspectSection,
} from "../../../lib/text/ops.ts";

/** One inventory: the kind its rows carry, what the section is called, what
 * holding that kind of thing means, and what an empty one says. The order is
 * the operator pane's, so the two pages read down the same spine.
 *
 * Every inventory draws whether or not it holds anything, for the same reason
 * the operator's does: a section missing from the page reads the same as an
 * inventory this page does not report, and those are different answers. */
const INVENTORIES: readonly ({ kind: string } & OpsInspectSection)[] = [
	{ kind: "link", ...inspectLinks },
	{ kind: "registration", ...inspectRegistrations },
	{ kind: "session", ...inspectSessions },
	{ kind: "room", ...inspectRooms },
	{ kind: "occupant", ...inspectOccupants },
	{ kind: "moderator", ...inspectModerators },
	{ kind: "directory", ...inspectBootstrap },
	{ kind: "trouble", ...inspectTrouble },
];

export function DiagnosticsPane({ rows }: { rows: readonly DiagnosticRow[] }) {
	const session = useRoomsSession();
	const byKind = new Map<string, DiagnosticRow[]>();
	for (const row of rows) {
		const held = byKind.get(row.kind);
		if (held == null) byKind.set(row.kind, [row]);
		else held.push(row);
	}
	// A kind the server grows before this list learns about it still has to
	// appear, or the pane would quietly hold less than the directory does.
	const known = new Set(INVENTORIES.map((one) => one.kind));
	const unnamed = [...byKind.keys()].filter((kind) => !known.has(kind)).sort();

	return (
		<div className="ops-pane">
			<OpsHead refresh={() => session.refreshOpsCap("diagnostics")}>
				{inspectLead}
			</OpsHead>
			{[
				...INVENTORIES,
				...unnamed.map((kind) => ({ kind, title: kind, lead: "", empty: "" })),
			].map(({ kind, title, lead, empty }) => {
				const held = byKind.get(kind) ?? [];
				return (
					<section className="ops-section" key={kind}>
						<SectionTitle count={held.length}>{title}</SectionTitle>
						<div className="group well">
							{lead !== "" && <p className="hint">{lead}</p>}
							{held.length === 0 ? <p className="empty">{empty}</p> : (
								<ul className="entries">
									{held.map((row, at) => (
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
			})}
		</div>
	);
}
