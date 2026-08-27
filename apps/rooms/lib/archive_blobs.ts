// Blob custody behind the member-owned archive capability.

import type {
	ArchiveBackend,
	ArchiveCoordinates,
	ArchivedAttachment,
	ArchiveLine,
	ErasableArchiveBackend,
} from "./archive.ts";

export const MAX_ARCHIVE_BLOB_BYTES = 512 * 1024 * 1024;

export interface ArchiveAttachmentAddress extends ArchiveCoordinates {
	readonly conversationKind: ArchiveLine["conversationKind"];
	readonly directory: string;
	readonly conversation: string;
	readonly index: number;
}

export interface ArchivedAttachmentSource extends ArchivedAttachment {
	read(offset: number, maxLength: number): Promise<Uint8Array>;
}

export interface ArchivedAttachmentRead {
	readonly record: ArchiveLine;
	readonly attachment: ArchivedAttachmentSource;
}

export interface BlobArchiveBackend extends ArchiveBackend {
	putWithAttachments(record: ArchiveLine, attachments: readonly ArchivedAttachmentSource[]): Promise<number>;
	readAttachment(address: ArchiveAttachmentAddress): Promise<ArchivedAttachmentRead | null>;
}

export interface ErasableBlobArchiveBackend extends BlobArchiveBackend, ErasableArchiveBackend {}

export function isBlobArchiveBackend(backend: ArchiveBackend): backend is BlobArchiveBackend {
	return "putWithAttachments" in backend && typeof backend.putWithAttachments === "function" &&
		"readAttachment" in backend && typeof backend.readAttachment === "function";
}

export function archiveAttachmentKey(address: ArchiveAttachmentAddress): string {
	return JSON.stringify([
		address.source,
		address.generation,
		address.id,
		address.conversationKind,
		address.directory,
		address.conversation,
		address.index,
	]);
}

type AttachmentMetadata = Pick<ArchivedAttachment, "name" | "mime" | "size" | "width" | "height">;

export function attachmentMetadataEqual(left: AttachmentMetadata, right: AttachmentMetadata): boolean {
	return left.name === right.name && left.mime === right.mime && left.size === right.size &&
		left.width === right.width && left.height === right.height;
}

export function lineAttachmentAddress(record: ArchiveLine, index: number): ArchiveAttachmentAddress {
	return {
		source: record.source,
		generation: record.generation,
		id: record.id,
		conversationKind: record.conversationKind,
		directory: record.directory,
		conversation: record.conversation,
		index,
	};
}
