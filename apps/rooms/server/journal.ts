// The server's trouble journal: failures with nowhere better to land.
//
// The same rule the page holds (`web/ui/store/trouble.ts`): a console line
// may accompany an operator-facing surface, never replace it. A notify that
// failed after its member was already retired, a session that died, a
// release that would not release — none of those can reach their caller, and
// all of them used to die in the process's stderr. They land here instead,
// bounded, newest first, repeats folded into a count, and ride the inspect
// capability's snapshot as ordinary `trouble` rows.

import type { Ref, Session } from "@pancake/runtime";
import { MAX_TROUBLE_REASON_BYTES, MAX_TROUBLE_SOURCE_BYTES } from "../lib/limits.ts";
import type { OperatorRevision } from "./operator/revision.ts";

/** One filed trouble, folded: a repeat of the newest entry raises its count. */
export interface TroubleEntry {
	readonly source: string;
	readonly reason: string;
	readonly count: number;
}

/** The ring keeps this many distinct troubles; the oldest fall off. */
const TROUBLE_KEPT = 50;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function bounded(value: string, maxBytes: number): string {
	const bytes = encoder.encode(value);
	if (bytes.length <= maxBytes) return value;
	const prefix = decoder.decode(bytes.subarray(0, maxBytes - 3)).replace(/\uFFFD$/u, "");
	return `${prefix}…`;
}

/** One server's diagnostic account. Constructing another server constructs
 * another ring; acknowledging one does not clear the other. */
export class TroubleJournal {
	#ring: TroubleEntry[] = [];

	constructor(readonly operator: OperatorRevision) {}

	/** File one trouble: stderr keeps the full value for whoever is debugging,
	 * and the journal keeps the sentence the inspect capability can serve. */
	note(source: string, error: unknown): void {
		console.error(`rooms: ${source}:`, error);
		source = bounded(source, MAX_TROUBLE_SOURCE_BYTES);
		const reason = bounded(error instanceof Error ? error.message : String(error), MAX_TROUBLE_REASON_BYTES);
		const newest = this.#ring[0];
		if (newest !== undefined && newest.source === source && newest.reason === reason) {
			this.#ring = [{ ...newest, count: newest.count + 1 }, ...this.#ring.slice(1)];
			this.operator.noteChange();
			return;
		}
		this.#ring = [{ source, reason, count: 1 }, ...this.#ring.slice(0, TROUBLE_KEPT - 1)];
		this.operator.noteChange();
	}

	/** The journal, newest first, for the snapshot to serve. */
	rows(): readonly TroubleEntry[] {
		return this.#ring;
	}

	/** Clear this server's diagnostic account. This changes no application or
	 * protocol state; the operator is acknowledging the rows it already read. */
	clear(): void {
		if (this.#ring.length === 0) return;
		this.#ring = [];
		this.operator.noteChange();
	}

	/** Give one capability back on the session it lives on. A refused release
	 * is this journal's diagnostic, not a second process-owned sink. */
	release(session: Session, ref: Ref, what = "retained capability"): void {
		try {
			session.release(ref);
		} catch (error) {
			this.note(`could not release ${what}`, error);
		}
	}
}
