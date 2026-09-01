// IndexedDB transactions for the tab's member-owned archive (ADR-0129).
//
// The database module owns its schema and open lifecycle. This backend owns
// atomic record/blob mutations and bounded reads behind the shared archive
// seam. Older schemas reset rather than inventing provenance they never held.

import {
	ALL_ARCHIVE_RECORDS,
	type ArchiveFilter,
	type ArchiveLine,
	archiveMatches,
	type ArchivePage,
	type ArchiveRecord,
	archiveRecordKey,
	archiveRecordRow,
	type ErasableArchiveBackend,
	MAX_ARCHIVE_READ,
	MAX_ARCHIVE_RECORDS,
	MemoryArchiveBackend,
	parseArchiveRecord,
} from "../../lib/archive/protocol.ts";
import {
	type ArchiveAttachmentAddress,
	archiveAttachmentKey,
	type ArchivedAttachmentRead,
	type ArchivedAttachmentSource,
	attachmentMetadataEqual,
	type ErasableBlobArchiveBackend,
	lineAttachmentAddress,
	MAX_ARCHIVE_BLOB_BYTES,
} from "../../lib/archive/blobs.ts";
import { BLOB_CHUNK } from "../../lib/limits.ts";
import {
	archiveCoordinatesKey as coordinatesKey,
	sourcesFromStaged,
	stageBrowserBlob,
	type StagedBrowserBlob,
} from "./archive_blob_stage.ts";
import {
	archiveIdentity,
	BLOB_BYTES_KEY,
	type BlobBytesMetaRow,
	BlobBytesMetaRowSchema,
	BLOBS,
	COORDINATES_INDEX,
	META,
	type PageArchiveDatabase,
	RECORDS,
	RETENTION_EPOCH_KEY,
	type RetentionEpochMetaRow,
	RetentionEpochMetaRowSchema,
	REVISION_INDEX,
	REVISION_KEY,
	type RevisionMetaRow,
	RevisionMetaRowSchema,
	SOURCE_KEY,
	type SourceMetaRow,
	SourceMetaRowSchema,
	type StoredArchiveBlob,
	type StoredArchiveRecord,
	StoredArchiveRecordSchema,
	transactionFailure,
} from "./archive_database.ts";
import * as z from "zod/mini";

function uuid(): string {
	return crypto.randomUUID();
}

function sourceFrom(held: IDBDatabase): Promise<string> {
	return new Promise((resolve, reject) => {
		const tx = held.transaction(META, "readwrite");
		const meta = tx.objectStore(META);
		let source = "";
		let failure: Error | null = null;
		const get = meta.get(SOURCE_KEY);
		get.onsuccess = () => {
			if (get.result == null) {
				source = uuid();
				meta.put({ key: SOURCE_KEY, value: source } satisfies SourceMetaRow);
				return;
			}
			const parsed = z.safeParse(SourceMetaRowSchema, get.result);
			if (parsed.success) source = parsed.data.value;
			else {
				failure = new Error("archive storage contains invalid source identity");
				tx.abort();
			}
		};
		tx.oncomplete = () => resolve(source);
		tx.onerror = () => reject(failure ?? transactionFailure(tx, "archive source transaction failed"));
		tx.onabort = () => reject(failure ?? transactionFailure(tx, "archive source transaction aborted"));
	});
}

function retentionEpochFrom(held: IDBDatabase): Promise<string> {
	return new Promise((resolve, reject) => {
		const tx = held.transaction(META, "readwrite");
		const meta = tx.objectStore(META);
		let epoch = "";
		let failure: Error | null = null;
		const get = meta.get(RETENTION_EPOCH_KEY);
		get.onsuccess = () => {
			if (get.result == null) {
				epoch = uuid();
				meta.put({ key: RETENTION_EPOCH_KEY, value: epoch } satisfies RetentionEpochMetaRow);
				return;
			}
			const parsed = z.safeParse(RetentionEpochMetaRowSchema, get.result);
			if (parsed.success) epoch = parsed.data.value;
			else {
				failure = new Error("archive storage contains invalid retention identity");
				tx.abort();
			}
		};
		tx.oncomplete = () => resolve(epoch);
		tx.onerror = () => reject(failure ?? transactionFailure(tx, "history epoch transaction failed"));
		tx.onabort = () => reject(failure ?? transactionFailure(tx, "history epoch transaction aborted"));
	});
}

export async function historyRetentionEpoch(db: PageArchiveDatabase): Promise<string> {
	const held = await db.open();
	return held == null ? uuid() : await retentionEpochFrom(held);
}

/** The one backend shared by every capability reference this tab exports.
 * When IndexedDB is unavailable from the outset, the capability remains a
 * useful bounded in-memory archive for this page lifetime. Once a database
 * transaction begins, however, a failure is reported rather than silently
 * forking the archive between two stores. */
export class TabArchiveBackend implements ErasableArchiveBackend, ErasableBlobArchiveBackend {
	readonly #fallback = new MemoryArchiveBackend();
	readonly #fallbackSource = uuid();
	#source: Promise<string> | null = null;

	constructor(readonly db: PageArchiveDatabase) {}

	async source(): Promise<string> {
		if (this.#source != null) return await this.#source;
		this.#source = (async () => {
			const held = await this.db.open();
			if (held == null) return this.#fallbackSource;
			return await sourceFrom(held);
		})();
		return await this.#source;
	}

	/** Drop page-lifetime content without rewinding a reader's revision cursor. */
	clearVolatile(): void {
		this.#fallback.clear();
	}

	async clear(): Promise<void> {
		this.#fallback.clear();
		const held = await this.db.open();
		if (held == null) return;
		await new Promise<void>((resolve, reject) => {
			const tx = held.transaction([RECORDS, BLOBS, META], "readwrite");
			tx.objectStore(RECORDS).clear();
			tx.objectStore(BLOBS).clear();
			tx.objectStore(META).put({ key: BLOB_BYTES_KEY, value: 0 } satisfies BlobBytesMetaRow);
			tx.oncomplete = () => resolve();
			tx.onerror = () => reject(transactionFailure(tx, "archive clear transaction failed"));
			tx.onabort = () => reject(transactionFailure(tx, "archive clear transaction aborted"));
		});
	}

	async put(record: ArchiveRecord): Promise<number> {
		const revision = await this.#put(record, null, []);
		if (revision == null) throw new Error("an unrestricted archive write was not admitted");
		return revision;
	}

	putRetained(record: ArchiveRecord, epoch: string): Promise<number | null> {
		return this.#put(record, epoch, []);
	}

	async putRetainedWithAttachments(
		record: ArchiveLine,
		sources: readonly ArchivedAttachmentSource[],
		epoch: string,
	): Promise<number | null> {
		if (
			sources.length !== record.attachments.length ||
			sources.some((source, index) => !attachmentMetadataEqual(source, record.attachments[index]))
		) throw new Error("archive attachment sources do not match their line metadata");
		return await this.#put(record, epoch, await Promise.all(sources.map(stageBrowserBlob)));
	}

	async putWithAttachments(record: ArchiveLine, sources: readonly ArchivedAttachmentSource[]): Promise<number> {
		if (
			sources.length !== record.attachments.length ||
			sources.some((source, index) => !attachmentMetadataEqual(source, record.attachments[index]))
		) throw new Error("archive attachment sources do not match their line metadata");
		const staged = await Promise.all(sources.map(stageBrowserBlob));
		const revision = await this.#put(record, null, staged);
		if (revision == null) throw new Error("an unrestricted archive blob write was not admitted");
		return revision;
	}

	async #put(
		record: ArchiveRecord,
		expectedEpoch: string | null,
		staged: readonly StagedBrowserBlob[],
	): Promise<number | null> {
		if (expectedEpoch != null && !z.safeParse(archiveIdentity, expectedEpoch).success) {
			throw new Error("history retention identity is invalid");
		}
		const held = await this.db.open();
		if (held == null) {
			return staged.length > 0 && record.kind === "line"
				? await this.#fallback.putWithAttachments(record, sourcesFromStaged(record, staged))
				: await this.#fallback.put(record);
		}
		return await new Promise((resolve, reject) => {
			const tx = held.transaction([RECORDS, BLOBS, META], "readwrite");
			const records = tx.objectStore(RECORDS);
			const blobs = tx.objectStore(BLOBS);
			const meta = tx.objectStore(META);
			let revision = 0;
			let admitted = true;
			let failure: Error | null = null;
			const prepare = () => {
				const existing = records.get(archiveRecordKey(record));
				existing.onsuccess = () => {
					let prior: ArchiveLine | null = null;
					if (existing.result != null) {
						const parsed = z.safeParse(StoredArchiveRecordSchema, existing.result);
						if (!parsed.success) {
							failure = new Error("archive storage contains an invalid record envelope");
							tx.abort();
							return;
						}
						// A stored row this build cannot read is not a prior worth
						// honouring, and throwing here would leave the request handler
						// by a path IndexedDB does not carry: this put's promise would
						// settle neither way and its caller would wait for good. Treat
						// it as absent instead, which lets this write replace it and
						// puts the key back in a readable state.
						try {
							const found = parseArchiveRecord(parsed.data.row);
							if (found.kind === "line") prior = found;
						} catch {
							// tolerant: nothing is borrowed from a row this build cannot read.
						}
					}
					const checked = record.kind === "line"
						? {
							...record,
							attachments: record.attachments.map((attachment, index) => ({
								...attachment,
								blob: staged[index]?.digest ??
									(prior?.attachments[index] != null &&
											attachmentMetadataEqual(prior.attachments[index], attachment)
										? prior.attachments[index].blob
										: null),
							})),
						} satisfies ArchiveLine
						: record;
					const blobBytes = meta.get(BLOB_BYTES_KEY);
					blobBytes.onsuccess = () => {
						let retainedBytes = 0;
						if (blobBytes.result != null) {
							const parsed = z.safeParse(BlobBytesMetaRowSchema, blobBytes.result);
							if (!parsed.success) {
								failure = new Error("archive storage contains an invalid blob byte count");
								tx.abort();
								return;
							}
							retainedBytes = parsed.data.value;
						}
						const priorBytes = prior?.attachments.reduce(
							(total, attachment) => total + (attachment.blob == null ? 0 : attachment.size),
							0,
						) ?? 0;
						const nextBytes = checked.kind === "line"
							? checked.attachments.reduce(
								(total, attachment) => total + (attachment.blob == null ? 0 : attachment.size),
								0,
							)
							: 0;
						let nextBlobBytes = retainedBytes - priorBytes + nextBytes;
						if (prior != null) {
							for (let index = 0; index < prior.attachments.length; index += 1) {
								if (
									prior.attachments[index].blob ===
										(checked.kind === "line" ? checked.attachments[index]?.blob : null)
								) continue;
								blobs.delete(archiveAttachmentKey(lineAttachmentAddress(prior, index)));
							}
						}
						if (checked.kind === "line") {
							for (const stagedBlob of staged) {
								blobs.put(
									{
										key: archiveAttachmentKey(lineAttachmentAddress(checked, stagedBlob.index)),
										digest: stagedBlob.digest,
										size: stagedBlob.size,
										bytes: stagedBlob.bytes,
									} satisfies StoredArchiveBlob,
								);
							}
						}
						const current = meta.get(REVISION_KEY);
						current.onsuccess = () => {
							let prior = 0;
							if (current.result != null) {
								const parsed = z.safeParse(RevisionMetaRowSchema, current.result);
								if (!parsed.success) {
									failure = new Error("archive storage contains an invalid revision");
									tx.abort();
									return;
								}
								prior = parsed.data.value;
							}
							if (prior === Number.MAX_SAFE_INTEGER) {
								failure = new Error("archive revision space is exhausted");
								tx.abort();
								return;
							}
							revision = prior + 1;
							meta.put({ key: REVISION_KEY, value: revision } satisfies RevisionMetaRow);
							records.put(
								{
									key: archiveRecordKey(checked),
									coordinates: coordinatesKey(checked),
									revision,
									row: archiveRecordRow(checked),
								} satisfies StoredArchiveRecord,
							);
							const count = records.count();
							count.onsuccess = () => {
								const commitBlobBytes = () => {
									if (
										!Number.isSafeInteger(nextBlobBytes) || nextBlobBytes < 0 ||
										nextBlobBytes > MAX_ARCHIVE_BLOB_BYTES
									) {
										failure = new Error(
											nextBlobBytes > MAX_ARCHIVE_BLOB_BYTES
												? `archive blobs exceed their ${MAX_ARCHIVE_BLOB_BYTES}-byte ceiling`
												: "archive storage contains an inconsistent blob byte count",
										);
										tx.abort();
										return;
									}
									meta.put({ key: BLOB_BYTES_KEY, value: nextBlobBytes } satisfies BlobBytesMetaRow);
								};
								let remove = count.result - MAX_ARCHIVE_RECORDS;
								if (remove <= 0) {
									commitBlobBytes();
									return;
								}
								const cursor = records.index(REVISION_INDEX).openCursor();
								cursor.onsuccess = () => {
									const at = cursor.result;
									if (at == null) {
										failure = new Error("archive storage could not retire its excess records");
										tx.abort();
										return;
									}
									const parsed = z.safeParse(StoredArchiveRecordSchema, at.value);
									if (!parsed.success) {
										failure = new Error("archive storage contains an invalid evicted record");
										tx.abort();
										return;
									}
									// Retiring a row this build cannot read is still retiring it,
									// and this pass exists to retire rows. Its blob bytes cannot be
									// named, so none are reclaimed for it; the row itself still
									// goes. Throwing here would leave the cursor handler the way
									// the put's own read could, and hang this write for good.
									let evicted: ArchiveLine | null = null;
									try {
										const found = parseArchiveRecord(parsed.data.row);
										if (found.kind === "line") evicted = found;
									} catch {
										// tolerant: an unreadable row is retired naming no bytes.
									}
									if (evicted !== null) {
										for (let index = 0; index < evicted.attachments.length; index += 1) {
											if (evicted.attachments[index].blob == null) continue;
											blobs.delete(archiveAttachmentKey(lineAttachmentAddress(evicted, index)));
											nextBlobBytes -= evicted.attachments[index].size;
										}
									}
									at.delete();
									remove -= 1;
									if (remove === 0) {
										commitBlobBytes();
										return;
									}
									at.continue();
								};
							};
						};
					};
				};
			};
			if (expectedEpoch == null) prepare();
			else {
				const epoch = meta.get(RETENTION_EPOCH_KEY);
				epoch.onsuccess = () => {
					if (epoch.result == null) {
						meta.put({ key: RETENTION_EPOCH_KEY, value: expectedEpoch } satisfies RetentionEpochMetaRow);
						prepare();
						return;
					}
					const parsed = z.safeParse(RetentionEpochMetaRowSchema, epoch.result);
					if (!parsed.success) {
						failure = new Error("archive storage contains invalid retention identity");
						tx.abort();
					} else if (parsed.data.value === expectedEpoch) prepare();
					else admitted = false;
				};
			}
			tx.oncomplete = () => resolve(admitted ? revision : null);
			tx.onerror = () => reject(failure ?? transactionFailure(tx, "archive put transaction failed"));
			tx.onabort = () => reject(failure ?? transactionFailure(tx, "archive put transaction aborted"));
		});
	}

	async read(filter: ArchiveFilter, after: number, limit: number): Promise<ArchivePage> {
		const held = await this.db.open();
		if (held == null) return await this.#fallback.read(filter, after, limit);
		return await new Promise((resolve, reject) => {
			const tx = held.transaction([RECORDS, META], "readonly");
			const records: ArchivePage["records"] = [];
			let latest = after;
			let next = after;
			let more = false;
			let failure: unknown = null;
			const meta = tx.objectStore(META).get(REVISION_KEY);
			meta.onsuccess = () => {
				if (meta.result == null) return;
				const parsed = z.safeParse(RevisionMetaRowSchema, meta.result);
				if (parsed.success) latest = parsed.data.value;
				else {
					failure = new Error("archive storage contains an invalid revision");
					tx.abort();
				}
			};
			const range = IDBKeyRange.lowerBound(after, true);
			const cursor = tx.objectStore(RECORDS).index(REVISION_INDEX).openCursor(range);
			cursor.onsuccess = () => {
				const at = cursor.result;
				if (at == null) return;
				try {
					const parsed = z.safeParse(StoredArchiveRecordSchema, at.value);
					if (!parsed.success) throw new Error("archive storage contains an invalid record envelope");
					const stored = parsed.data;
					const record = parseArchiveRecord(stored.row);
					if (archiveMatches(record, filter)) {
						if (records.length === limit) {
							more = true;
							return;
						}
						records.push({ revision: stored.revision, record });
						next = stored.revision;
					}
					at.continue();
				} catch (error) {
					failure = error;
					tx.abort();
				}
			};
			tx.oncomplete = () => resolve({ next: more ? next : Math.max(latest, next), more, records });
			tx.onerror = () => reject(failure ?? transactionFailure(tx, "archive read transaction failed"));
			tx.onabort = () => reject(failure ?? transactionFailure(tx, "archive read transaction aborted"));
		});
	}

	peekLine(filter: ArchiveFilter): ArchiveLine | null {
		// IndexedDB cannot answer on the inbound turn. Tab-hosted CapTP does not
		// serve `blob()`; local reads use `attachment(record, index)`.
		return this.#fallback.peekLine(filter);
	}

	async readAttachment(address: ArchiveAttachmentAddress): Promise<ArchivedAttachmentRead | null> {
		const held = await this.db.open();
		if (held == null) return await this.#fallback.readAttachment(address);
		return await new Promise((resolve, reject) => {
			const tx = held.transaction([RECORDS, BLOBS], "readonly");
			let failure: unknown = null;
			let result: ArchivedAttachmentRead | null = null;
			const recordRequest = tx.objectStore(RECORDS).index(COORDINATES_INDEX).get(coordinatesKey(address));
			recordRequest.onsuccess = () => {
				if (recordRequest.result == null) return;
				try {
					const parsed = z.safeParse(StoredArchiveRecordSchema, recordRequest.result);
					if (!parsed.success) throw new Error("archive storage contains an invalid record envelope");
					const record = parseArchiveRecord(parsed.data.row);
					if (record.kind !== "line") return;
					const metadata = record.attachments[address.index];
					if (metadata?.blob == null) return;
					const blobRequest = tx.objectStore(BLOBS).get(
						archiveAttachmentKey(lineAttachmentAddress(record, address.index)),
					);
					blobRequest.onsuccess = () => {
						const stored = blobRequest.result as StoredArchiveBlob | undefined;
						if (
							stored == null || !(stored.bytes instanceof Blob) || stored.digest !== metadata.blob ||
							stored.size !== metadata.size || stored.bytes.size !== metadata.size
						) return;
						let verified: Promise<void> | null = null;
						result = {
							record,
							attachment: {
								...metadata,
								read: async (offset, maxLength) => {
									if (
										!Number.isSafeInteger(offset) || offset < 0 ||
										!Number.isSafeInteger(maxLength) || maxLength <= 0
									) throw new Error("archive blob reads need a bounded offset and length");
									verified ??= stored.bytes.arrayBuffer().then(async (buffer) => {
										const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", buffer));
										const hex = [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join(
											"",
										);
										if (hex !== stored.digest) {
											throw new Error("archive blob content does not match its digest");
										}
									});
									await verified;
									if (offset >= metadata.size) return new Uint8Array();
									const length = Math.min(maxLength, BLOB_CHUNK, metadata.size - offset);
									return new Uint8Array(
										await stored.bytes.slice(offset, offset + length).arrayBuffer(),
									);
								},
							},
						};
					};
				} catch (error) {
					failure = error;
					tx.abort();
				}
			};
			tx.oncomplete = () => resolve(result);
			tx.onerror = () => reject(failure ?? transactionFailure(tx, "archive blob read transaction failed"));
			tx.onabort = () => reject(failure ?? transactionFailure(tx, "archive blob read transaction aborted"));
		});
	}
}

/** Read a complete bounded context for the local conversation view. The
 * archive itself remains paged; only this tab-owned helper walks every page,
 * and the whole store ceiling makes that walk finite. */
export async function readTabArchiveContext(
	archive: TabArchiveBackend,
	conversationKind: "room" | "direct",
	directory: string,
	conversation: string,
): Promise<ArchiveRecord[]> {
	const filter: ArchiveFilter = {
		...ALL_ARCHIVE_RECORDS,
		kind: "line",
		conversationKind,
		directory,
		conversation,
	};
	const records: ArchiveRecord[] = [];
	let after = 0;
	while (true) {
		const batch = await archive.read(filter, after, MAX_ARCHIVE_READ);
		records.push(...batch.records.map((entry) => entry.record));
		if (!batch.more) return records;
		after = batch.next;
	}
}

/** Advance the device recorder's admission boundary, optionally erasing every
 * retained row in that same transaction. */
export async function setHistoryRetentionEpoch(
	db: PageArchiveDatabase,
	epoch: string,
	erase: boolean,
): Promise<void> {
	if (!z.safeParse(archiveIdentity, epoch).success) throw new Error("history retention identity is invalid");
	const held = await db.open();
	if (held == null) return;
	await new Promise<void>((resolve, reject) => {
		const tx = held.transaction(erase ? [RECORDS, BLOBS, META] : [META], "readwrite");
		tx.objectStore(META).put({ key: RETENTION_EPOCH_KEY, value: epoch } satisfies RetentionEpochMetaRow);
		if (erase) {
			tx.objectStore(RECORDS).clear();
			tx.objectStore(BLOBS).clear();
			tx.objectStore(META).put({ key: BLOB_BYTES_KEY, value: 0 } satisfies BlobBytesMetaRow);
		}
		tx.oncomplete = () => resolve();
		tx.onerror = () => reject(transactionFailure(tx, "history retention transaction failed"));
		tx.onabort = () => reject(transactionFailure(tx, "history retention transaction aborted"));
	});
}
