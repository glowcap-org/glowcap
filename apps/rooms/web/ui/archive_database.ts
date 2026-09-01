// IndexedDB schema and open lifecycle for the browser member archive.

import { nonemptyText, nonnegativeSafeInteger, positiveSafeInteger } from "../../lib/schema.ts";
import * as z from "zod/mini";

const HISTORY_DB = "rooms-history";
const DB_VERSION = 1;
export const RECORDS = "archive-records";
export const BLOBS = "archive-blobs";
export const META = "archive-meta";
export const REVISION_INDEX = "revision";
export const COORDINATES_INDEX = "coordinates";
export const SOURCE_KEY = "source";
export const REVISION_KEY = "revision";
export const RETENTION_EPOCH_KEY = "retention-epoch";
export const BLOB_BYTES_KEY = "blob-bytes";

export const archiveIdentity = nonemptyText(128).check(
	// deno-lint-ignore no-control-regex
	z.refine((value) => !/[\u0000-\u001f\u007f-\u009f]/.test(value)),
);
export const StoredArchiveRecordSchema = z.strictObject({
	key: nonemptyText(32 * 1024),
	coordinates: nonemptyText(1024),
	revision: positiveSafeInteger,
	row: z.unknown(),
});
export const SourceMetaRowSchema = z.strictObject({ key: z.literal(SOURCE_KEY), value: archiveIdentity });
export const RetentionEpochMetaRowSchema = z.strictObject({
	key: z.literal(RETENTION_EPOCH_KEY),
	value: archiveIdentity,
});
export const RevisionMetaRowSchema = z.strictObject({ key: z.literal(REVISION_KEY), value: nonnegativeSafeInteger });
export const BlobBytesMetaRowSchema = z.strictObject({ key: z.literal(BLOB_BYTES_KEY), value: nonnegativeSafeInteger });

export type StoredArchiveRecord = z.infer<typeof StoredArchiveRecordSchema>;
export type SourceMetaRow = z.infer<typeof SourceMetaRowSchema>;
export type RetentionEpochMetaRow = z.infer<typeof RetentionEpochMetaRowSchema>;
export type RevisionMetaRow = z.infer<typeof RevisionMetaRowSchema>;
export type BlobBytesMetaRow = z.infer<typeof BlobBytesMetaRowSchema>;

export interface StoredArchiveBlob {
	key: string;
	digest: string;
	size: number;
	bytes: Blob;
}

/** Open/delete lifecycle for this page's handle on the origin `rooms-history` store. */
export class PageArchiveDatabase {
	opened: Promise<IDBDatabase | null> | null = null;
	deleting: Promise<void> | null = null;

	open(): Promise<IDBDatabase | null> {
		if (this.deleting != null) return this.deleting.then(() => this.open());
		if (this.opened != null) return this.opened;
		this.opened = new Promise((resolve) => {
			let abandoned = false;
			try {
				const req = indexedDB.open(HISTORY_DB, DB_VERSION);
				req.onupgradeneeded = () => {
					const held = req.result;
					if (held.objectStoreNames.length !== 0) {
						req.transaction?.abort();
						return;
					}
					const records = held.createObjectStore(RECORDS, { keyPath: "key" });
					records.createIndex(REVISION_INDEX, "revision", { unique: true });
					records.createIndex(COORDINATES_INDEX, "coordinates", { unique: false });
					held.createObjectStore(BLOBS, { keyPath: "key" });
					held.createObjectStore(META, { keyPath: "key" });
				};
				req.onsuccess = () => {
					const held = req.result;
					if (abandoned || !hasCurrentArchiveSchema(held)) {
						held.close();
						if (!abandoned) resolve(null);
						return;
					}
					held.onversionchange = () => held.close();
					resolve(held);
				};
				req.onerror = () => resolve(null);
				req.onblocked = () => {
					abandoned = true;
					resolve(null);
				};
			} catch {
				resolve(null);
			}
		});
		return this.opened;
	}

	drop(): Promise<void> {
		if (this.deleting != null) return this.deleting;
		const prior = this.opened;
		this.opened = null;
		const work = (async () => {
			(await prior)?.close();
			await new Promise<void>((resolve, reject) => {
				const request = indexedDB.deleteDatabase(HISTORY_DB);
				request.onsuccess = () => resolve();
				request.onerror = () => reject(request.error ?? new Error("browser history deletion failed"));
				request.onblocked = () => reject(new Error("browser history deletion is blocked by another tab"));
			});
		})();
		const settled = work.finally(() => {
			if (this.deleting === settled) this.deleting = null;
		});
		this.deleting = settled;
		return settled;
	}
}

function hasCurrentArchiveSchema(database: IDBDatabase): boolean {
	if (Array.from(database.objectStoreNames).sort().join("\0") !== [BLOBS, META, RECORDS].sort().join("\0")) {
		return false;
	}
	try {
		const tx = database.transaction([RECORDS, BLOBS, META], "readonly");
		const records = tx.objectStore(RECORDS);
		const blobs = tx.objectStore(BLOBS);
		const meta = tx.objectStore(META);
		const revision = records.index(REVISION_INDEX);
		const coordinates = records.index(COORDINATES_INDEX);
		return records.keyPath === "key" && blobs.keyPath === "key" && meta.keyPath === "key" &&
			Array.from(records.indexNames).sort().join("\0") ===
				[COORDINATES_INDEX, REVISION_INDEX].sort().join("\0") &&
			revision.keyPath === "revision" && revision.unique && coordinates.keyPath === "coordinates" &&
			!coordinates.unique;
	} catch {
		return false;
	}
}

export function transactionFailure(tx: IDBTransaction, fallback: string): Error {
	return tx.error ?? new Error(fallback);
}
