// The server's trouble journal: failures with nowhere better to land.
//
// The same rule the page holds (`web/ui/store/trouble.ts`): a console line
// may accompany an operator-facing surface, never replace it. A notify that
// failed after its member was already retired, a session that died, a
// release that would not release — none of those can reach their caller, and
// all of them used to die in the process's stderr. They land here instead,
// bounded, newest first, repeats folded into a count, and ride the inspect
// capability's snapshot as ordinary `trouble` rows.

import { noteOperatorChange } from "./operator/revision.ts";
import { MAX_TROUBLE_REASON_BYTES, MAX_TROUBLE_SOURCE_BYTES } from "../lib/limits.ts";

/** One filed trouble, folded: a repeat of the newest entry raises its count. */
export interface TroubleEntry {
	readonly source: string;
	readonly reason: string;
	readonly count: number;
}

/** The ring keeps this many distinct troubles; the oldest fall off. */
const TROUBLE_KEPT = 50;

let ring: TroubleEntry[] = [];
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function bounded(value: string, maxBytes: number): string {
	const bytes = encoder.encode(value);
	if (bytes.length <= maxBytes) return value;
	const prefix = decoder.decode(bytes.subarray(0, maxBytes - 3)).replace(/\uFFFD$/u, "");
	return `${prefix}…`;
}

/** File one trouble: stderr keeps the full value for whoever is debugging,
 * and the journal keeps the sentence the inspect capability can serve. */
export function noteTrouble(source: string, error: unknown): void {
	console.error(`rooms: ${source}:`, error);
	source = bounded(source, MAX_TROUBLE_SOURCE_BYTES);
	const reason = bounded(error instanceof Error ? error.message : String(error), MAX_TROUBLE_REASON_BYTES);
	const newest = ring[0];
	if (newest !== undefined && newest.source === source && newest.reason === reason) {
		ring = [{ ...newest, count: newest.count + 1 }, ...ring.slice(1)];
		noteOperatorChange();
		return;
	}
	ring = [{ source, reason, count: 1 }, ...ring.slice(0, TROUBLE_KEPT - 1)];
	noteOperatorChange();
}

/** The journal, newest first, for the snapshot to serve. */
export function troubleRows(): readonly TroubleEntry[] {
	return ring;
}

/** Clear the process-owned diagnostic account. This changes no application or
 * protocol state; the operator is acknowledging the rows it already read. */
export function clearTrouble(): void {
	if (ring.length === 0) return;
	ring = [];
	noteOperatorChange();
}
