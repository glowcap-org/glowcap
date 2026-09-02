// Selected archive capability custody for one durable Rooms session.

import { type Ref, retainCleanupFailures, type Runtime, type Session } from "@glowcap/runtime";
import {
	ALL_ARCHIVE_RECORDS,
	type ArchiveConversationKind,
	type ArchiveCoordinates,
	type ArchiveFilter,
	type ArchiveLine,
	type ArchivePage,
	type ArchiveRecord,
	type ArchiveStanding,
	type ErasableArchiveBackend,
	MAX_ARCHIVE_READ,
	MemoryArchiveBackend,
	putArchive,
	putArchiveWithAttachments,
	readAllArchiveRecords,
	readArchive,
	readArchiveAttachment,
} from "../lib/archive/protocol.ts";
import { issueArchiveShare, listArchiveShares, revokeArchiveShare } from "../lib/archive/client.ts";
import { ARCHIVE_CANNOT_MINT_SHARE } from "../lib/archive/durable_protocol.ts";
import { type ArchivedAttachmentSource, isBlobArchiveBackend, lineAttachmentAddress } from "../lib/archive/blobs.ts";
import { fetchBlobChunk } from "../lib/attachment.ts";
import type { Message } from "../lib/room/client.ts";
import type { RuntimeAttachment } from "./room_files.ts";
import { parseRoomsSturdyref } from "../lib/locator.ts";
import { BLOB_CHUNK, MAX_ARCHIVE_PENDING_ATTACHMENT_BYTES } from "../lib/limits.ts";

interface SessionArchiveMessage {
	keep: boolean;
	generation: string | null;
	kind: ArchiveConversationKind;
	directory: string;
	conversation: string;
	nick: string;
	message: Message;
	files: RuntimeAttachment[];
}

interface HeldArchive {
	sturdyref: string;
	session: Session;
	capability: Ref;
}

export interface HeldArchivedAttachment extends ArchivedAttachmentSource {
	release(): void;
}

function retainRuntimeAttachment(file: RuntimeAttachment): RuntimeAttachment {
	const loading = file.materialize?.() ?? materializeRuntimeAttachment(file);
	// The queued archive write observes this same promise. Mark an early refusal
	// observed now without replacing the promise or its eventual diagnostic.
	void loading.catch(() => undefined);
	return {
		name: file.name,
		mime: file.mime,
		size: file.size,
		width: file.width,
		height: file.height,
		materialize: () => loading,
		read: (offset, maxLength) =>
			loading.then((bytes) => {
				if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(maxLength) || maxLength <= 0) {
					throw new Error("archive attachment reads need a bounded offset and length");
				}
				if (bytes.length !== file.size) throw new Error("archive attachment materialized an unexpected size");
				if (offset >= bytes.length) return new Uint8Array();
				return bytes.subarray(offset, Math.min(bytes.length, offset + maxLength, offset + BLOB_CHUNK));
			}),
	};
}

async function materializeRuntimeAttachment(file: RuntimeAttachment): Promise<Uint8Array> {
	const bytes = new Uint8Array(file.size);
	for (let offset = 0; offset < file.size; offset += BLOB_CHUNK) {
		const length = Math.min(BLOB_CHUNK, file.size - offset);
		const chunk = await file.read(offset, length);
		if (!(chunk instanceof Uint8Array) || chunk.length !== length) {
			throw new Error(`archive attachment answered ${chunk?.length ?? 0} of ${length} requested bytes`);
		}
		bytes.set(chunk, offset);
	}
	return bytes;
}

export class DurableRoomsArchive {
	readonly #runtime: Runtime;
	readonly #source: string;
	readonly #local: ErasableArchiveBackend;
	readonly #issue: (error: unknown | null) => void;
	#held: HeldArchive | null = null;
	#prepared: HeldArchive | null = null;
	#writes: Promise<void> = Promise.resolve();
	#pendingFileBytes = 0;
	#eraseRequired = false;
	#stood = new Set<string>();

	constructor(
		runtime: Runtime,
		source: string,
		issue: (error: unknown | null) => void,
		local: ErasableArchiveBackend = new MemoryArchiveBackend(),
	) {
		this.#runtime = runtime;
		this.#source = source;
		this.#issue = issue;
		this.#local = local;
	}

	async reconcile(sturdyref: string | null): Promise<void> {
		if (this.#held?.sturdyref === sturdyref) return;
		await this.#retire();
		if (sturdyref == null) {
			await this.#retirePrepared();
			this.#issue(null);
			return;
		}
		try {
			this.#held = this.#prepared?.sturdyref === sturdyref ? this.#takePrepared() : await this.#open(sturdyref);
			this.#issue(null);
		} catch (error) {
			this.#issue(error);
		}
	}

	async prepare(sturdyref: string): Promise<void> {
		if (this.#held?.sturdyref === sturdyref || this.#prepared?.sturdyref === sturdyref) return;
		await this.#retirePrepared();
		this.#prepared = await this.#open(sturdyref);
	}

	record(
		input: Omit<ArchiveLine, "source" | "id"> & { id?: string },
		files: RuntimeAttachment[] = [],
	): ArchiveCoordinates {
		const held = this.#held;
		const eraseBeforeWrite = held == null && this.#eraseRequired;
		const { id = crypto.randomUUID(), ...line } = input;
		const record: ArchiveLine = { ...line, source: this.#source, id };
		let archivedFiles = files;
		const fileBytes = files.reduce((sum, file) => sum + file.size, 0);
		if (fileBytes > 0) {
			if (this.#pendingFileBytes + fileBytes > MAX_ARCHIVE_PENDING_ATTACHMENT_BYTES) {
				archivedFiles = [];
				this.#issue(new Error("archive attachment writes are waiting at their memory ceiling"));
			} else {
				this.#pendingFileBytes += fileBytes;
				archivedFiles = files.map(retainRuntimeAttachment);
			}
		}
		this.#writes = this.#writes.then(
			() => eraseBeforeWrite ? this.#prepareLocalAccess() : undefined,
			() => eraseBeforeWrite ? this.#prepareLocalAccess() : undefined,
		).then(() => this.#put(held, record, archivedFiles)).catch((error) => this.#issue(error)).finally(() => {
			if (archivedFiles.length > 0) this.#pendingFileBytes -= fileBytes;
		});
		return { source: record.source, generation: record.generation, id: record.id };
	}

	recordMessage(input: SessionArchiveMessage): ArchiveCoordinates | null {
		const { message } = input;
		if (
			!input.keep || input.generation == null || message.system ||
			message.text === "" && input.files.length === 0 && message.change !== "withdrawn"
		) return null;
		const coords = this.record({
			kind: "line",
			...(message.lineId == null ? {} : { id: String(message.lineId) }),
			generation: input.generation,
			conversationKind: input.kind,
			directory: input.directory,
			conversation: input.conversation,
			from: message.from,
			text: message.text,
			mine: message.from === input.nick,
			at: Date.now(),
			state: message.change === "withdrawn"
				? "withdrawn"
				: message.change === "edited" || message.change === "refiled"
				? "edited"
				: "present",
			attachments: message.change === "withdrawn"
				? []
				: input.files.map(({ name, mime, size, width, height }) => ({
					name,
					mime,
					size,
					width,
					height,
					blob: null,
				})),
		}, message.change === "withdrawn" ? [] : input.files);
		if (coords != null && input.kind === "room") {
			this.#rememberStanding(input.directory, input.conversation, input.generation, input.nick);
		}
		return coords;
	}

	#rememberStanding(directory: string, conversation: string, generation: string, nick: string): void {
		if (nick === "") return;
		const key = `${directory}\u0000${conversation}\u0000${generation}`;
		if (this.#stood.has(key)) return;
		this.#stood.add(key);
		const held = this.#held;
		const standing: ArchiveStanding = {
			kind: "standing",
			source: this.#source,
			generation,
			id: "standing",
			directory,
			room: conversation,
			nick,
			at: Date.now(),
		};
		this.#writes = this.#writes.then(
			() => this.#put(held, standing, []),
			() => this.#put(held, standing, []),
		).catch((error) => this.#issue(error));
	}

	async read(kind: ArchiveConversationKind, directory: string, conversation: string): Promise<ArchiveRecord[]> {
		await this.#writes;
		const held = this.#held;
		const filter = {
			...ALL_ARCHIVE_RECORDS,
			kind: "line",
			conversationKind: kind,
			directory,
			conversation,
		} as const;
		if (held != null) return await readAllArchiveRecords(held.session, held.capability, filter);
		await this.#prepareLocalAccess();
		const records: ArchiveRecord[] = [];
		let after = 0;
		let more = true;
		while (more) {
			const page = await this.#local.read(filter, after, MAX_ARCHIVE_READ);
			records.push(...page.records.map((entry) => entry.record));
			more = page.more;
			after = page.next;
		}
		return records;
	}

	async attachment(record: ArchiveLine, index: number): Promise<HeldArchivedAttachment | null> {
		const metadata = record.attachments[index];
		if (metadata?.blob == null) return null;
		const held = this.#held;
		if (held != null) {
			const attachment = await readArchiveAttachment(held.session, held.capability, record, index);
			if (attachment == null) return null;
			let released = false;
			return {
				...metadata,
				read: (offset, maxLength) => fetchBlobChunk(held.session, attachment, offset, maxLength),
				release: () => {
					if (released) return;
					released = true;
					held.session.release(attachment.blob);
				},
			};
		}
		if (!isBlobArchiveBackend(this.#local)) return null;
		const found = await this.#local.readAttachment(lineAttachmentAddress(record, index));
		return found == null ? null : { ...found.attachment, release: () => {} };
	}

	/** Erase the session-owned archive after all admitted writes. A selected peer
	 * remains a separate capability with no erase verb; disabling retention only
	 * stops future writes there. */
	clearLocal(): Promise<void> {
		this.#eraseRequired = true;
		const cleared = this.#writes.then(
			() => this.#prepareLocalAccess(),
			() => this.#prepareLocalAccess(),
		);
		this.#writes = cleared.catch((error) => this.#issue(error));
		return cleared;
	}

	/** Retry a previously refused local erase at a runtime reconciliation point. */
	settleLocalErase(): Promise<void> {
		return this.#prepareLocalAccess();
	}

	/** Read one bounded page for a forwarding facet. The selected remote archive
	 * retains its own validation; the local backend is checked by archiveBehavior
	 * before any page crosses the direct session. */
	async readPage(filter: ArchiveFilter, after: number, limit: number): Promise<ArchivePage> {
		await this.#writes;
		const held = this.#held;
		if (held != null) return await readArchive(held.session, held.capability, filter, after, limit);
		await this.#prepareLocalAccess();
		return await this.#local.read(filter, after, limit);
	}

	issueShare(id: string, label: string, filter: ArchiveFilter): Promise<string> {
		const held = this.#held;
		if (held == null) return Promise.reject(new Error(ARCHIVE_CANNOT_MINT_SHARE));
		return issueArchiveShare(held.session, held.capability, id, label, filter);
	}

	revokeShare(id: string): Promise<boolean> {
		const held = this.#held;
		if (held == null) return Promise.reject(new Error(ARCHIVE_CANNOT_MINT_SHARE));
		return revokeArchiveShare(held.session, held.capability, id);
	}

	listShares(): Promise<import("../lib/archive/facet.ts").ArchiveDurableShareView[]> {
		const held = this.#held;
		if (held == null) return Promise.reject(new Error(ARCHIVE_CANNOT_MINT_SHARE));
		return listArchiveShares(held.session, held.capability);
	}

	async close(): Promise<void> {
		await this.#retire();
		await this.#retirePrepared();
	}

	async #retire(): Promise<void> {
		await this.#writes;
		const held = this.#held;
		this.#held = null;
		if (held != null) await held.session.close().catch((error) => this.#issue(error));
	}

	async #retirePrepared(): Promise<void> {
		const prepared = this.#prepared;
		this.#prepared = null;
		if (prepared != null) await prepared.session.close().catch((error) => this.#issue(error));
	}

	#takePrepared(): HeldArchive {
		const prepared = this.#prepared;
		if (prepared == null) throw new Error("the prepared archive capability is missing");
		this.#prepared = null;
		return prepared;
	}

	async #open(sturdyref: string): Promise<HeldArchive> {
		const parsed = parseRoomsSturdyref(sturdyref);
		const session = await this.#runtime.connect(parsed.locator);
		try {
			const capability = await session.enliven(sturdyref);
			await readArchive(session, capability, ALL_ARCHIVE_RECORDS, 0, 1);
			return { sturdyref, session, capability };
		} catch (error) {
			throw await retainCleanupFailures(error, [() => session.close()]);
		}
	}

	async #put(held: HeldArchive | null, record: ArchiveRecord, files: RuntimeAttachment[]): Promise<void> {
		if (record.kind !== "line" || files.length === 0) {
			if (held == null) await this.#local.put(record);
			else await putArchive(held.session, held.capability, record);
			return;
		}
		const sources = files.map((file) => ({
			name: file.name,
			mime: file.mime,
			size: file.size,
			width: file.width,
			height: file.height,
			read: file.read,
		}));
		if (held != null) {
			await putArchiveWithAttachments(held.session, held.capability, record, sources);
		} else if (isBlobArchiveBackend(this.#local)) {
			await this.#local.putWithAttachments(record, sources.map((source) => ({ ...source, blob: null })));
		} else await this.#local.put(record);
	}

	async #prepareLocalAccess(): Promise<void> {
		if (!this.#eraseRequired) return;
		await this.#local.clear();
		this.#eraseRequired = false;
		this.#issue(null);
	}
}
