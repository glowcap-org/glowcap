// Archive attachment metadata is a durable record projection. Blob bytes and
// their capability authority remain owned by the archive blob protocol.
import type { Argument } from "@glowcap/runtime";
import { attachmentRefusal, MAX_IMAGE_DIM, MAX_MESSAGE_FILES, MAX_ROOM_ATTACHMENT_BYTES } from "../limits.ts";

/** The durable fact that a file occupied one place on a line. */
export interface ArchivedAttachment {
	readonly name: string;
	readonly mime: string;
	readonly size: number;
	readonly width: number;
	readonly height: number;
	/** Content digest minted by the archive that holds the bytes, or null when
	 * this record retains metadata only. It identifies content, not authority. */
	readonly blob: string | null;
}

function archivedDimension(raw: unknown): number {
	if (typeof raw !== "bigint" || raw < 0n || raw > BigInt(MAX_IMAGE_DIM)) {
		throw new Error("archive attachment dimensions are invalid");
	}
	return Number(raw);
}

export function parseArchivedAttachments(raw: unknown): ArchivedAttachment[] {
	if (!Array.isArray(raw) || raw.length > MAX_MESSAGE_FILES) {
		throw new Error(`an archive line may carry at most ${MAX_MESSAGE_FILES} attachment records`);
	}
	const attachments = raw.map((entry) => {
		if (
			!Array.isArray(entry) || entry.length !== 6 || typeof entry[0] !== "string" ||
			typeof entry[1] !== "string" || typeof entry[2] !== "bigint" || entry[2] > BigInt(Number.MAX_SAFE_INTEGER)
		) throw new Error("an archive attachment record has the wrong shape");
		const blob = entry[5];
		if (blob !== null && (typeof blob !== "string" || !/^[0-9a-f]{64}$/.test(blob))) {
			throw new Error("an archive attachment has an invalid blob digest");
		}
		const size = Number(entry[2]);
		const refused = attachmentRefusal(entry[0], entry[1], size);
		if (refused != null) throw new Error(`archive attachment: ${refused}`);
		return {
			name: entry[0],
			mime: entry[1],
			size,
			width: archivedDimension(entry[3]),
			height: archivedDimension(entry[4]),
			blob,
		};
	});
	if (attachments.reduce((total, attachment) => total + attachment.size, 0) > MAX_ROOM_ATTACHMENT_BYTES) {
		throw new Error(`archive line attachments may total at most ${MAX_ROOM_ATTACHMENT_BYTES} bytes`);
	}
	return attachments;
}

export function archivedAttachmentRows(attachments: readonly ArchivedAttachment[]): Argument[] {
	return attachments.map((attachment) => [
		attachment.name,
		attachment.mime,
		BigInt(attachment.size),
		BigInt(attachment.width),
		BigInt(attachment.height),
		attachment.blob,
	]);
}
