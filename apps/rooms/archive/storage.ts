// Bounded durable storage for the member-owned archive peer.
//
// The file is a compacted snapshot followed by committed JSONL revisions.
// Writes append and fsync one revision; after a bounded delta tail, compaction
// atomically replaces the file. A torn final line is the one state a crash may
// leave and is discarded on restart before serving. Any earlier corruption is
// a startup refusal, never a best-effort rewrite of the member's history.

import {
	type ArchiveFilter,
	ArchiveIndex,
	type ArchiveLine,
	type ArchivePage,
	type ArchiveRecord,
	type ErasableArchiveBackend,
	MAX_ARCHIVE_CONTEXT_BYTES,
	MAX_ARCHIVE_CONVERSATION_BYTES,
	MAX_ARCHIVE_ID_BYTES,
	MAX_ARCHIVE_RECORDS,
	parseArchiveRecord,
} from "../lib/archive/protocol.ts";
import type {
	ArchiveAttachmentAddress,
	ArchivedAttachmentRead,
	ArchivedAttachmentSource,
	ErasableBlobArchiveBackend,
} from "../lib/archive/blobs.ts";
import {
	MAX_ATTACHMENT_BYTES,
	MAX_FILE_NAME,
	MAX_IMAGE_DIM,
	MAX_LINE,
	MAX_MESSAGE_FILES,
	MAX_MIME,
	MAX_NICK,
} from "../lib/limits.ts";
import { boundedText, fixedHex, nonemptyText, nonnegativeSafeInteger, positiveSafeInteger } from "../lib/schema.ts";
import * as z from "zod/mini";
import { appendSynced, atomicWrite } from "./file_io.ts";
import { FileArchiveBlobs } from "./blob_storage.ts";
import { MAX_ARCHIVE_BLOB_BYTES } from "../lib/archive/blobs.ts";

const FILE = "archive.jsonl";
const FORMAT = "glowcap-rooms-member-archive";
const VERSION = 1;
const DEFAULT_COMPACT_DELTA = 512;
/** The protocol's worst-case 5,000-record snapshot fits below this ceiling;
 * the loader refuses a larger file before allocating a string for it. */
const MAX_ARCHIVE_FILE_BYTES = 128 * 1024 * 1024;
const encoder = new TextEncoder();

interface OpenOptions {
	capacity?: number;
	compactDelta?: number;
	maxFileBytes?: number;
	maxBlobBytes?: number;
}

const ArchiveDiskCoordinatesShape = {
	source: nonemptyText(MAX_ARCHIVE_ID_BYTES),
	generation: nonemptyText(MAX_ARCHIVE_ID_BYTES),
	id: nonemptyText(MAX_ARCHIVE_ID_BYTES),
};

const ArchiveDiskAttachmentSchema = z.strictObject({
	name: nonemptyText(MAX_FILE_NAME),
	mime: boundedText(MAX_MIME),
	size: nonnegativeSafeInteger.check(z.maximum(MAX_ATTACHMENT_BYTES)),
	width: nonnegativeSafeInteger.check(z.maximum(MAX_IMAGE_DIM)),
	height: nonnegativeSafeInteger.check(z.maximum(MAX_IMAGE_DIM)),
	blob: z.nullable(fixedHex(32)),
});

export const ArchiveDiskRecordSchema = z.union([
	z.strictObject({
		kind: z.literal("standing"),
		...ArchiveDiskCoordinatesShape,
		directory: nonemptyText(MAX_ARCHIVE_CONTEXT_BYTES),
		room: nonemptyText(MAX_ARCHIVE_CONVERSATION_BYTES),
		nick: boundedText(MAX_NICK),
		at: nonnegativeSafeInteger,
	}),
	z.strictObject({
		kind: z.literal("line"),
		...ArchiveDiskCoordinatesShape,
		conversationKind: z.enum(["room", "direct"]),
		directory: nonemptyText(MAX_ARCHIVE_CONTEXT_BYTES),
		conversation: nonemptyText(MAX_ARCHIVE_CONVERSATION_BYTES),
		from: boundedText(MAX_NICK),
		text: boundedText(MAX_LINE),
		mine: z.boolean(),
		at: nonnegativeSafeInteger,
		state: z.enum(["present", "edited", "withdrawn"]),
		attachments: z.array(ArchiveDiskAttachmentSchema).check(z.maxLength(MAX_MESSAGE_FILES)),
	}),
]);

export const ArchiveFileHeaderSchema = z.strictObject({
	archive: z.literal(FORMAT),
	version: z.literal(VERSION),
	revision: nonnegativeSafeInteger,
});

export const ArchiveDiskEntrySchema = z.strictObject({
	revision: positiveSafeInteger,
	record: ArchiveDiskRecordSchema,
});

type Header = z.infer<typeof ArchiveFileHeaderSchema>;
type DiskEntry = { revision: number; record: ArchiveRecord };
type ArchiveDiskRecord = z.infer<typeof ArchiveDiskRecordSchema>;
interface CommittedRecord {
	revision: number;
	retired: ArchiveRecord | null;
}

function recordFromJson(row: ArchiveDiskRecord): ArchiveRecord {
	if (row.kind === "standing") {
		return parseArchiveRecord([
			"standing",
			row.source,
			row.generation,
			row.id,
			row.directory,
			row.room,
			row.nick,
			BigInt(row.at),
		]);
	}
	return parseArchiveRecord([
		"line",
		row.source,
		row.generation,
		row.id,
		row.conversationKind,
		row.directory,
		row.conversation,
		row.from,
		row.text,
		row.mine,
		BigInt(row.at),
		row.state,
		row.attachments.map((attachment) => [
			attachment.name,
			attachment.mime,
			BigInt(attachment.size),
			BigInt(attachment.width),
			BigInt(attachment.height),
			attachment.blob,
		]),
	]);
}

function decodeJson(line: string, what: string): unknown {
	try {
		return JSON.parse(line);
	} catch {
		throw new Error(`archive file has invalid JSON in ${what}`);
	}
}

function parseJson<T>(line: string, what: string, schema: z.ZodMiniType<T>): T {
	const parsed = z.safeParse(schema, decodeJson(line, what));
	if (!parsed.success) throw new Error(`archive file has an invalid ${what}:\n${z.prettifyError(parsed.error)}`);
	return parsed.data;
}

/// The two fields that stamp which prerelease schema wrote a file, read loosely
/// so a refusal can name them. Rooms has no released persistence predecessor
/// and rewrites nothing; the operator resets the state directory.
const ArchiveFileStampSchema = z.object({
	archive: z.string(),
	version: nonnegativeSafeInteger,
});

function parseHeader(line: string): Header {
	const decoded = decodeJson(line, "header");
	const parsed = z.safeParse(ArchiveFileHeaderSchema, decoded);
	if (parsed.success) return parsed.data;
	const stamp = z.safeParse(ArchiveFileStampSchema, decoded);
	if (stamp.success && (stamp.data.archive !== FORMAT || stamp.data.version !== VERSION)) {
		throw new Error(
			`archive file was written as ${stamp.data.archive} version ${stamp.data.version}, and this build reads ${FORMAT} version ${VERSION}. ` +
				"Rooms does not rewrite prerelease state: stop the peer and remove its state directory (apps/rooms/operating.md).",
		);
	}
	throw new Error(`archive file has an invalid header:\n${z.prettifyError(parsed.error)}`);
}

function parseEntry(line: string): DiskEntry {
	const row = parseJson(line, "record row", ArchiveDiskEntrySchema);
	return { revision: row.revision, record: recordFromJson(row.record) };
}

function snapshotBytes(index: ArchiveIndex): Uint8Array {
	const lines = [
		JSON.stringify({ archive: FORMAT, version: VERSION, revision: index.revision }),
		...index.snapshot().map((entry) => JSON.stringify(entry)),
	];
	return encoder.encode(lines.join("\n") + "\n");
}

/** Append-only storage with a bounded resident index and bounded on-disk tail. */
export class FileArchiveBackend implements ErasableArchiveBackend, ErasableBlobArchiveBackend {
	readonly #path: string;
	readonly #index: ArchiveIndex;
	readonly #capacity: number;
	readonly #compactDelta: number;
	readonly #maxFileBytes: number;
	#blobs: FileArchiveBlobs | null = null;
	#fileBytes = 0;
	#logRows = 0;
	#tail: Promise<void> = Promise.resolve();

	private constructor(path: string, index: ArchiveIndex, options: Required<OpenOptions>) {
		this.#path = path;
		this.#index = index;
		this.#capacity = options.capacity;
		this.#compactDelta = options.compactDelta;
		this.#maxFileBytes = options.maxFileBytes;
	}

	static async open(directory: string, options: OpenOptions = {}): Promise<FileArchiveBackend> {
		const capacity = options.capacity ?? MAX_ARCHIVE_RECORDS;
		const compactDelta = options.compactDelta ?? DEFAULT_COMPACT_DELTA;
		const maxFileBytes = options.maxFileBytes ?? MAX_ARCHIVE_FILE_BYTES;
		const maxBlobBytes = options.maxBlobBytes ?? MAX_ARCHIVE_BLOB_BYTES;
		if (!Number.isSafeInteger(compactDelta) || compactDelta < 1) {
			throw new Error("archive compact delta must be a positive safe integer");
		}
		if (!Number.isSafeInteger(maxFileBytes) || maxFileBytes < 1) {
			throw new Error("archive file ceiling must be a positive safe integer");
		}
		if (!Number.isSafeInteger(maxBlobBytes) || maxBlobBytes < 1) {
			throw new Error("archive blob ceiling must be a positive safe integer");
		}
		await Deno.mkdir(directory, { recursive: true, mode: 0o700 });
		const path = `${directory}/${FILE}`;
		const backend = new FileArchiveBackend(path, new ArchiveIndex(capacity), {
			capacity,
			compactDelta,
			maxFileBytes,
			maxBlobBytes,
		});
		try {
			await backend.#load();
		} catch (error) {
			if (!(error instanceof Deno.errors.NotFound)) throw error;
			await backend.#compact();
		}
		backend.#blobs = await FileArchiveBlobs.open(directory, backend.#index, maxBlobBytes);
		return backend;
	}

	async #load(): Promise<void> {
		const stat = await Deno.stat(this.#path);
		if (stat.size > this.#maxFileBytes) throw new Error("archive file exceeds its byte ceiling");
		const text = await Deno.readTextFile(this.#path);
		const complete = text.endsWith("\n");
		const lines = text.split("\n");
		lines.pop();
		if (lines.length === 0) throw new Error("archive file has no complete header");

		const header = parseHeader(lines[0]);
		const rows = lines.slice(1);
		if (rows.length > MAX_ARCHIVE_RECORDS + this.#compactDelta) {
			throw new Error("archive file exceeds its revision-row ceiling");
		}
		const entries = rows.map(parseEntry);
		const snapshot: DiskEntry[] = [];
		let at = 0;
		let prior = 0;
		while (at < entries.length && entries[at].revision <= header.revision) {
			const entry = entries[at];
			if (entry.revision <= prior) throw new Error("archive snapshot rows are not ordered");
			snapshot.push(entry);
			prior = entry.revision;
			at += 1;
		}
		this.#index.restore(header.revision, snapshot);
		for (; at < entries.length; at += 1) {
			const entry = entries[at];
			this.#index.apply(entry.revision, entry.record);
		}
		this.#fileBytes = stat.size;
		this.#logRows = entries.length;
		// A crash can tear only the append tail. Rewrite the recovered current
		// state now, or a later append would turn that fragment into middle-file
		// corruption on the next restart.
		if (!complete) await this.#compact();
	}

	put(record: ArchiveRecord): Promise<number> {
		const run = this.#tail.then(async () => {
			const prior = record.kind === "line" ? this.#index.line(record) : null;
			const checked = record.kind === "line"
				? this.#requireBlobs().preserve(prior, {
					...record,
					attachments: record.attachments.map((attachment) => ({ ...attachment, blob: null })),
				})
				: record;
			const committed = await this.#commitRecord(checked);
			await this.#settleBlobCleanup(committed.retired, checked);
			return committed.revision;
		});
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	putWithAttachments(record: ArchiveLine, sources: readonly ArchivedAttachmentSource[]) {
		const run = this.#tail.then(async () => {
			const submitted = {
				...record,
				attachments: record.attachments.map((attachment) => ({ ...attachment, blob: null })),
			};
			const staged = await this.#requireBlobs().stage(submitted, sources, this.#index.retiredBy(submitted));
			try {
				const committed = await this.#commitRecord(staged.record);
				await this.#settleBlobCleanup(committed.retired, staged.record);
				return committed.revision;
			} catch (error) {
				await this.#requireBlobs().abort(staged.created);
				throw error;
			}
		});
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	async readAttachment(address: ArchiveAttachmentAddress): Promise<ArchivedAttachmentRead | null> {
		await this.#tail;
		return await this.#requireBlobs().read(address);
	}

	clear(): Promise<void> {
		const run = this.#tail.then(async () => {
			const bytes = encoder.encode(
				JSON.stringify({
					archive: FORMAT,
					version: VERSION,
					revision: this.#index.revision,
				}) + "\n",
			);
			await atomicWrite(this.#path, bytes);
			this.#index.clear();
			this.#fileBytes = bytes.length;
			this.#logRows = 0;
			// The empty archive is the commit point. If byte cleanup fails, no
			// retained line can reach the orphan and a later clear retries removal.
			await this.#requireBlobs().clear();
		});
		this.#tail = run.then(() => {}, () => {});
		return run;
	}

	async #commitRecord(record: ArchiveRecord): Promise<CommittedRecord> {
		if (this.#index.revision === Number.MAX_SAFE_INTEGER) {
			throw new Error("archive revision space is exhausted");
		}
		if (this.#logRows - this.#index.size >= this.#compactDelta) await this.#compact();
		const revision = this.#index.revision + 1;
		const bytes = encoder.encode(JSON.stringify({ revision, record }) + "\n");
		if (this.#fileBytes + bytes.length > this.#maxFileBytes) {
			await this.#compact();
			if (this.#fileBytes + bytes.length > this.#maxFileBytes) {
				return await this.#commitProposedSnapshot(revision, record);
			}
		}
		await appendSynced(this.#path, bytes);
		const retired = this.#index.apply(revision, record);
		this.#fileBytes += bytes.length;
		this.#logRows += 1;
		return { revision, retired };
	}

	async #settleBlobCleanup(retired: ArchiveRecord | null, next: ArchiveRecord) {
		try {
			await this.#requireBlobs().commit(retired, next);
		} catch (error) {
			// The line is already committed. Any undeleted content is an orphan and
			// startup pruning owns its eventual cleanup.
			console.error(
				`archive blob cleanup after record commit failed: ${error instanceof Error ? error.message : error}`,
			);
		}
	}

	#requireBlobs(): FileArchiveBlobs {
		if (this.#blobs == null) throw new Error("archive blob storage is not open");
		return this.#blobs;
	}

	/** When an append would cross the byte ceiling, commit the post-write state
	 * directly. This matters for a replacement or eviction: the old snapshot may
	 * not fit beside the event even though the state after applying it does. */
	async #commitProposedSnapshot(revision: number, record: ArchiveRecord): Promise<CommittedRecord> {
		const proposed = new ArchiveIndex(this.#capacity);
		proposed.restore(this.#index.revision, this.#index.snapshot());
		const retired = proposed.apply(revision, record);
		const bytes = snapshotBytes(proposed);
		if (bytes.length > this.#maxFileBytes) {
			throw new Error("archive file ceiling cannot hold the next record");
		}
		await atomicWrite(this.#path, bytes);
		this.#index.restore(proposed.revision, proposed.snapshot());
		this.#fileBytes = bytes.length;
		this.#logRows = proposed.size;
		return { revision, retired };
	}

	async read(filter: ArchiveFilter, after: number, limit: number): Promise<ArchivePage> {
		await this.#tail;
		return this.#index.read(filter, after, limit);
	}

	peekLine(filter: ArchiveFilter): ArchiveLine | null {
		return this.#index.matchingLine(filter);
	}

	async #compact(): Promise<void> {
		const bytes = snapshotBytes(this.#index);
		if (bytes.length > this.#maxFileBytes) throw new Error("archive snapshot exceeds its byte ceiling");
		await atomicWrite(this.#path, bytes);
		this.#fileBytes = bytes.length;
		this.#logRows = this.#index.size;
	}
}
