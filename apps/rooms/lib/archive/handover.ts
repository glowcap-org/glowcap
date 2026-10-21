// Shared vocabulary for archive sharing: the live pipe's kind is not the
// archive filter's record kind.

export const ARCHIVE_SHARE_KINDS = ["direct", "room", "standing"] as const;
export type ArchiveShareKind = (typeof ARCHIVE_SHARE_KINDS)[number];

export function parseArchiveShareKind(raw: unknown): ArchiveShareKind {
	if (raw === "direct" || raw === "room" || raw === "standing") return raw;
	throw new Error("archive share kind must be direct, room, or standing");
}
