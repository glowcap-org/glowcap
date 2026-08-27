// Attachment-reference custody for one live durable room membership.

import type { Attachment } from "../lib/attachment.ts";
import { MAX_ROOM_ATTACHMENT_BYTES, MAX_SCROLLBACK } from "../lib/limits.ts";
import type { Message, Room } from "../lib/room_client.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";

export interface RuntimeAttachment {
	/** Remote attachments carry their live capability. Locally sent direct
	 * attachments carry only this bounded descriptor; the session observer
	 * mints a per-view reader for either form. */
	attachment?: Attachment;
	name: string;
	mime: string;
	size: number;
	width: number;
	height: number;
	read(offset: number, maxLen: number): Promise<Uint8Array>;
	/** Owned bytes for a durable archive write, started at record admission. */
	materialize?(): Promise<Uint8Array>;
}

export class RoomFileCustody {
	readonly #room: Room;
	readonly #files = new Map<number, Attachment[]>();
	#bytes = 0;

	constructor(room: Room) {
		this.#room = room;
	}

	apply(message: Message): void {
		if (message.lineId == null) return;
		const previous = this.#files.get(message.lineId);
		if (message.change === "withdrawn") {
			this.#releaseLine(message.lineId);
			return;
		}
		if (message.change !== "refiled" && (message.change !== "said" || message.attachments.length === 0)) return;
		if (previous != null) {
			this.#bytes -= this.#size(previous);
			this.#release(previous.filter((attachment) => !message.attachments.includes(attachment)));
		}
		if (message.attachments.length === 0) this.#files.delete(message.lineId);
		else {
			this.#files.set(message.lineId, message.attachments);
			this.#bytes += this.#size(message.attachments);
		}
		while (this.#files.size > MAX_SCROLLBACK || this.#bytes > MAX_ROOM_ATTACHMENT_BYTES) {
			const oldest = this.#files.keys().next().value as number | undefined;
			if (oldest == null) break;
			this.#releaseLine(oldest);
		}
	}

	project(message: Message): RuntimeAttachment[] {
		return message.attachments.map((attachment) => ({
			attachment,
			name: attachment.name,
			mime: attachment.mime,
			size: attachment.size,
			width: attachment.width,
			height: attachment.height,
			read: (offset: number, maxLen: number) => this.#room.readFile(attachment, offset, maxLen),
		}));
	}

	close(): void {
		for (const attachments of this.#files.values()) this.#release(attachments);
		this.#files.clear();
		this.#bytes = 0;
	}

	#releaseLine(lineId: number): void {
		const attachments = this.#files.get(lineId);
		if (attachments == null) return;
		this.#files.delete(lineId);
		this.#bytes -= this.#size(attachments);
		this.#release(attachments);
	}

	#size(attachments: readonly Attachment[]): number {
		return attachments.reduce((total, attachment) => total + attachment.size, 0);
	}

	#release(attachments: readonly Attachment[]): void {
		for (const attachment of attachments) {
			settleCapabilityCleanup("room attachment release failed", () => this.#room.release(attachment));
		}
	}
}
