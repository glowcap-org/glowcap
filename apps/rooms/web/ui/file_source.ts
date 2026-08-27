// A browser File projected onto the transport-neutral attachment source seam.

import type { AttachmentSource } from "../../lib/attachment.ts";

export function pickedSource(file: File): AttachmentSource {
	return {
		name: file.name,
		mime: file.type || "application/octet-stream",
		size: file.size,
		read: async (offset: number, length: number) =>
			new Uint8Array(await file.slice(offset, offset + length).arrayBuffer()),
	};
}
