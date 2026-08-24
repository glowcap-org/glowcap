// The server's trouble journal: failures with nowhere better to land.
//
// The same rule the page holds (`web/ui/store/trouble.ts`): a console line
// may accompany an operator-facing surface, never replace it. A notify that
// failed after its member was already retired, a session that died, a
// release that would not release — none of those can reach their caller, and
// all of them used to die in the process's stderr. They land here instead,
// bounded, newest first, repeats folded into a count, and ride the inspect
// capability's snapshot as ordinary `trouble` rows.

/** One filed trouble, folded: a repeat of the newest entry raises its count. */
export interface TroubleEntry {
	readonly source: string;
	readonly reason: string;
	readonly count: number;
}

/** The ring keeps this many distinct troubles; the oldest fall off. */
const TROUBLE_KEPT = 50;

let ring: TroubleEntry[] = [];

/** File one trouble: stderr keeps the full value for whoever is debugging,
 * and the journal keeps the sentence the inspect capability can serve. */
export function noteTrouble(source: string, error: unknown): void {
	console.error(`rooms: ${source}:`, error);
	const reason = error instanceof Error ? error.message : String(error);
	const newest = ring[0];
	if (newest !== undefined && newest.source === source && newest.reason === reason) {
		ring = [{ ...newest, count: newest.count + 1 }, ...ring.slice(1)];
		return;
	}
	ring = [{ source, reason, count: 1 }, ...ring.slice(0, TROUBLE_KEPT - 1)];
}

/** The journal, newest first, for the snapshot to serve. */
export function troubleRows(): readonly TroubleEntry[] {
	return ring;
}
