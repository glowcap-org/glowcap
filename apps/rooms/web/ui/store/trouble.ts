// The page's trouble journal: failures with nowhere better to land.
//
// The rule this enforces: a console line may accompany a reader-facing
// surface, never replace it. A cleanup that fails, a lease that will not
// release, a publisher that errors between status changes, none of those
// warrant a toast, and none should die in the console. They land
// here instead, bounded, deduplicated against the newest entry, and drawn by
// the operations page's diagnostics pane.

import type { PageProjection } from "./core.ts";

/** The ring keeps this many distinct troubles. The oldest fall off. */
const TROUBLE_KEPT = 50;

/** File one trouble. A repeat of the newest entry folds into its count, so a
 * failure loop reads as one line with a number instead of a full ring. */
export function noteTrouble(projection: PageProjection, source: string, reason: string): void {
	const rows = projection.get().trouble;
	const newest = rows[0];
	if (newest !== undefined && newest.source === source && newest.reason === reason) {
		projection.set({ trouble: [{ ...newest, count: newest.count + 1 }, ...rows.slice(1)] });
		return;
	}
	projection.set({ trouble: [{ source, reason, count: 1 }, ...rows.slice(0, TROUBLE_KEPT - 1)] });
}
