// Pure projection of archived file facts into presentation state.

import type { ArchivedAttachment } from "../../lib/archive.ts";
import type { AttachmentView } from "./types.ts";

export const ARCHIVED_BYTES_UNAVAILABLE = "These archived file bytes are not available in this view.";

/** Project durable metadata as an explicitly unavailable attachment. The
 * message keeps its original shape without offering a download that no
 * capability can answer. */
export function archivedAttachmentViews(
	attachments: readonly ArchivedAttachment[],
): Omit<AttachmentView, "id">[] {
	return attachments.map(({ blob: _blob, ...attachment }) => ({
		...attachment,
		lost: true,
		error: ARCHIVED_BYTES_UNAVAILABLE,
	}));
}
