// Live attachment capabilities projected from a durable Rooms session.

import * as store from "../store.ts";
import { blobOf } from "../net/files.ts";
import type { AttachmentView, Item, ViewerDirection } from "../types.ts";
import type { AttachedRoomsController } from "./attached.ts";
import { ARCHIVED_BYTES_UNAVAILABLE } from "../archive_attachments.ts";
import { settleCapabilityCleanup } from "../../../lib/capability_cleanup.ts";
import type { PageProjection } from "../store/core.ts";
import type { Attachment } from "../../../lib/attachment.ts";
import type { ArchiveLine } from "../../../lib/archive/protocol.ts";
interface HeldFile {
	readonly mime: string;
	readonly durable: boolean;
	fetch(onProgress: (got: number) => void): Promise<Uint8Array>;
	release(): void;
}

export class AttachedSessionFiles {
	readonly #controller: AttachedRoomsController;
	readonly #projection: PageProjection;
	readonly #stopLineCustody: () => void;
	readonly #files = new Map<number, HeldFile>();
	readonly #urls = new Map<number, string>();
	readonly #progress = new Map<number, { key: string; got: number }>();
	#frame: number | null = null;

	constructor(controller: AttachedRoomsController, projection: PageProjection) {
		this.#controller = controller;
		this.#projection = projection;
		this.#stopLineCustody = this.#projection.onLinesDropped((_key: string, lines: readonly Item[]) => {
			for (const line of lines) {
				if (line.kind === "chat") this.release(line.attachments ?? []);
			}
		});
	}

	hold(attachment: Attachment): AttachmentView {
		const view = store.attachmentView(this.#projection, {
			name: attachment.name,
			mime: attachment.mime,
			size: attachment.size,
			width: attachment.width,
			height: attachment.height,
		});
		this.#files.set(view.id, {
			mime: attachment.mime,
			durable: false,
			fetch: (onProgress) => this.#controller.fetchAttachment(attachment, onProgress),
			release: () => this.#controller.releaseAttachment(attachment),
		});
		return view;
	}

	holdArchived(record: ArchiveLine, index: number): AttachmentView {
		const attachment = record.attachments[index];
		const view = store.attachmentView(this.#projection, {
			name: attachment.name,
			mime: attachment.mime,
			size: attachment.size,
			width: attachment.width,
			height: attachment.height,
			...(attachment.blob == null ? { lost: true, error: ARCHIVED_BYTES_UNAVAILABLE } : {}),
		});
		if (attachment.blob != null) {
			this.#files.set(view.id, {
				mime: attachment.mime,
				durable: true,
				fetch: (onProgress) => this.#controller.fetchArchivedAttachment(record, index, onProgress),
				release: () => {},
			});
		}
		return view;
	}

	release(views: readonly AttachmentView[]): void {
		for (const view of views) this.#release(view.id);
	}

	releaseIncoming(attachments: readonly Attachment[]): void {
		for (const attachment of attachments) {
			settleCapabilityCleanup(
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
		if (view == null || file == null || view.url != null || view.got != null || view.lost === true) return;
		store.updateAttachment(this.#projection, key, id, { got: 0, error: undefined });
		void file.fetch((got) => this.#noteProgress(key, id, got))
			.then((bytes) => {
				if (this.#files.get(id) !== file) return;
				file.release();
				this.#files.delete(id);
				const prior = this.#urls.get(id);
				if (prior != null) URL.revokeObjectURL(prior);
				const url = URL.createObjectURL(blobOf(bytes, file.mime));
				this.#urls.set(id, url);
				this.#progress.delete(id);
				store.updateAttachment(this.#projection, key, id, { got: undefined, error: undefined, url });
			})
			.catch((error) => {
				if (this.#files.get(id) !== file) return;
				this.#progress.delete(id);
				store.updateAttachment(this.#projection, key, id, {
					got: undefined,
					error: error instanceof Error ? error.message : String(error),
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
		for (const url of this.#urls.values()) URL.revokeObjectURL(url);
		this.#urls.clear();
	}

	#noteProgress(key: string, id: number, got: number): void {
		this.#progress.set(id, { key, got });
		if (this.#frame != null) return;
		this.#frame = requestAnimationFrame(() => {
			this.#frame = null;
			for (const [file, progress] of this.#progress) {
				store.updateAttachment(this.#projection, progress.key, file, { got: progress.got });
			}
			this.#progress.clear();
		});
	}

	#release(id: number): void {
		const file = this.#files.get(id);
		if (file != null) {
			this.#files.delete(id);
			settleCapabilityCleanup("attached file capability release failed", file.release);
		}
		const url = this.#urls.get(id);
		if (url != null) {
			URL.revokeObjectURL(url);
			this.#urls.delete(id);
		}
		this.#progress.delete(id);
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
