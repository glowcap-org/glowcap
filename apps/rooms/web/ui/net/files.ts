// A posted file's bytes, from the capability that carries them to the picture on
// screen.
//
// Nothing here knows whether a file came from a room or from the person you are
// talking to. Both hand this layer the same thing — a capability to read bounded
// chunks from — and the difference between them is only who hosts it, which the
// two `hold*` wrappers close over and nobody below them asks about again.
//
// Two costs are owned here rather than left to callers. A file's bytes arrive in
// chunks and each one would otherwise be a store write, so progress is coalesced
// to at most one update per frame; and every picture drawn from bytes is an
// object URL the browser keeps until it is told otherwise, so each is remembered
// against the file that shows it and released when that file's line goes.

import { type Attachment, type AttachmentSource, fetchBlob } from "../../../lib/attachment.ts";
import type { Session } from "@pancake/runtime";
import type { Room } from "../../../lib/room_client.ts";
import { BLOB_EXPIRED, roomErrorOf } from "../../../lib/errors.ts";
import * as store from "../store.ts";
import type { DmConv, Item, RoomConv, ViewerDirection } from "../types.ts";
import { reason } from "./common.ts";
import { convSession, type HeldFile, isCurrent, type Live } from "./live.ts";

/** Keep transfer cadence out of React. Parallel files replace their own latest
 * byte count in a session-bounded map, then one animation frame publishes every
 * conversation's visible progress with one history copy apiece. */
export function noteAttachmentProgress(session: Live, key: string, id: number, got: number): void {
	let updates = session.progress.pending.get(key);
	if (updates === undefined) {
		updates = new Map();
		session.progress.pending.set(key, updates);
	}
	updates.set(id, { got });
	if (session.progress.frame !== null) return;
	session.progress.frame = requestAnimationFrame(() => {
		session.progress.frame = null;
		const pending = session.progress.pending;
		session.progress.pending = new Map();
		if (!isCurrent(session)) return;
		for (const [conversation, fields] of pending) store.updateAttachments(conversation, fields);
	});
}

/** A URL, completion, or error is terminal presentation state. Remove queued
 * byte counts for those files before publishing it synchronously, so a frame
 * already in flight cannot overwrite the terminal answer. */
export function discardAttachmentProgress(session: Live, key: string, ids: Iterable<number>): void {
	const pending = session.progress.pending.get(key);
	if (pending !== undefined) {
		for (const id of ids) pending.delete(id);
		if (pending.size === 0) session.progress.pending.delete(key);
	}
	if (session.progress.pending.size === 0 && session.progress.frame !== null) {
		cancelAnimationFrame(session.progress.frame);
		session.progress.frame = null;
	}
}

export function commitAttachmentUpdates(
	session: Live,
	key: string,
	updates: ReadonlyMap<number, store.AttachmentFields>,
): void {
	discardAttachmentProgress(session, key, updates.keys());
	store.updateAttachments(key, updates);
}

export function commitAttachment(
	session: Live,
	key: string,
	id: number,
	fields: store.AttachmentFields,
): void {
	commitAttachmentUpdates(session, key, new Map([[id, fields]]));
}

/** A picture's own pixel size, or nothing when it is not one or the browser
 * will not decode it. Sent with the file so every reader can leave the right
 * space before the bytes arrive, which is what keeps a log of images from
 * jumping as each one lands. */
export async function measureImage(
	file: File,
	mime: string,
): Promise<{ width?: number; height?: number }> {
	if (!mime.startsWith("image/")) return {};
	try {
		const bitmap = await createImageBitmap(file);
		const size = { width: bitmap.width, height: bitmap.height };
		bitmap.close();
		return size;
	} catch {
		// An image this browser cannot decode still posts; it just arrives
		// without a shape to reserve.
		return {};
	}
}

/** Said wherever this window finds it no longer holds a file's reference. It
 * reads as a fact about this window rather than about the room, because the
 * room may well still have the bytes: what ended was the connection they were
 * offered over. */
const FILE_GONE_WITH_ITS_CONNECTION = "this file came over an earlier connection and cannot be fetched again";

/** Fetch a posted file's bytes and hand it an object URL to draw or download
 * from. Idempotent: a file already holding its bytes, or already
 * fetching them, is left alone. */
export function openAttachment(key: string, id: number): void {
	const conv = store.getConv(key);
	const item = conv?.history.find((line) => line.kind === "chat" && line.attachments?.some((file) => file.id === id));
	const attachment = item?.kind === "chat" ? item.attachments?.find((file) => file.id === id) : undefined;
	if (attachment === undefined) return;
	if (attachment.url !== undefined || attachment.got !== undefined) return;
	// Nothing left to try for this one: it says why, and its row has already
	// dropped the control that would ask. Checked here because the viewer steps
	// through pictures by asking for them, so it reaches this without a press.
	if (attachment.lost === true) return;
	// A file reference is only good on the connection it arrived over, and this
	// window holds none for this one. Pressing again would land here again, so
	// the row says what happened and stops offering.
	const owner = convSession(key);
	const row = owner?.files.get(id);
	if (owner === null || row === undefined) {
		store.updateAttachment(key, id, { error: FILE_GONE_WITH_ITS_CONNECTION, lost: true });
		return;
	}
	commitAttachment(owner, key, id, { got: 0, error: undefined });
	row.fetch((got) => {
		if (isCurrent(owner) && owner.files.get(id) === row) noteAttachmentProgress(owner, key, id, got);
	})
		.then((bytes) => {
			// Conversation teardown releases and removes the held capability. A
			// fetch that settled at the same time must not mint a URL after that
			// cleanup, or attach its bytes to a later session.
			if (!isCurrent(owner) || owner.files.get(id) !== row) return;
			row.release();
			owner.files.delete(id);
			commitAttachment(owner, key, id, {
				got: undefined,
				url: keepObjectUrl(owner, id, blobOf(bytes, row.attachment.mime)),
			});
		})
		.catch((err) => {
			if (!isCurrent(owner) || owner.files.get(id) !== row) return;
			// A room drops its oldest files to stay under its media ceiling, and
			// keeps saying so on every later read. Nothing brings that one back,
			// so the row must not go on inviting a press.
			const evicted = roomErrorOf(err)?.code === BLOB_EXPIRED;
			commitAttachment(owner, key, id, { got: undefined, error: reason(err), lost: evicted ? true : undefined });
		});
}

/** Move the viewer through this conversation's images, fetching the next one
 * on demand through the same transfer path as an explicit press in the log. */
export function stepViewer(direction: ViewerDirection): void {
	const key = store.get().viewing?.key;
	const file = store.stepViewer(direction);
	if (key !== undefined && file !== null && file.url === undefined) openAttachment(key, file.id);
}

export function holdRoomFile(room: Room, attachment: Attachment): HeldFile {
	return {
		attachment,
		fetch: (onProgress) => room.fetch(attachment, onProgress),
		release: () => {
			try {
				room.release(attachment);
			} catch {
				// The room session already reclaimed it.
			}
		},
	};
}

export function holdDirectFile(
	session: Session,
	attachment: Attachment,
): HeldFile {
	return {
		attachment,
		fetch: (onProgress) => fetchBlob(session, attachment, onProgress),
		release: () => {
			try {
				session.release(attachment.blob);
			} catch {
				// The direct session already reclaimed it.
			}
		},
	};
}

/** A Blob over exactly these bytes. Copied into an array of its own because a
 * `Uint8Array` may be a view into a larger buffer, and because `BlobPart`
 * admits an `ArrayBuffer` but not the `SharedArrayBuffer` a view's type
 * allows. */
export function blobOf(bytes: Uint8Array, mime: string): Blob {
	const own = new Uint8Array(bytes.byteLength);
	own.set(bytes);
	return new Blob([own.buffer], { type: mime });
}

/** One browser file as the shared attachment layer reads it. The description
 * is also validated before Send clears the composer, so refusal preserves the
 * reader's draft and attached chips. */
export function pickedSource(file: File): AttachmentSource {
	return {
		name: file.name,
		mime: file.type || "application/octet-stream",
		size: file.size,
		read: async (offset: number, length: number) =>
			new Uint8Array(await file.slice(offset, offset + length).arrayBuffer()),
	};
}

/** Mint the object URL one file owns, replacing any retry's prior URL. The
 * session is the one whose capability produced the bytes, and it is what the URL
 * is released with when that directory goes. */
export function keepObjectUrl(owner: Live, id: number, blob: Blob): string {
	const url = URL.createObjectURL(blob);
	const old = owner.objectUrls.get(id);
	if (old !== undefined) URL.revokeObjectURL(old);
	owner.objectUrls.set(id, url);
	return url;
}

/** Release every object URL and blob capability this session minted. */
export function releaseFiles(session: Live): void {
	if (session.progress.frame !== null) cancelAnimationFrame(session.progress.frame);
	session.progress.frame = null;
	session.progress.pending.clear();
	for (const url of session.objectUrls.values()) URL.revokeObjectURL(url);
	session.objectUrls.clear();
	for (const row of session.files.values()) row.release();
	session.files.clear();
	session.outgoing.clear();
	// A fetch still running has just lost the reference it was reading from, and
	// nothing will settle it now. Its row is drawn as loading, and a row that is
	// loading is one `openAttachment` refuses to restart, so left alone it
	// shimmers at nothing for the life of the tab, with no control to press.
	for (const conv of store.get().convs.values()) {
		if (conv.dir !== session.id) continue;
		const stalled = new Map<number, store.AttachmentFields>();
		for (const item of conv.history) {
			if (item.kind !== "chat") continue;
			for (const file of item.attachments ?? []) {
				if (file.got === undefined) continue;
				stalled.set(file.id, { got: undefined, error: FILE_GONE_WITH_ITS_CONNECTION, lost: true });
			}
		}
		store.updateAttachments(conv.key, stalled);
	}
}

/** Release media whose conversation history is about to disappear. */
export function releaseConversationFiles(session: Live, conv: RoomConv | DmConv): void {
	releaseLines(session, conv.key, conv.history);
}

/** Let go of everything a set of lines was holding: the bytes of each file they
 * carried, the URL a picture was drawn from, and the reference that governed one
 * of our own. Called for a conversation that is going, and for the oldest lines
 * of one that has passed the far end of its log. */
/** Let go of one file's live state on a session: the blob capability behind it
 * and the object URL a picture was drawn from. The store row is the caller's to
 * update; this is only the references a page does not draw. Used both when a
 * line leaves and when a refile drops a file the line no longer carries. */
export function releaseHeldFile(session: Live, id: number): void {
	const held = session.files.get(id);
	if (held !== undefined) held.release();
	session.files.delete(id);
	const url = session.objectUrls.get(id);
	if (url !== undefined) URL.revokeObjectURL(url);
	session.objectUrls.delete(id);
}

export function releaseLines(session: Live, key: string, lines: readonly Item[]): void {
	const fileIds: number[] = [];
	for (const item of lines) {
		if (item.kind !== "chat") continue;
		for (const attachment of item.attachments ?? []) {
			fileIds.push(attachment.id);
			releaseHeldFile(session, attachment.id);
		}
		session.outgoing.delete(item.id);
		// Nothing is left to change or take back once the line itself is gone, so
		// the reference that governed it is handed back rather than kept for a
		// bubble nobody can see.
		const posted = session.posted.get(item.id);
		if (posted !== undefined) {
			try {
				posted.release();
			} catch {
				// The session that answered with it has already reclaimed it.
			}
			session.posted.delete(item.id);
		}
	}
	discardAttachmentProgress(session, key, fileIds);
}
