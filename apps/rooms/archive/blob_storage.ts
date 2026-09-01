// Bounded content-addressed file custody for one durable member archive.

import { createHash } from "node:crypto";
import type { ArchiveLine, ArchiveRecord } from "../lib/archive/protocol.ts";
import type { ArchiveIndex } from "../lib/archive/index.ts";
import {
	type ArchiveAttachmentAddress,
	type ArchivedAttachmentRead,
	type ArchivedAttachmentSource,
	attachmentMetadataEqual,
	MAX_ARCHIVE_BLOB_BYTES,
} from "../lib/archive/blobs.ts";
import { BLOB_CHUNK } from "../lib/limits.ts";
import { renameSynced, writeAll } from "../lib/durable_file.ts";

const DIRECTORY = "blobs";

export interface StagedArchiveBlobs {
	readonly record: ArchiveLine;
	readonly created: ReadonlySet<string>;
}

export class FileArchiveBlobs {
	readonly #directory: string;
	readonly #index: ArchiveIndex;
	readonly #maxBytes: number;
	readonly #references = new Map<string, number>();
	readonly #pendingRemoval = new Set<string>();
	readonly #sizes = new Map<string, number>();
	readonly #verified = new Set<string>();
	#bytes = 0;

	private constructor(directory: string, index: ArchiveIndex, maxBytes: number) {
		this.#directory = directory;
		this.#index = index;
		this.#maxBytes = maxBytes;
	}

	static async open(directory: string, index: ArchiveIndex, maxBytes = MAX_ARCHIVE_BLOB_BYTES) {
		if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) {
			throw new Error("archive blob ceiling must be a positive safe integer");
		}
		const blobs = new FileArchiveBlobs(`${directory}/${DIRECTORY}`, index, maxBytes);
		await blobs.#load();
		return blobs;
	}

	/** Retain prior blob identities only when the submitted metadata still names
	 * the same file position. Caller-supplied digests never select archive data. */
	preserve(prior: ArchiveLine | null, submitted: ArchiveLine): ArchiveLine {
		return {
			...submitted,
			attachments: submitted.attachments.map((attachment, index) => ({
				...attachment,
				blob: prior?.attachments[index] != null &&
						attachmentMetadataEqual(prior.attachments[index], attachment)
					? prior.attachments[index].blob
					: null,
			})),
		};
	}

	async stage(
		record: ArchiveLine,
		sources: readonly ArchivedAttachmentSource[],
		retired: ArchiveRecord | null,
	): Promise<StagedArchiveBlobs> {
		if (
			sources.length !== record.attachments.length ||
			sources.some((source, index) => !attachmentMetadataEqual(source, record.attachments[index]))
		) throw new Error("archive attachment sources do not match their line metadata");
		await Deno.mkdir(this.#directory, { recursive: true, mode: 0o700 });
		const created = new Set<string>();
		const digests: string[] = [];
		try {
			for (const source of sources) {
				const result = await this.#write(source);
				digests.push(result.digest);
				this.#bytes += result.byteDelta;
				if (result.created) created.add(result.digest);
			}
			const stored: ArchiveLine = {
				...record,
				attachments: record.attachments.map((attachment, index) => ({
					...attachment,
					blob: digests[index],
				})),
			};
			if (this.#projectedBytes(retired, stored) > this.#maxBytes) {
				throw new Error(`archive blobs exceed their ${this.#maxBytes}-byte ceiling`);
			}
			return { record: stored, created };
		} catch (error) {
			try {
				await this.abort(created);
			} catch (cleanup) {
				throw new AggregateError([error, cleanup], "archive blob staging and cleanup both failed");
			}
			throw error;
		}
	}

	/** Apply blob references only after the line revision committed. */
	async commit(retired: ArchiveRecord | null, next: ArchiveRecord): Promise<void> {
		if (retired?.kind === "line") {
			for (const digest of retired.attachments.flatMap((attachment) => attachment.blob ?? [])) {
				this.#references.set(digest, (this.#references.get(digest) ?? 1) - 1);
			}
		}
		if (next.kind === "line") {
			for (const digest of next.attachments.flatMap((attachment) => attachment.blob ?? [])) {
				this.#references.set(digest, (this.#references.get(digest) ?? 0) + 1);
			}
		}
		for (const [digest, count] of this.#references) {
			if (count <= 0) this.#pendingRemoval.add(digest);
		}
		for (const digest of [...this.#pendingRemoval]) {
			if ((this.#references.get(digest) ?? 0) > 0) {
				this.#pendingRemoval.delete(digest);
				continue;
			}
			await this.#remove(digest);
			this.#references.delete(digest);
			this.#pendingRemoval.delete(digest);
		}
	}

	async abort(created: ReadonlySet<string>): Promise<void> {
		for (const digest of created) {
			if ((this.#references.get(digest) ?? 0) > 0) continue;
			this.#pendingRemoval.add(digest);
			await this.#remove(digest);
			this.#pendingRemoval.delete(digest);
		}
	}

	async read(address: ArchiveAttachmentAddress): Promise<ArchivedAttachmentRead | null> {
		const record = this.#index.line(address);
		const metadata = record?.attachments[address.index];
		if (record == null || metadata?.blob == null) return null;
		const path = this.#path(metadata.blob);
		try {
			const stat = await Deno.stat(path);
			if (stat.size !== metadata.size) return null;
			await this.#verify(path, metadata.blob, metadata.size);
		} catch (error) {
			if (error instanceof Deno.errors.NotFound) return null;
			throw error;
		}
		return {
			record,
			attachment: {
				...metadata,
				read: async (offset, maxLength) => {
					if (
						!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(maxLength) ||
						maxLength <= 0
					) {
						throw new Error("archive blob reads need a bounded offset and length");
					}
					if (offset >= metadata.size) return new Uint8Array();
					const length = Math.min(maxLength, BLOB_CHUNK, metadata.size - offset);
					const file = await Deno.open(path, { read: true });
					try {
						await file.seek(offset, Deno.SeekMode.Start);
						const bytes = new Uint8Array(length);
						let read = 0;
						while (read < length) {
							const got = await file.read(bytes.subarray(read));
							if (got == null) throw new Error("archive blob ended before its retained size");
							read += got;
						}
						return bytes;
					} finally {
						file.close();
					}
				},
			},
		};
	}

	async clear(): Promise<void> {
		try {
			await Deno.remove(this.#directory, { recursive: true });
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
		}
		this.#references.clear();
		this.#pendingRemoval.clear();
		this.#sizes.clear();
		this.#verified.clear();
		this.#bytes = 0;
	}

	async #load(): Promise<void> {
		for (const { record } of this.#index.snapshot()) {
			if (record.kind !== "line") continue;
			for (const digest of record.attachments.flatMap((attachment) => attachment.blob ?? [])) {
				this.#references.set(digest, (this.#references.get(digest) ?? 0) + 1);
			}
		}
		try {
			for await (const entry of Deno.readDir(this.#directory)) {
				const path = `${this.#directory}/${entry.name}`;
				if (!entry.isFile || !this.#references.has(entry.name) || !/^[0-9a-f]{64}$/.test(entry.name)) {
					await Deno.remove(path, { recursive: !entry.isFile });
					continue;
				}
				const size = (await Deno.stat(path)).size;
				this.#bytes += size;
				this.#sizes.set(entry.name, size);
			}
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
		}
		if (this.#bytes > this.#maxBytes) throw new Error("archive blobs exceed their byte ceiling");
	}

	async #write(
		source: ArchivedAttachmentSource,
	): Promise<{ digest: string; created: boolean; byteDelta: number }> {
		const temporary = `${this.#directory}/.tmp-${crypto.randomUUID()}`;
		const file = await Deno.open(temporary, { createNew: true, write: true, mode: 0o600 });
		const hash = createHash("sha256");
		try {
			try {
				for (let offset = 0; offset < source.size; offset += BLOB_CHUNK) {
					const length = Math.min(BLOB_CHUNK, source.size - offset);
					const chunk = await source.read(offset, length);
					if (!(chunk instanceof Uint8Array) || chunk.length !== length) {
						throw new Error(
							`archive attachment source answered ${chunk?.length ?? 0} of ${length} requested bytes`,
						);
					}
					hash.update(chunk);
					await writeAll(file, chunk);
				}
				await file.sync();
			} finally {
				file.close();
			}
			const digest = hash.digest("hex");
			const path = this.#path(digest);
			const priorSize = this.#sizes.get(digest);
			await renameSynced(temporary, path);
			this.#sizes.set(digest, source.size);
			this.#verified.add(digest);
			return { digest, created: priorSize == null, byteDelta: source.size - (priorSize ?? 0) };
		} catch (error) {
			await this.#removeTemporary(temporary);
			throw error;
		}
	}

	async #removeTemporary(path: string): Promise<void> {
		try {
			await Deno.remove(path);
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) {
				console.error(`archive blob temporary cleanup failed: ${error}`);
			}
		}
	}

	#projectedBytes(retired: ArchiveRecord | null, next: ArchiveLine): number {
		const deltas = new Map<string, number>();
		if (retired?.kind === "line") {
			for (const digest of retired.attachments.flatMap((attachment) => attachment.blob ?? [])) {
				deltas.set(digest, (deltas.get(digest) ?? 0) - 1);
			}
		}
		for (const digest of next.attachments.flatMap((attachment) => attachment.blob ?? [])) {
			deltas.set(digest, (deltas.get(digest) ?? 0) + 1);
		}
		let bytes = this.#bytes;
		const reclaimable = new Set(this.#pendingRemoval);
		for (const [digest, delta] of deltas) {
			if ((this.#references.get(digest) ?? 0) + delta > 0) reclaimable.delete(digest);
			else reclaimable.add(digest);
		}
		for (const digest of reclaimable) bytes -= this.#sizes.get(digest) ?? 0;
		return bytes;
	}

	async #remove(digest: string): Promise<void> {
		const size = this.#sizes.get(digest) ?? 0;
		try {
			await Deno.remove(this.#path(digest));
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
		}
		this.#bytes -= size;
		this.#sizes.delete(digest);
		this.#verified.delete(digest);
	}

	#path(digest: string): string {
		return `${this.#directory}/${digest}`;
	}

	async #verify(path: string, digest: string, size: number): Promise<void> {
		if (this.#verified.has(digest)) return;
		const hash = createHash("sha256");
		const file = await Deno.open(path, { read: true });
		try {
			let read = 0;
			while (read < size) {
				const bytes = new Uint8Array(Math.min(BLOB_CHUNK, size - read));
				const got = await file.read(bytes);
				if (got == null || got === 0) throw new Error("archive blob ended before its retained size");
				hash.update(bytes.subarray(0, got));
				read += got;
			}
		} finally {
			file.close();
		}
		if (hash.digest("hex") !== digest) throw new Error("archive blob content does not match its digest");
		this.#verified.add(digest);
	}
}
