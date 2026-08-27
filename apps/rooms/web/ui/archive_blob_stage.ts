// Browser-only staging for archive blob transactions.

import type { ArchiveLine, ArchiveRecord } from "../../lib/archive.ts";
import type { ArchiveAttachmentAddress, ArchivedAttachmentSource } from "../../lib/archive_blobs.ts";
import { BLOB_CHUNK } from "../../lib/limits.ts";

export function archiveCoordinatesKey(record: ArchiveRecord | Omit<ArchiveAttachmentAddress, "index">): string {
	return "conversationKind" in record
		? JSON.stringify([
			record.source,
			record.generation,
			record.id,
			"line",
			record.conversationKind,
			record.directory,
			record.conversation,
		])
		: JSON.stringify([record.source, record.generation, record.id, "standing", record.directory, record.room]);
}

export interface StagedBrowserBlob {
	index: number;
	digest: string;
	size: number;
	bytes: Blob;
}

export async function stageBrowserBlob(
	source: ArchivedAttachmentSource,
	index: number,
): Promise<StagedBrowserBlob> {
	const chunks: Uint8Array<ArrayBuffer>[] = [];
	for (let offset = 0; offset < source.size; offset += BLOB_CHUNK) {
		const length = Math.min(BLOB_CHUNK, source.size - offset);
		const chunk = await source.read(offset, length);
		if (!(chunk instanceof Uint8Array) || chunk.length !== length) {
			throw new Error(`archive attachment source answered ${chunk?.length ?? 0} of ${length} requested bytes`);
		}
		const owned = new Uint8Array(length);
		owned.set(chunk);
		chunks.push(owned);
	}
	const bytes = new Blob(chunks.map((chunk) => chunk.buffer), { type: source.mime });
	const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", await bytes.arrayBuffer()));
	return {
		index,
		digest: [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join(""),
		size: source.size,
		bytes,
	};
}

export function sourcesFromStaged(
	record: ArchiveLine,
	staged: readonly StagedBrowserBlob[],
): ArchivedAttachmentSource[] {
	return staged.map((stagedBlob) => {
		let loaded: Promise<Uint8Array> | null = null;
		return {
			...record.attachments[stagedBlob.index],
			read: async (offset, length) => {
				loaded ??= stagedBlob.bytes.arrayBuffer().then((buffer) => new Uint8Array(buffer));
				const bytes = await loaded;
				return bytes.subarray(offset, offset + length);
			},
		};
	});
}
