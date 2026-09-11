// A browser File projected onto the transport-neutral attachment source seam.

import type { AttachmentSource } from "../../lib/attachment.ts";

/** One browser file as the shared attachment layer reads it. The description
 * is also validated before Send clears the composer, so refusal preserves the
 * reader's draft and attached chips. */
export async function pickedSource(file: File): Promise<AttachmentSource> {
	const mime = file.type || "application/octet-stream";
	let dimensions: { width?: number; height?: number } = {};
	if (mime.startsWith("image/")) {
		try {
			const bitmap = await createImageBitmap(file);
			try {
				dimensions = { width: bitmap.width, height: bitmap.height };
			} finally {
				bitmap.close();
			}
		} catch { /* Unsupported images still have ordinary downloadable bytes. */ }
	}
	return {
		...dimensions,
		name: file.name,
		mime,
		size: file.size,
		read: async (offset: number, length: number) =>
			new Uint8Array(await file.slice(offset, offset + length).arrayBuffer()),
	};
}
