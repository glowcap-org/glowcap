// One archived line keeps the time and conversation order with which it first
// entered its recorder. Edits, refiles, and withdrawals replace content at the
// same coordinates; they do not move the message through history.

import type { ArchiveLine } from "./protocol.ts";

export function preserveArchiveLineChronology(prior: ArchiveLine | null, next: ArchiveLine): ArchiveLine {
	return prior == null || prior.at === next.at && prior.order === next.order
		? next
		: { ...next, at: prior.at, order: prior.order };
}
