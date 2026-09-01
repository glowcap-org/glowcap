// The name over one well on an Operations pane.
//
// Every pane is a stack of these, so the shape lives here once rather than as
// a bare heading each pane spells for itself. Spelled by hand it drifts, and
// the way it drifted was a count: the component hides a zero and one written
// out longhand showed one.

import type { ReactNode } from "react";

/** A section's name over its well, with how many rows are under it. The count
 * is the first thing an operator wants from a page of inventories, and it
 * belongs where the eye already stops.
 *
 * A directory holds as many of these as it has been asked to hold, and the
 * pane reads one page at a time, so the number is what has been read rather
 * than what exists. It says so with a trailing `+` while more remain: a bare
 * "20" over the first page of twenty thousand is the one thing this chip must
 * never say. A count of nothing draws no chip at all: the well under it
 * already says the inventory is empty, and a row of zeros down the page is
 * noise where every one of them is the same word twice. */
export function SectionTitle(
	{ id, count, more = false, children }: { id?: string; count?: number; more?: boolean; children: ReactNode },
) {
	return (
		<h3 className="well-title overline" id={id}>
			{children}
			{count != null && count > 0 && (
				<span className="ops-section-count" title={more ? `${count} read so far, and more remain` : undefined}>
					{count}
					{more ? "+" : ""}
				</span>
			)}
		</h3>
	);
}
