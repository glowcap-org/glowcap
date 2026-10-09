import type { Attachment } from "../../../lib/attachment.ts";
export type FileData = Uint8Array | import("../../../../../zig-out/wasm/rooms/rooms_browser.js").RoomsBrowserFileView;
// Live attachment capabilities projected from a durable Rooms session.

import * as store from "../store.ts";
import { blobOf } from "../blob.ts";
import type { AttachmentView, Item, ViewerDirection } from "../types.ts";

import { ARCHIVED_BYTES_UNAVAILABLE } from "../archive_attachments.ts";
import { settleViewCleanup } from "./cleanup.ts";
import type { PageProjection } from "../store/core.ts";

import type { ArchiveLine } from "../../../lib/archive/protocol.ts";
import { refusalText } from "../../../lib/text/failure.ts";
export interface HeldFile {
	readonly mime: string;
	readonly durable: boolean;
	fetch(onProgress: (got: number) => void): Promise<FileData>;
	release(): void;
}

import { earlierConnectionBytesUnavailable } from "../../../lib/text/attached.ts";

export const EARLIER_CONNECTION_BYTES_UNAVAILABLE = earlierConnectionBytesUnavailable;

export interface FileDescription {
	name: string;
	mime: string;
	size: number;
	width: number;
	height: number;
}
export interface FileSources<F extends FileDescription> {
	fetchAttachment(file: F, progress: (got: number) => void, signal: AbortSignal): Promise<FileData>;
	releaseAttachment(file: F): void;
	archiveSource(record: ArchiveLine, index: number): HeldFile | null;
}
export class AttachedSessionFiles<F extends FileDescription = Attachment> {
	readonly #controller: FileSources<F>;
	readonly #projection: PageProjection;
	readonly #stopLineCustody: () => void;
	readonly #files = new Map<number, HeldFile>();
	readonly #urls = new Map<number, { url: string; release(): void }>();
	readonly #transfers = new Map<number, symbol>();
	readonly #progress = new Map<number, { key: string; attempt: symbol; got: number }>();
	#frame: number | null = null;

	constructor(controller: FileSources<F>, projection: PageProjection) {
		this.#controller = controller;
		this.#projection = projection;
		this.#stopLineCustody = this.#projection.onLinesDropped((_key: string, lines: readonly Item[]) => {
			for (const line of lines) {
				if (line.kind === "chat") this.release(line.attachments ?? []);
			}
		});
	}

	retains(id: number): boolean {
		return this.#files.has(id);
	}
	hold(attachment: F, unavailable?: string): AttachmentView {
		const view = store.attachmentView(this.#projection, {
			name: attachment.name,
			mime: attachment.mime,
			size: attachment.size,
			width: attachment.width,
			height: attachment.height,
			...(unavailable == null ? {} : { lost: true, error: unavailable }),
		});
		if (unavailable != null) {
			this.releaseIncoming([attachment]);
			return view;
		}
		const stop = new AbortController();
		this.#files.set(view.id, {
			mime: attachment.mime,
			durable: false,
			fetch: (onProgress) => this.#controller.fetchAttachment(attachment, onProgress, stop.signal),
			release: () => {
				stop.abort();
				this.#controller.releaseAttachment(attachment);
			},
		});
		return view;
	}

	holdArchived(
		record: ArchiveLine,
		index: number,
		source?: (record: ArchiveLine, index: number) => HeldFile | null,
	): AttachmentView {
		const attachment = record.attachments[index];
		const view = store.attachmentView(this.#projection, {
			name: attachment.name,
			mime: attachment.mime,
			size: attachment.size,
			width: attachment.width,
			height: attachment.height,
			...(attachment.blob == null ? { lost: true, error: ARCHIVED_BYTES_UNAVAILABLE } : {}),
			...(attachment.blob == null ? {} : { archiveDigest: attachment.blob }),
		});
		const file = source == null ? this.#archivedFile(record, index) : source(record, index);
		if (file != null) this.#files.set(view.id, file);
		return view;
	}

	/** Move an existing view from its live occurrence to the archive's durable
	 * byte source. Presentation identity and any settled object URL stay put.
	 * An in-flight automatic fetch resumes against the durable source instead of
	 * leaving its original intent stranded on an aborted occurrence. */
	adoptArchived(
		key: string,
		id: number,
		record: ArchiveLine,
		index: number,
		source?: (record: ArchiveLine, index: number) => HeldFile | null,
	): void {
		if (this.#files.get(id)?.durable === true) return;
		const durable = source == null ? this.#archivedFile(record, index) : source(record, index);
		if (durable == null) return;
		const prior = this.#files.get(id);
		const transferring = this.#transfers.has(id);
		if (prior != null) {
			settleViewCleanup(this.#projection, "attached file capability release failed", prior.release);
		}
		this.#files.set(id, durable);
		if (!transferring) return;
		this.#transfers.delete(id);
		this.#progress.delete(id);
		store.updateAttachment(this.#projection, key, id, { got: undefined, error: undefined });
		this.open(key, id);
	}

	release(views: readonly AttachmentView[]): void {
		for (const view of views) this.#release(view.id);
	}

	releaseIncoming(attachments: readonly F[]): void {
		for (const attachment of attachments) {
			settleViewCleanup(
				this.#projection,
				"attached file capability release failed",
				() => this.#controller.releaseAttachment(attachment),
			);
		}
	}

	/** Retire live attachment references when their attached transport is replaced.
	 * A loaded object URL is independent of the transport and may keep rendering;
	 * only views whose bytes still come from the dead session become lost. */
	markLost(reason: string, directory?: string): void {
		if (this.#frame != null) cancelAnimationFrame(this.#frame);
		this.#frame = null;
		this.#progress.clear();
		for (const id of [...this.#files.keys()]) {
			if (this.#files.get(id)?.durable === true) continue;
			if (directory != null && !this.#attachmentIsOn(id, directory)) continue;
			this.#markViewLost(id, reason);
			this.#release(id);
		}
	}

	open(key: string, id: number): void {
		const item = store.historyOf(this.#projection, key).find((row) =>
			row.kind === "chat" && row.attachments?.some((attachment) => attachment.id === id)
		);
		const view = item?.kind === "chat" ? item.attachments?.find((attachment) => attachment.id === id) : undefined;
		const file = this.#files.get(id);
		if (view == null || view.url != null || view.got != null || view.lost === true) return;
		// The view can outlive the transport capability that supplied its bytes.
		// A press is still an intent and must settle visibly rather than becoming a
		// silent no-op merely because connection cleanup won the race.
		if (file == null) {
			store.updateAttachment(this.#projection, key, id, {
				error: EARLIER_CONNECTION_BYTES_UNAVAILABLE,
				lost: true,
			});
			return;
		}
		const attempt = Symbol();
		this.#transfers.set(id, attempt);
		store.updateAttachment(this.#projection, key, id, { got: 0, error: undefined });
		void file.fetch((got) => this.#noteProgress(key, id, attempt, got))
			.then((bytes) => {
				if (this.#files.get(id) !== file || this.#transfers.get(id) !== attempt) {
					releaseData(bytes);
					return;
				}
				this.#transfers.delete(id);
				const display = displayData(bytes, file.mime);
				this.#files.delete(id);
				settleViewCleanup(this.#projection, "attached file capability release failed", file.release);
				const prior = this.#urls.get(id);
				this.#urls.delete(id);
				if (prior != null) {
					settleViewCleanup(this.#projection, "attached file display release failed", prior.release);
				}
				this.#urls.set(id, display);
				this.#progress.delete(id);
				store.updateAttachment(this.#projection, key, id, {
					got: undefined,
					error: undefined,
					url: display.url,
				});
			})
			.catch((error) => {
				if (this.#files.get(id) !== file || this.#transfers.get(id) !== attempt) return;
				this.#transfers.delete(id);
				this.#progress.delete(id);
				store.updateAttachment(this.#projection, key, id, {
					got: undefined,
					error: refusalText(error),
				});
			});
	}

	openViewer(key: string, id: number): void {
		store.openViewer(this.#projection, key, id);
		this.open(key, id);
	}

	stepViewer(direction: ViewerDirection): void {
		const key = this.#projection.get().viewing?.key;
		const file = store.stepViewer(this.#projection, direction);
		if (key != null && file != null && file.url == null) this.open(key, file.id);
	}

	close(): void {
		this.#stopLineCustody();
		if (this.#frame != null) cancelAnimationFrame(this.#frame);
		this.#frame = null;
		this.#progress.clear();
		for (const id of [...this.#files.keys()]) this.#release(id);
		for (const id of [...this.#urls.keys()]) this.#release(id);
	}

	#noteProgress(key: string, id: number, attempt: symbol, got: number): void {
		if (this.#transfers.get(id) !== attempt) return;
		this.#progress.set(id, { key, attempt, got });
		if (this.#frame != null) return;
		this.#frame = requestAnimationFrame(() => {
			this.#frame = null;
			for (const [file, progress] of this.#progress) {
				if (this.#transfers.get(file) !== progress.attempt) continue;
				store.updateAttachment(this.#projection, progress.key, file, { got: progress.got });
			}
			this.#progress.clear();
		});
	}

	#archivedFile(record: ArchiveLine, index: number): HeldFile | null {
		const attachment = record.attachments[index];
		if (attachment.blob == null) return null;
		return this.#controller.archiveSource(record, index);
	}

	#release(id: number): void {
		const file = this.#files.get(id);
		if (file != null) {
			this.#files.delete(id);
			settleViewCleanup(this.#projection, "attached file capability release failed", file.release);
		}
		const url = this.#urls.get(id);
		if (url != null) {
			this.#urls.delete(id);
			settleViewCleanup(this.#projection, "attached file display release failed", url.release);
		}
		this.#progress.delete(id);
		this.#transfers.delete(id);
	}

	#attachmentIsOn(id: number, directory: string): boolean {
		for (const conversation of this.#projection.get().convs.values()) {
			if (conversation.dir !== directory) continue;
			if (
				store.historyOf(this.#projection, conversation.key).some((item) =>
					item.kind === "chat" && item.attachments?.some((attachment) => attachment.id === id)
				)
			) return true;
		}
		return false;
	}

	#markViewLost(id: number, reason: string): void {
		for (const conversation of this.#projection.get().convs.values()) {
			if (
				!store.historyOf(this.#projection, conversation.key).some((item) =>
					item.kind === "chat" && item.attachments?.some((attachment) => attachment.id === id)
				)
			) continue;
			store.updateAttachment(this.#projection, conversation.key, id, {
				got: undefined,
				error: reason,
				lost: true,
			});
		}
	}
}

function releaseData(data: FileData): void {
	if (!(data instanceof Uint8Array)) {
		try {
			data.release();
		} finally {
			data.free();
		}
	}
}
function displayData(data: FileData, mime: string): { url: string; release(): void } {
	if (data instanceof Uint8Array) {
		const url = URL.createObjectURL(blobOf(data, mime));
		return { url, release: () => URL.revokeObjectURL(url) };
	}
	return { url: data.url, release: () => releaseData(data) };
}
