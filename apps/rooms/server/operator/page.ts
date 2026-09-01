// Reading one page of an inventory that may be very large.
//
// An operator arrives at a directory holding a few rows or a few hundred
// thousand, and the page it reads is the same size either way. Two things
// follow. A search has to happen here rather than in the browser, because the
// browser has one page and the answer may be in the next three thousand. And
// the count beside a section has to be the number of rows that match, not the
// number that were sent, or every number on the page is a lie about the
// directory.
//
// So an inventory offers rows as sources rather than as rows: the text a
// search matches, which every row pays, and the work of building the row,
// which only a row on the asked-for page pays. Counting a hundred thousand
// matches then costs a hundred thousand string tests, while building costs
// one page.

/** One row an inventory can offer. `text` is already lowercased, because the
 * query is lowercased once and a per-row `toLowerCase()` over a large
 * inventory is the whole cost of the scan. */
export interface OperatorRowSource<T> {
	/** Stable row identity when the inventory has one. */
	readonly id?: string;
	readonly text: string;
	/** Allocation-free field matching for hot inventories. Falls back to
	 * `text` where a category is small enough to precompose it. */
	readonly matches?: (words: readonly string[]) => boolean;
	build(): T;
	/** Borrowed direct act for a row already selected by this scan. */
	readonly retire?: () => boolean;
	/** Whether the owner still holds this cached row after an in-place sweep. */
	readonly active?: () => boolean;
	/** Exact structured subtype, when an inventory has one. */
	readonly kind?: string;
}

export interface OperatorRowPage<T> {
	readonly rows: T[];
	/** Whether rows matching the query stand after this page. */
	readonly more: boolean;
	/** Every row matching the query, whether or not it is on this page. */
	readonly total: number;
}

/** The searchable text of a row, lowercased once. */
export function searchText(...parts: readonly (string | number | null | undefined)[]): string {
	return parts.filter((part) => part != null && part !== "").join(" ").toLowerCase();
}

/** Whether a source matches every word of the query, in any order and in any
 * field. Words rather than the whole string, so "alice lobby" finds Alice's
 * membership of the lobby without the operator guessing which field comes
 * first in a row they have never seen. */
export function matchesQuery(text: string, words: readonly string[]): boolean {
	for (const word of words) if (!text.includes(word)) return false;
	return true;
}

export function sourceMatches<T>(source: OperatorRowSource<T>, words: readonly string[]): boolean {
	return source.matches?.(words) ?? matchesQuery(source.text, words);
}

/** The query as the words a row has to carry, empty when nothing was asked. */
export function queryWords(query: string): readonly string[] {
	return query.trim().toLowerCase().split(/\s+/).filter((word) => word !== "");
}

export function queryPage<T>(
	sources: Iterable<OperatorRowSource<T>>,
	query: string,
	offset: number,
	limit: number,
): OperatorRowPage<T> {
	const words = queryWords(query);
	const rows: T[] = [];
	let total = 0;
	for (const source of sources) {
		if (words.length > 0 && !sourceMatches(source, words)) continue;
		if (total >= offset && rows.length < limit) rows.push(source.build());
		total += 1;
	}
	return { rows, more: offset + rows.length < total, total };
}

/** The rows a bulk act should touch: every match, in inventory order, bounded
 * so one call cannot hold the turn for an unbounded time. The caller runs
 * again for what remains, which is also what lets an operator stop. */
export function queryBatch<T>(
	sources: Iterable<OperatorRowSource<T>>,
	query: string,
	limit: number,
): { rows: T[]; total: number } {
	const words = queryWords(query);
	const rows: T[] = [];
	let total = 0;
	for (const source of sources) {
		if (words.length > 0 && !sourceMatches(source, words)) continue;
		total += 1;
		if (rows.length < limit) rows.push(source.build());
	}
	return { rows, total };
}
