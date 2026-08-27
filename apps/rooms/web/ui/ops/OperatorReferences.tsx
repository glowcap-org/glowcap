// The capability occurrences this server currently holds, grouped by what
// each one is.
//
// Flat, the list was a column of nine repeating words with the interesting
// part — who owns it, which room, which member — pushed to the side. An
// operator arrives asking about a kind ("what is holding lines open?"), so the
// kind is the heading and the row is free to lead with its owner. A kind with
// nothing in it is not drawn at all, which is what keeps this page short on a
// quiet directory and long only where there is something to answer for.
//
// A kind heading is also the way to ask for only that kind, because grouping a
// page of thirty-two rows is not an answer about a directory holding a hundred
// thousand: pressing the kind searches the directory for it, and the section's
// own count then speaks for that kind alone. For the same reason the number
// beside a kind is drawn only while the page holds every matching row; over
// more than a page it would be counting what was sent.

import type { ReactNode } from "react";
import type { OperatorReferenceRow } from "../../../lib/operator.ts";
import { Button } from "../Button.tsx";
import { Said } from "../Said.tsx";
import { type OperatorActs, SectionTitle } from "./operator_acts.tsx";
import { OperatorSweep } from "./OperatorSweep.tsx";

/** Every kind the directory can hold, in the order an operator reads them:
 * what people are in, what they are talking through, then the plumbing that
 * carries names and connections. */
const REFERENCE_KINDS: readonly { kind: OperatorReferenceRow["kind"]; label: string }[] = [
	{ kind: "membership", label: "Room memberships" },
	{ kind: "line", label: "Direct lines" },
	{ kind: "upload", label: "Uploads in flight" },
	{ kind: "foreign-room", label: "Peered rooms" },
	{ kind: "pending-peering", label: "Peerings being set up" },
	{ kind: "registration", label: "Nickname registrations" },
	{ kind: "offered-inbox", label: "Offered inboxes" },
	{ kind: "signaling", label: "Signaling routes" },
	{ kind: "signal-exchange", label: "Signaling exchanges" },
];

export function OperatorReferences(
	{ rows, total, search, onFilter, acts, more }: {
		rows: readonly OperatorReferenceRow[];
		/** How many references the directory holds that match the search. The
		 * rows above are one page of them. */
		total: number;
		search: string;
		/** Ask the directory for one kind alone. */
		onFilter(kind: string): void;
		acts: OperatorActs;
		more: ReactNode;
	},
) {
	return (
		<section className="ops-section" id="operatorReferences">
			<SectionTitle count={total}>Retained references</SectionTitle>
			<div className="group well">
				<p className="hint">
					These are capability occurrences this server currently holds. Releasing one updates its owning
					aggregate here; it does not revoke copies already held by remote peers.
				</p>
				{rows.length === 0
					? <p className="empty">This server holds no independently releasable references.</p>
					: REFERENCE_KINDS.map(({ kind, label }) => {
						const whole = rows.length === total;
						const held = rows.filter((row) => row.kind === kind);
						if (held.length === 0) return null;
						return (
							<div className="ops-kind-group" key={kind} data-kind={kind}>
								<p className="ops-kind-head">
									<Button
										variant="link"
										title={`Search this directory for ${label.toLowerCase()}`}
										onClick={() => onFilter(kind)}
									>
										{label}
									</Button>
									{whole && <span className="ops-kind-count">{held.length}</span>}
								</p>
								<ul className="entries">
									{held.map((row) => {
										const key = `reference:${row.id}`;
										return (
											<li className="entry" key={row.id}>
												<div className="entry-head">
													{
														/* Under a kind's own heading the row leads with what
													    tells it from its siblings — the room it is in, or
													    the member who holds it — rather than repeating the
													    kind in every line. */
													}
													<span className="entry-name">
														{row.room !== ""
															? row.room
															: row.member !== ""
															? row.member
															: row.owner}
													</span>
													{row.room !== "" && row.member !== "" && (
														<span className="entry-meta">
															member <code>{row.member}</code>
														</span>
													)}
													<div className="actions">
														<Button
															variant="quiet"
															disabled={acts.confirming === key}
															onClick={() => acts.ask(key)}
														>
															Release…
														</Button>
													</div>
												</div>
												<p className="hint">{row.detail}</p>
												{acts.confirm(
													key,
													"Only this server's retained occurrence will be released. Remote holders keep their copies and authority.",
													"Release retained reference",
													() => acts.session.releaseOperatorReference(row.id),
												)}
												{acts.why[key] != null && <Said kind="failure">{acts.why[key]}</Said>}
											</li>
										);
									})}
								</ul>
							</div>
						);
					})}
				{more}
				<OperatorSweep
					category="references"
					act="Release"
					past="Released"
					subject="references"
					effect="Only this server's retained occurrences are released; remote holders keep their copies and authority."
					search={search}
					total={total}
				/>
			</div>
		</section>
	);
}
