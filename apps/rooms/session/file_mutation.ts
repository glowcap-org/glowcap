// Bounded attachment materialization for session file mutations.

import { Ref, retainCleanupFailures, type Session } from "@pancake/runtime";
import { fetchBlob } from "../lib/attachment.ts";
import type { Attachment, AttachmentSource } from "../lib/attachment.ts";
import type { LiveDirectory } from "./live.ts";
import type { RuntimeAttachment } from "./room_files.ts";
import type { Message } from "../lib/room/client.ts";
import { MAX_SCROLLBACK } from "../lib/limits.ts";
import type { PostedLine } from "../lib/posted_line.ts";
import { settleCapabilityCleanup } from "../lib/capability_cleanup.ts";

export interface MaterializedAttachmentSource extends AttachmentSource {
	bytes: Uint8Array<ArrayBuffer>;
	digest: string;
}

export async function materializeAttachmentSources(
	session: Session,
	attachments: readonly Attachment[],
): Promise<MaterializedAttachmentSource[]> {
	const sources: MaterializedAttachmentSource[] = [];
	try {
		for (const attachment of attachments) {
			const bytes = await fetchBlob(session, attachment) as Uint8Array<ArrayBuffer>;
			const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
			sources.push({
				name: attachment.name,
				mime: attachment.mime,
				bytes,
				width: attachment.width,
				height: attachment.height,
				digest: [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join(""),
			});
		}
		return sources;
	} finally {
		for (const attachment of attachments) {
			settleCapabilityCleanup(
				"materialized attachment reference release failed",
				() => session.release(attachment.blob),
			);
		}
	}
}

export async function refileSessionLine(
	directories: ReadonlyMap<string, LiveDirectory>,
	emitDirect: (
		held: LiveDirectory,
		conversationId: string,
		generation: string,
		message: Message,
		editable: boolean,
		files: RuntimeAttachment[],
	) => void,
	conversationId: string,
	lineId: number,
	caption: string,
	keep: readonly number[],
	files: AttachmentSource[],
): Promise<void> {
	for (const held of directories.values()) {
		const room = held.roomRealization.rooms.get(conversationId);
		if (room != null) {
			const line = room.postedLines.get(lineId);
			if (line == null) throw new Error("this Rooms session does not hold authority over that room line");
			const uploads: Ref[] = [];
			try {
				for (const file of files) uploads.push(await room.room.stage(file));
				await line.refile(caption, [...keep]);
				await Promise.all(uploads.map((upload, index) => room.room.upload(upload, files[index])));
			} catch (error) {
				throw await retainCleanupFailures(
					error,
					uploads.map((upload) => async () => {
						await room.room.discard(upload);
					}),
				);
			}
			return;
		}
		const direct = held.directs.get(conversationId);
		if (direct != null) {
			const changed = await direct.refile(held.nick, lineId, caption, keep, files);
			emitDirect(held, conversationId, direct.generation, changed.message, true, changed.files);
			return;
		}
	}
	throw new Error("that conversation is not connected in this Rooms session");
}

export async function sendSessionFiles(
	directories: ReadonlyMap<string, LiveDirectory>,
	sendDirect: (
		held: LiveDirectory,
		conversationId: string,
		caption: string,
		files: AttachmentSource[],
	) => Promise<void>,
	conversationId: string,
	caption: string,
	files: AttachmentSource[],
): Promise<void> {
	for (const held of directories.values()) {
		const room = held.roomRealization.rooms.get(conversationId);
		if (room != null) {
			if (room.pendingLines.length >= MAX_SCROLLBACK) {
				throw new Error("that room has too many line capabilities waiting for their echoes");
			}
			const uploads: Ref[] = [];
			let authority: Promise<PostedLine | null> | null = null;
			let posted = false;
			try {
				for (const file of files) uploads.push(await room.room.stage(file));
				authority = room.room.postFiles(caption);
				room.pendingLines.push(authority);
				await authority;
				posted = true;
				await Promise.all(uploads.map((upload, index) => room.room.upload(upload, files[index])));
			} catch (error) {
				if (!posted && authority != null) {
					const at = room.pendingLines.indexOf(authority);
					if (at >= 0) room.pendingLines.splice(at, 1);
				}
				throw await retainCleanupFailures(
					error,
					uploads.map((upload) => async () => {
						await room.room.discard(upload);
					}),
				);
			}
			return;
		}
		if (held.directs.has(conversationId)) {
			await sendDirect(held, conversationId, caption, files);
			return;
		}
	}
	throw new Error("that conversation is not connected in this Rooms session");
}
