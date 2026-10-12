// Bounded storage policy shared by every Rooms archive backend.

import type {
	ArchiveFilter,
	ArchiveLine,
	ArchivePage,
	ArchiveRecord,
	ErasableArchiveBackend,
	RevisedArchiveRecord,
} from "./protocol.ts";
import {
	type ArchiveAttachmentAddress,
	type ArchivedAttachmentRead,
	type ArchivedAttachmentSource,
	attachmentMetadataEqual,
	type ErasableBlobArchiveBackend,
} from "./blobs.ts";
import { archiveMatches } from "./scope.ts";
import { BLOB_CHUNK } from "../limits.ts";
import { preserveArchiveLineChronology } from "./chronology.ts";

/** Whole-archive resident record ceiling. Least recently revised records
 * leave first. A held reference is authority to use the archive and not to
 * grow its host without limit. */
import { MAX_ARCHIVE_RECORDS } from "./limits.ts";
export { MAX_ARCHIVE_RECORDS } from "./limits.ts";

export function archiveRecordKey(record: ArchiveRecord): string {
	return JSON.stringify([
		record.source,
		record.generation,
		record.kind,
		record.kind === "line" ? record.conversationKind : "",
		record.directory,
		record.kind === "line" ? record.conversation : record.room,
		record.id,
	]);
}

/** The bounded, storage-independent archive index. A durable adapter owns when
 * a revision becomes committed, and this type owns what that revision means
 * once committed. Replacement, eviction, and ordered reads live here so the
 * browser, memory, and file backends share one semantic authority. */
export class ArchiveIndex {
	readonly #capacity: number;
	readonly #byKey = new Map<string, RevisedArchiveRecord>();
	readonly #byRevision = new Map<number, string>();
	#revision = 0;

	constructor(capacity = MAX_ARCHIVE_RECORDS) {
		if (!Number.isSafeInteger(capacity) || capacity < 1 || capacity > MAX_ARCHIVE_RECORDS) {
			throw new Error(`archive capacity must be between 1 and ${MAX_ARCHIVE_RECORDS}`);
		}
		this.#capacity = capacity;
	}

	get revision(): number {
		return this.#revision;
	}

	get size(): number {
		return this.#byKey.size;
	}

	/** Drop content without rewinding the revision feed. A caller that already
	 * holds a cursor must still be able to observe later records. */
	clear(): void {
		this.#byKey.clear();
		this.#byRevision.clear();
	}

	/** Restore one compacted snapshot. Records cross this storage boundary by
	 * owned transfer: wire and disk adapters validate before calling, and the
	 * index retains the immutable object without cloning it. Entries may have
	 * gaps because replaced and evicted records are absent, but must be strictly
	 * ordered and no newer than the snapshot's high-water revision. */
	restore(revision: number, entries: readonly RevisedArchiveRecord[]): void {
		if (!Number.isSafeInteger(revision) || revision < 0) {
			throw new Error("archive snapshot has an invalid revision");
		}
		if (entries.length > this.#capacity) throw new Error("archive snapshot exceeds capacity");
		const byKey = new Map<string, RevisedArchiveRecord>();
		const byRevision = new Map<number, string>();
		let prior = 0;
		for (const raw of entries) {
			if (!Number.isSafeInteger(raw.revision) || raw.revision <= prior || raw.revision > revision) {
				throw new Error("archive snapshot records are not in revision order");
			}
			const record = raw.record;
			const key = archiveRecordKey(record);
			if (byKey.has(key)) throw new Error("archive snapshot repeats a record key");
			const entry = { revision: raw.revision, record };
			byKey.set(key, entry);
			byRevision.set(raw.revision, key);
			prior = raw.revision;
		}
		this.#byKey.clear();
		this.#byRevision.clear();
		for (const [key, entry] of byKey) this.#byKey.set(key, entry);
		for (const [at, key] of byRevision) this.#byRevision.set(at, key);
		this.#revision = revision;
	}

	/** Apply the next committed revision. The storage adapter transfers one
	 * already-validated immutable record after committing it. A first record is
	 * retained directly, and replacing a line canonicalizes its chronology to
	 * the immutable first occurrence. The returned record is no longer reachable
	 * after the transition, so byte-owning adapters can retire their dependent
	 * content under the same policy. */
	apply(revision: number, record: ArchiveRecord): ArchiveRecord | null {
		if (!Number.isSafeInteger(revision) || revision !== this.#revision + 1) {
			throw new Error("archive revision is not the next revision");
		}
		const retired = this.retiredBy(record);
		const key = archiveRecordKey(record);
		const previous = this.#byKey.get(key);
		if (previous != null) this.#byRevision.delete(previous.revision);
		const retained = previous?.record.kind === "line" && record.kind === "line"
			? preserveArchiveLineChronology(previous.record, record)
			: record;
		const entry = { revision, record: retained };
		this.#byKey.set(key, entry);
		this.#byRevision.set(revision, key);
		this.#revision = revision;
		while (this.#byKey.size > this.#capacity) {
			const oldest = this.#byRevision.entries().next().value as [number, string] | undefined;
			if (oldest == null) break;
			this.#byRevision.delete(oldest[0]);
			this.#byKey.delete(oldest[1]);
		}
		return retired;
	}

	/** The record the next put will replace or evict, without changing the index.
	 * File adapters use this before their commit point to validate the retained
	 * byte state that the same transition will leave behind. */
	retiredBy(record: ArchiveRecord): ArchiveRecord | null {
		const key = archiveRecordKey(record);
		const previous = this.#byKey.get(key);
		if (previous != null) return previous.record;
		if (this.#byKey.size < this.#capacity) return null;
		const oldest = this.#byRevision.entries().next().value as [number, string] | undefined;
		if (oldest == null) return null;
		const entry = this.#byKey.get(oldest[1]);
		return entry?.record ?? null;
	}

	snapshot(): RevisedArchiveRecord[] {
		const entries: RevisedArchiveRecord[] = [];
		for (const key of this.#byRevision.values()) {
			const entry = this.#byKey.get(key);
			if (entry != null) entries.push(entry);
		}
		return entries;
	}

	read(filter: ArchiveFilter, after: number, limit: number): ArchivePage {
		const records: RevisedArchiveRecord[] = [];
		let next = after;
		let more = false;
		for (const [revision, key] of this.#byRevision) {
			if (revision <= after) continue;
			const entry = this.#byKey.get(key);
			if (entry == null || !archiveMatches(entry.record, filter)) continue;
			if (records.length === limit) {
				more = true;
				break;
			}
			records.push(entry);
			next = revision;
		}
		// No matching record remains. Advancing over non-matches is safe, and a
		// later matching put receives a greater revision and is still returned.
		if (!more) next = this.#revision;
		return { next, more, records };
	}

	matchingLine(filter: ArchiveFilter): ArchiveLine | null {
		const record = this.read(filter, 0, 1).records[0]?.record;
		return record?.kind === "line" ? record : null;
	}

	line(address: Omit<ArchiveAttachmentAddress, "index">): ArchiveLine | null {
		for (const entry of this.#byKey.values()) {
			const record = entry.record;
			if (
				record.kind === "line" && record.source === address.source &&
				record.generation === address.generation && record.id === address.id &&
				record.conversationKind === address.conversationKind && record.directory === address.directory &&
				record.conversation === address.conversation
			) return record;
		}
		return null;
	}
}

/** In-memory implementation of the archive backend contract. */
export class MemoryArchiveBackend implements ErasableArchiveBackend, ErasableBlobArchiveBackend {
	readonly #index: ArchiveIndex;
	readonly #blobs = new Map<string, Uint8Array>();
	readonly #references = new Map<string, number>();

	constructor(capacity = MAX_ARCHIVE_RECORDS) {
		this.#index = new ArchiveIndex(capacity);
	}

	clear(): void {
		this.#index.clear();
		this.#blobs.clear();
		this.#references.clear();
	}

	put(record: ArchiveRecord): Promise<number> {
		const prior = record.kind === "line" ? this.#index.line(record) : null;
		const checked = record.kind === "line" ? this.#preserve(prior, record) : record;
		const revision = this.#index.revision + 1;
		const retired = this.#index.apply(revision, checked);
		this.#commitBlobs(retired, checked);
		return Promise.resolve(revision);
	}

	read(filter: ArchiveFilter, after: number, limit: number): Promise<ArchivePage> {
		return Promise.resolve(this.#index.read(filter, after, limit));
	}

	peekLine(filter: ArchiveFilter): ArchiveLine | null {
		return this.#index.matchingLine(filter);
	}

	async putWithAttachments(record: ArchiveLine, attachments: readonly ArchivedAttachmentSource[]): Promise<number> {
		if (
			attachments.length !== record.attachments.length ||
			attachments.some((attachment, index) => !attachmentMetadataEqual(attachment, record.attachments[index]))
		) throw new Error("archive attachment sources do not match their line metadata");
		const bytes = await Promise.all(attachments.map((attachment) => this.#materialize(attachment)));
		const digests = await Promise.all(bytes.map((value) => this.#digest(value)));
		const stored: ArchiveLine = {
			...record,
			attachments: record.attachments.map((attachment, index) => ({
				...attachment,
				blob: digests[index],
			})),
		};
		const revision = this.#index.revision + 1;
		for (const [index, digest] of digests.entries()) {
			this.#blobs.set(digest, bytes[index]);
		}
		const retired = this.#index.apply(revision, stored);
		this.#commitBlobs(retired, stored);
		return revision;
	}

	readAttachment(address: ArchiveAttachmentAddress): Promise<ArchivedAttachmentRead | null> {
		const record = this.#index.line(address);
		const metadata = record?.attachments[address.index];
		const held = metadata?.blob == null ? null : this.#blobs.get(metadata.blob);
		if (record == null || metadata == null || held == null) {
			return Promise.resolve(null);
		}
		return Promise.resolve({
			record,
			attachment: {
				...metadata,
				read: (offset, maxLength) => {
					if (
						!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(maxLength) ||
						maxLength <= 0
					) {
						return Promise.reject(new Error("archive blob reads need a bounded offset and length"));
					}
					return Promise.resolve(
						held.subarray(offset, Math.min(held.length, offset + maxLength, offset + BLOB_CHUNK)),
					);
				},
			},
		});
	}

	#preserve(prior: ArchiveLine | null, submitted: ArchiveLine): ArchiveLine {
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

	#commitBlobs(retired: ArchiveRecord | null, next: ArchiveRecord): void {
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
		for (const [digest, count] of [...this.#references]) {
			if (count > 0) continue;
			this.#references.delete(digest);
			this.#blobs.delete(digest);
		}
	}

	async #digest(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
		const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
		return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
	}

	async #materialize(source: ArchivedAttachmentSource): Promise<Uint8Array<ArrayBuffer>> {
		const bytes = new Uint8Array(source.size);
		for (let offset = 0; offset < source.size; offset += BLOB_CHUNK) {
			const length = Math.min(BLOB_CHUNK, source.size - offset);
			const chunk = await source.read(offset, length);
			if (!(chunk instanceof Uint8Array) || chunk.length !== length) {
				throw new Error(
					`archive attachment source answered ${chunk?.length ?? 0} of ${length} requested bytes`,
				);
			}
			bytes.set(chunk, offset);
		}
		return bytes;
	}
}
