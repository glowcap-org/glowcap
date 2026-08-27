// Explicit custody for files on one durable direct conversation.

import type { Attachment, AttachmentSource } from "../lib/attachment.ts";
import { fetchBlob, validateAttachmentSource } from "../lib/attachment.ts";
import type { Session } from "@pancake/runtime";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";
import {
	BLOB_CHUNK,
	MAX_DIRECT_ATTACHMENT_BYTES,
	MAX_DIRECT_ATTACHMENTS,
	MAX_MESSAGE_FILES,
	MAX_SCROLLBACK,
} from "../lib/limits.ts";
import type { RuntimeAttachment } from "./room_files.ts";

interface SentFile {
	name: string;
	mime: string;
	size: number;
	width: number;
	height: number;
	source: AttachmentSource | null;
}

interface ReceivedFile {
	attachment: Attachment;
	session: Session;
	bytes: Promise<Uint8Array> | null;
	settled: boolean;
	releaseWhenSettled: boolean;
	budgetHeld: boolean;
}

// A direct recipient has no room server to own retained media, so this is the
// receiver-side sibling of attachment.ts's process-wide hosted-source budget.
// Pending materializations keep their reservation after a conversation drops
// them: the allocation is still live until the read settles and cannot be made
// invisible merely by removing its presentation row.
const receivedFiles: ReceivedFile[] = [];
let receivedFileBytes = 0;

function releaseReceivedBudget(file: ReceivedFile): void {
	if (!file.budgetHeld) return;
	file.budgetHeld = false;
	receivedFileBytes -= file.attachment.size;
	const at = receivedFiles.indexOf(file);
	if (at >= 0) receivedFiles.splice(at, 1);
}

function dropReceivedFile(file: ReceivedFile): void {
	if (file.bytes == null) return;
	file.bytes = null;
	if (file.settled) releaseReceivedBudget(file);
	else file.releaseWhenSettled = true;
}

function admitReceivedFiles(count: number, bytes: number): void {
	while (
		receivedFiles.length + count > MAX_DIRECT_ATTACHMENTS || receivedFileBytes + bytes > MAX_DIRECT_ATTACHMENT_BYTES
	) {
		const oldest = receivedFiles.find((file) => file.settled);
		if (oldest == null) {
			throw new Error("direct-message files are still arriving at the process memory ceiling");
		}
		dropReceivedFile(oldest);
	}
}

function startReceivedFile(session: Session, attachment: Attachment): ReceivedFile {
	const file: ReceivedFile = {
		attachment,
		session,
		bytes: null,
		settled: false,
		releaseWhenSettled: false,
		budgetHeld: true,
	};
	receivedFiles.push(file);
	receivedFileBytes += attachment.size;
	const loading = fetchBlob(session, attachment).then(
		(bytes) => {
			file.settled = true;
			if (file.releaseWhenSettled) releaseReceivedBudget(file);
			return bytes;
		},
		(error) => {
			file.settled = true;
			releaseReceivedBudget(file);
			throw error;
		},
	).finally(() => {
		settleCapabilityCleanup(
			"materialized direct attachment release failed",
			() => session.release(attachment.blob),
		);
	});
	file.bytes = loading;
	// The retained promise is observed by archive and view readers later. Mark
	// an early refusal observed now without changing the promise they receive.
	void loading.catch(() => undefined);
	return file;
}

/** Owns direct-file authority after a line has been emitted. Incoming
 * capabilities are materialized once because the durable session has several
 * internal readers (archive and attached views), while the direct sender grants
 * one complete read. Outgoing descriptors retain the caller's bounded reader.
 * The two maps stay separate because both peers may use the same line number
 * in opposite directions. */
export class DirectFileCustody {
	readonly #incoming = new Map<number, ReceivedFile[]>();
	readonly #outgoing = new Map<number, SentFile[]>();
	#incomingBytes = 0;
	#outgoingBytes = 0;

	retainIncoming(
		message: { lineId?: number; change?: string; attachments: Attachment[] },
		session: Session,
	): RuntimeAttachment[] {
		if (message.lineId == null) return [];
		const previous = this.#incoming.get(message.lineId);
		if (message.change === "withdrawn") {
			this.#dropIncoming(message.lineId);
			return [];
		}
		if (message.change === "edited") return this.#projectIncoming(previous ?? []);
		if (message.change !== "said" && message.change !== "refiled") return [];
		const total = message.attachments.reduce((sum, attachment) => sum + attachment.size, 0);
		if (total > MAX_DIRECT_ATTACHMENT_BYTES) {
			throw new Error(`direct-message files may total at most ${MAX_DIRECT_ATTACHMENT_BYTES} bytes`);
		}
		const selected = message.attachments.map((attachment) => ({
			attachment,
			existing:
				previous?.find((file) => file.session === session && file.attachment.blob.equals(attachment.blob)) ??
					null,
		}));
		const fresh = selected.filter(({ attachment, existing }) =>
			existing == null || existing.bytes == null && attachment !== existing.attachment
		);
		try {
			admitReceivedFiles(
				fresh.length,
				fresh.reduce((sum, { attachment }) => sum + attachment.size, 0),
			);
		} catch (error) {
			for (const { attachment, existing } of selected) {
				if (attachment === existing?.attachment) continue;
				settleCapabilityCleanup(
					"refused direct attachment release failed",
					() => session.release(attachment.blob),
				);
			}
			throw error;
		}
		const retained = selected.map(({ attachment, existing }) => {
			if (existing != null && (attachment === existing.attachment || existing.bytes != null)) {
				if (attachment !== existing.attachment) {
					settleCapabilityCleanup(
						"repeated direct attachment release failed",
						() => session.release(attachment.blob),
					);
				}
				return existing;
			}
			return startReceivedFile(session, attachment);
		});
		for (const file of previous ?? []) {
			if (!retained.includes(file)) dropReceivedFile(file);
		}
		if (previous != null) this.#incomingBytes -= previous.reduce((sum, file) => sum + file.attachment.size, 0);
		if (retained.length === 0) this.#incoming.delete(message.lineId);
		else this.#incoming.set(message.lineId, retained);
		this.#incomingBytes += retained.reduce((sum, file) => sum + file.attachment.size, 0);
		this.#trimIncoming();
		return this.#projectIncoming(retained);
	}

	retainOutgoing(lineId: number, sources: readonly AttachmentSource[]): RuntimeAttachment[] {
		if (sources.length === 0) return [];
		if (sources.length > MAX_MESSAGE_FILES) throw new Error("a message may carry too many files");
		const files = sources.map((source) => {
			const size = validateAttachmentSource(source);
			return {
				name: source.name,
				mime: source.mime,
				size,
				width: source.width ?? 0,
				height: source.height ?? 0,
				source,
			};
		});
		const total = files.reduce((sum, file) => sum + file.size, 0);
		if (total > MAX_DIRECT_ATTACHMENT_BYTES) {
			throw new Error(`direct-message files may total at most ${MAX_DIRECT_ATTACHMENT_BYTES} bytes`);
		}
		this.#releaseOutgoing(lineId);
		this.#outgoing.set(lineId, files);
		this.#outgoingBytes += total;
		this.#trimOutgoing();
		return files.map((file) => this.#local(file));
	}

	projectOutgoing(lineId: number): RuntimeAttachment[] {
		return (this.#outgoing.get(lineId) ?? []).map((file) => this.#local(file));
	}

	refileOutgoing(lineId: number, keep: readonly number[], sources: readonly AttachmentSource[]): RuntimeAttachment[] {
		const current = this.#outgoing.get(lineId) ?? [];
		const kept = keep.map((index) => {
			const file = current[index];
			if (file == null) throw new Error(`no direct file at index ${index}`);
			return file;
		});
		if (new Set(keep).size !== keep.length || kept.length + sources.length > MAX_MESSAGE_FILES) {
			throw new Error("direct refile has invalid kept files");
		}
		const added = sources.map((source) => {
			const size = validateAttachmentSource(source);
			return {
				name: source.name,
				mime: source.mime,
				size,
				width: source.width ?? 0,
				height: source.height ?? 0,
				source,
			};
		});
		const files = [...kept, ...added];
		if (files.reduce((sum, file) => sum + file.size, 0) > MAX_DIRECT_ATTACHMENT_BYTES) {
			throw new Error(`direct-message files may total at most ${MAX_DIRECT_ATTACHMENT_BYTES} bytes`);
		}
		this.#outgoing.delete(lineId);
		this.#outgoingBytes -= current.reduce((sum, file) => sum + file.size, 0);
		for (const file of current) if (!kept.includes(file)) file.source = null;
		this.#outgoing.set(lineId, files);
		this.#outgoingBytes += files.reduce((sum, file) => sum + file.size, 0);
		this.#trimOutgoing();
		return files.map((file) => this.#local(file));
	}

	validateOutgoingRefiling(lineId: number, keep: readonly number[], sources: readonly AttachmentSource[]): void {
		const current = this.#outgoing.get(lineId) ?? [];
		if (new Set(keep).size !== keep.length || keep.some((index) => current[index] == null)) {
			throw new Error("direct refile has invalid kept files");
		}
		if (keep.length + sources.length > MAX_MESSAGE_FILES) throw new Error("direct refile has too many files");
		const size = sources.reduce((total, source) => total + validateAttachmentSource(source), 0) +
			keep.reduce((total, index) => total + (current[index]?.size ?? 0), 0);
		if (size > MAX_DIRECT_ATTACHMENT_BYTES) {
			throw new Error(`direct-message files may total at most ${MAX_DIRECT_ATTACHMENT_BYTES} bytes`);
		}
	}

	releaseOutgoing(lineId: number): void {
		this.#releaseOutgoing(lineId);
	}

	close(): void {
		for (const lineId of [...this.#incoming.keys()]) this.#dropIncoming(lineId);
		for (const lineId of [...this.#outgoing.keys()]) this.#releaseOutgoing(lineId);
	}

	#local(file: SentFile): RuntimeAttachment {
		return {
			name: file.name,
			mime: file.mime,
			size: file.size,
			width: file.width,
			height: file.height,
			materialize: async () => {
				const source = file.source;
				if (source == null) throw new Error("this direct attachment is no longer retained by the session");
				if (source.bytes != null) return source.bytes;
				const bytes = new Uint8Array(file.size);
				for (let offset = 0; offset < file.size; offset += BLOB_CHUNK) {
					const length = Math.min(BLOB_CHUNK, file.size - offset);
					const chunk = await source.read?.(offset, length);
					if (!(chunk instanceof Uint8Array) || chunk.length !== length) {
						throw new Error(
							`attachment source answered ${chunk?.length ?? 0} of ${length} requested bytes`,
						);
					}
					bytes.set(chunk, offset);
				}
				return bytes;
			},
			read: async (offset, maxLen) => {
				if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(maxLen) || maxLen <= 0) {
					throw new Error("direct attachment reads need a bounded offset and length");
				}
				const source = file.source;
				if (source == null) throw new Error("this direct attachment is no longer retained by the session");
				if (offset >= file.size) return new Uint8Array();
				const length = Math.min(maxLen, BLOB_CHUNK, file.size - offset);
				const chunk = source.bytes?.subarray(offset, offset + length) ?? await source.read?.(offset, length);
				if (!(chunk instanceof Uint8Array) || chunk.length !== length) {
					throw new Error(`attachment source answered ${chunk?.length ?? 0} of ${length} requested bytes`);
				}
				return chunk;
			},
		};
	}

	#releaseOutgoing(lineId: number): void {
		const files = this.#outgoing.get(lineId);
		if (files == null) return;
		this.#outgoing.delete(lineId);
		this.#outgoingBytes -= files.reduce((sum, file) => sum + file.size, 0);
		for (const file of files) file.source = null;
	}

	#dropIncoming(lineId: number): void {
		const files = this.#incoming.get(lineId);
		if (files == null) return;
		this.#incoming.delete(lineId);
		this.#incomingBytes -= files.reduce((sum, file) => sum + file.attachment.size, 0);
		for (const file of files) dropReceivedFile(file);
	}

	#trimIncoming(): void {
		while (this.#incoming.size > MAX_SCROLLBACK || this.#incomingBytes > MAX_DIRECT_ATTACHMENT_BYTES) {
			const oldest = this.#incoming.keys().next().value as number | undefined;
			if (oldest == null) break;
			this.#dropIncoming(oldest);
		}
	}

	#trimOutgoing(): void {
		while (this.#outgoing.size > MAX_SCROLLBACK || this.#outgoingBytes > MAX_DIRECT_ATTACHMENT_BYTES) {
			const oldest = this.#outgoing.entries().next().value as [number, SentFile[]] | undefined;
			if (oldest == null) break;
			this.#releaseOutgoing(oldest[0]);
		}
	}

	#projectIncoming(files: readonly ReceivedFile[]): RuntimeAttachment[] {
		return files.map((file) => ({
			name: file.attachment.name,
			mime: file.attachment.mime,
			size: file.attachment.size,
			width: file.attachment.width,
			height: file.attachment.height,
			materialize: () => {
				const loading = file.bytes;
				return loading ?? Promise.reject(new Error("this incoming direct attachment is no longer retained"));
			},
			read: (offset, maxLen) => {
				if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(maxLen) || maxLen <= 0) {
					return Promise.reject(new Error("direct attachment reads need a bounded offset and length"));
				}
				const loading = file.bytes;
				if (loading == null) {
					return Promise.reject(new Error("this incoming direct attachment is no longer retained"));
				}
				return loading.then((bytes) => {
					if (offset >= bytes.length) return new Uint8Array();
					return bytes.subarray(offset, Math.min(bytes.length, offset + maxLen, offset + BLOB_CHUNK));
				});
			},
		}));
	}
}
