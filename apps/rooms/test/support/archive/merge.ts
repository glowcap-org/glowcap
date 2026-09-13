// Coalescing several archive accounts into one reader's view (ADR-0144).
//
// A member can hold more than one archive at once: this browser's store beside
// a selected archive peer, or the durable session's local backend beside its
// held peer. Writes are exclusive — one recorder target at a time, never a
// fallback — so a line written before a selection change and its edit after it
// can live in different archives under the same coordinates. Reading is the
// combined view: every held account answers, and this module decides what one
// coordinate key shows.
//
// The rule, in order:
//
// 1. Identity is the record's coordinates (`archiveRecordKey`). Two accounts
//    reporting one key are one account stored twice, never two records. The
//    key is never rewritten and no record leaves its source.
// 2. Lifecycle state ranks: a withdrawal outranks an edit, an edit outranks a
//    plain present record. The lifecycle is monotone, so the higher state is
//    never the stale one.
// 3. A remaining tie means two archives hold the same state with possibly
//    different content, and nothing local can say which revision is newer.
//    The account currently selected for writes wins: it received the member's
//    most recent intent, which is the best available evidence of recency.
//    With no write target in the set, the first-listed account wins, so the
//    answer stays deterministic.
//
// What this never does: merge two recorder sources into one account, treat an
// absent key as a deletion (an archive's eviction is not a withdrawal), or
// mistake any of it for live traffic — attribution is the caller's rendering
// of the keeper each winner carries.

import { archiveRecordKey } from "../../../lib/archive/index.ts";
import type { ArchiveRecord } from "../../../lib/archive/protocol.ts";

/** One archive authority's current account: who keeps it, whether the member
 * writes to it now, and the records it currently reports. `K` is the caller's
 * account identity — an attribution label, a custody handle — carried through
 * to each winner so the caller never maps back from a string. */
export interface ArchiveAccount<K> {
	readonly keeper: K;
	/** True when this account is the member's current recorder. Its most recent
	 * intent lives here, so it wins a tie nothing else can settle. */
	readonly writes: boolean;
	readonly records: readonly ArchiveRecord[];
}

/** One winning record and the account identity that supplied it. */
export interface KeptArchiveRecord<K> {
	readonly keeper: K;
	readonly record: ArchiveRecord;
}

function lifecycleRank(record: ArchiveRecord): number {
	if (record.kind !== "line") return 0;
	switch (record.state) {
		case "withdrawn":
			return 2;
		case "edited":
			return 1;
		case "present":
			return 0;
	}
}

/** Coalesce every account's records: one winner per coordinate key, carrying
 * the keeper that supplied it. Keys appear in first-seen order across the
 * accounts as listed; ordering within a conversation is the caller's, since
 * only it knows the presentation. */
export function mergeArchiveAccounts<K>(accounts: readonly ArchiveAccount<K>[]): KeptArchiveRecord<K>[] {
	// The write target outranks every read-only account; read-only accounts
	// keep their listed order, so the caller names the preference.
	const preferences = accounts.map((account, index) => account.writes ? -1 : index);
	const winners = new Map<string, KeptArchiveRecord<K> & { rank: number; preference: number }>();
	accounts.forEach((account, index) => {
		const preference = preferences[index];
		for (const record of account.records) {
			const key = archiveRecordKey(record);
			const rank = lifecycleRank(record);
			const held = winners.get(key);
			if (held === undefined || rank > held.rank || (rank === held.rank && preference < held.preference)) {
				winners.set(key, { keeper: account.keeper, record, rank, preference });
			}
		}
	});
	return [...winners.values()].map(({ keeper, record }) => ({ keeper, record }));
}
