// A browser File projected onto the transport-neutral attachment source seam.

import type { AttachmentSource } from "../../lib/attachment.ts";

/** One browser file as the shared attachment layer reads it. The description
 * is also validated before Send clears the composer, so refusal preserves the
 * reader's draft and attached chips. */
export function pickedSource(file: File): AttachmentSource {
	return {
		name: file.name,
		mime: file.type || "application/octet-stream",
		size: file.size,
		read: async (offset: number, length: number) =>
			new Uint8Array(await file.slice(offset, offset + length).arrayBuffer()),
	};
}
