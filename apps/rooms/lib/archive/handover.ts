// Shared vocabulary for archive sharing: the live pipe's kind is not the
// archive filter's record kind.

import { ALL_ARCHIVE_RECORDS, type ArchiveFilter } from "./scope.ts";

export const ARCHIVE_SHARE_KINDS = ["direct", "room", "standing"] as const;
export type ArchiveShareKind = (typeof ARCHIVE_SHARE_KINDS)[number];

export function parseArchiveShareKind(raw: unknown): ArchiveShareKind {
	if (raw === "direct" || raw === "room" || raw === "standing") return raw;
	throw new Error("archive share kind must be direct, room, or standing");
}

/** Archive conversation identity for one live conversation. Held rooms and every
 * direct line key on persistId; a public room keys on its lowercase name. */
export function archiveConversationIdentity(conversation: {
	readonly type: "room" | "dm";
	readonly persistId: string;
	readonly id: string;
	readonly held?: boolean;
}): string {
	return conversation.type === "dm" || conversation.held === true
		? conversation.persistId
		: conversation.id.toLowerCase();
}

export function archiveShareFilter(
	kind: ArchiveShareKind,
	directory: string,
	conversation: string | null,
): ArchiveFilter {
	if (kind === "standing") {
		return {
			...ALL_ARCHIVE_RECORDS,
			kind: "standing",
			directory,
			conversation,
		};
	}
	if (conversation == null) throw new Error("a line archive share needs a conversation");
	return {
		...ALL_ARCHIVE_RECORDS,
		kind: "line",
		conversationKind: kind,
		directory,
		conversation,
	};
}
