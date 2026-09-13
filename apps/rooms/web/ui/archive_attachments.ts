// Pure projection of archived file facts into presentation state.

import type { ArchivedAttachment, ArchiveLine } from "../../lib/archive/protocol.ts";
import type { AttachmentView, Item } from "./types.ts";

import { archivedBytesUnavailable } from "../../lib/text/attached.ts";

export const ARCHIVED_BYTES_UNAVAILABLE = archivedBytesUnavailable;

/** Project durable metadata as an explicitly unavailable attachment. The
 * message keeps its original shape without offering a download that no
 * capability can answer. */
export function archivedAttachmentViews(
	attachments: readonly ArchivedAttachment[],
): Omit<AttachmentView, "id">[] {
	return attachments.map(({ blob, ...attachment }) => ({
		...attachment,
		...(blob == null ? {} : { archiveDigest: blob }),
		lost: true,
		error: ARCHIVED_BYTES_UNAVAILABLE,
	}));
}

/** Whether a drawn line's attachments and an archive record's agree. The one
 * comparison both archive reconciliations (attached session and shared
 * account) run before paying a custody replacement. */
export function archivedAttachmentsMatch(
	item: Extract<Item, { kind: "chat" }>,
	record: ArchiveLine,
): boolean {
	const current = item.attachments ?? [];
	return current.length === record.attachments.length && record.attachments.every((attachment, index) => {
		const existing = current[index];
		return existing != null && existing.name === attachment.name && existing.mime === attachment.mime &&
			existing.size === attachment.size && (existing.width ?? 0) === attachment.width &&
			(existing.height ?? 0) === attachment.height && existing.archiveDigest === (attachment.blob ?? undefined);
	});
}

/** Learn archive content identity without replacing live transfer or display
 * custody. A known conflicting digest is a real replacement; a lost view has
 * no custody to preserve and must likewise be rematerialized if durable bytes
 * later appear. */
export function adoptableArchiveDigests(
	item: Extract<Item, { kind: "chat" }>,
	record: ArchiveLine,
): ReadonlyMap<number, { archiveDigest: string }> | null {
	const current = item.attachments ?? [];
	if (current.length !== record.attachments.length) return null;
	const updates = new Map<number, { archiveDigest: string }>();
	for (const [index, attachment] of record.attachments.entries()) {
		const existing = current[index];
		if (
			existing == null || existing.name !== attachment.name || existing.mime !== attachment.mime ||
			existing.size !== attachment.size || (existing.width ?? 0) !== attachment.width ||
			(existing.height ?? 0) !== attachment.height
		) return null;
		if (existing.archiveDigest != null && existing.archiveDigest !== attachment.blob) return null;
		if (existing.archiveDigest == null && attachment.blob != null) {
			if (existing.lost === true) return null;
			updates.set(existing.id, { archiveDigest: attachment.blob });
		}
	}
	return updates;
}
