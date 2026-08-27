// Monotonic scope for member archive facets.
//
// Every dimension is exact-match. Null grants the whole dimension; narrowing
// replaces null with a value and can never replace a value with another one.

export type ArchiveConversationKind = "room" | "direct";

export interface ArchiveFilter {
	readonly source: string | null;
	readonly generation: string | null;
	readonly kind: "standing" | "line" | null;
	readonly conversationKind: ArchiveConversationKind | null;
	readonly directory: string | null;
	readonly conversation: string | null;
}

export const ALL_ARCHIVE_RECORDS: ArchiveFilter = {
	source: null,
	generation: null,
	kind: null,
	conversationKind: null,
	directory: null,
	conversation: null,
};

export type ArchiveAccess = "read" | "read-write";

export type ArchiveScopedRecord =
	& {
		readonly source: string;
		readonly generation: string;
		readonly directory: string;
	}
	& (
		| { readonly kind: "standing"; readonly room: string }
		| {
			readonly kind: "line";
			readonly conversationKind: ArchiveConversationKind;
			readonly conversation: string;
		}
	);

export function archiveMatches(record: ArchiveScopedRecord, filter: ArchiveFilter): boolean {
	return (filter.source === null || record.source === filter.source) &&
		(filter.generation === null || record.generation === filter.generation) &&
		(filter.kind === null || record.kind === filter.kind) &&
		(filter.conversationKind === null ||
			(record.kind === "line" && record.conversationKind === filter.conversationKind)) &&
		(filter.directory === null || record.directory === filter.directory) &&
		(filter.conversation === null ||
			(record.kind === "line" ? record.conversation : record.room) === filter.conversation);
}

function intersectValue<T>(held: T | null, asked: T | null): T | null | undefined {
	if (held === null) return asked;
	if (asked === null || asked === held) return held;
	return undefined;
}

/** Intersect two exact scopes. Null means they have no common record. */
export function intersectArchiveFilters(held: ArchiveFilter, asked: ArchiveFilter): ArchiveFilter | null {
	const source = intersectValue(held.source, asked.source);
	const generation = intersectValue(held.generation, asked.generation);
	const kind = intersectValue(held.kind, asked.kind);
	const conversationKind = intersectValue(held.conversationKind, asked.conversationKind);
	const directory = intersectValue(held.directory, asked.directory);
	const conversation = intersectValue(held.conversation, asked.conversation);
	if (
		source === undefined || generation === undefined || kind === undefined ||
		conversationKind === undefined || directory === undefined || conversation === undefined
	) return null;
	// A standing has no conversation kind, so this exact intersection is empty.
	if (kind === "standing" && conversationKind !== null) return null;
	return { source, generation, kind, conversationKind, directory, conversation };
}
