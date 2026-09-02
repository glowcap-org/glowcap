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

import * as store from "../store.ts";
import { type Attachment, fetchBlob } from "../../../lib/attachment.ts";
import type { Session } from "@glowcap/runtime";
import type { Room } from "../../../lib/room/client.ts";
import { BLOB_EXPIRED, roomErrorOf } from "../../../lib/errors.ts";
import type { Item, ViewerDirection } from "../types.ts";
import { reason } from "./common.ts";
import { type AttachmentProgress, convSession, type HeldFile, isCurrent, type Live } from "./live.ts";
import { settleCapabilityCleanup } from "../../../lib/capability_cleanup.ts";
import type { RoomsPageContext } from "../page.ts";

/** Keep transfer cadence out of React. Parallel files replace their own latest
 * byte count in a session-bounded map, then one animation frame publishes every
 * conversation's visible progress with one history copy apiece. */
function noteProgress(
	page: RoomsPageContext,
	progress: AttachmentProgress,
	live: () => boolean,
	key: string,
	id: number,
	got: number,
): void {
	let updates = progress.pending.get(key);
	if (updates === undefined) {
		updates = new Map();
		progress.pending.set(key, updates);
	}
	updates.set(id, { got });
	if (progress.frame !== null) return;
	progress.frame = requestAnimationFrame(() => {
		progress.frame = null;
		const pending = progress.pending;
		progress.pending = new Map();
		if (!live()) return;
		for (const [conversation, fields] of pending) store.updateAttachments(page.projection, conversation, fields);
	});
}

export function noteAttachmentProgress(session: Live, key: string, id: number, got: number): void {
	noteProgress(session.page, session.progress, () => isCurrent(session), key, id, got);
}

/** A URL, completion, or error is terminal presentation state. Remove queued
 * byte counts for those files before publishing it synchronously, so a frame
 * already in flight cannot overwrite the terminal answer. */
function discardProgress(progress: AttachmentProgress, key: string, ids: Iterable<number>): void {
	const pending = progress.pending.get(key);
	if (pending !== undefined) {
		for (const id of ids) pending.delete(id);
		if (pending.size === 0) progress.pending.delete(key);
	}
	if (progress.pending.size === 0 && progress.frame !== null) {
		cancelAnimationFrame(progress.frame);
		progress.frame = null;
	}
}

function discardAttachmentProgress(session: Live, key: string, ids: Iterable<number>): void {
	discardProgress(session.progress, key, ids);
}

export function commitAttachmentUpdates(
	session: Live,
	key: string,
	updates: ReadonlyMap<number, store.AttachmentFields>,
): void {
	const page = session.page;
	discardAttachmentProgress(session, key, updates.keys());
	store.updateAttachments(page.projection, key, updates);
}

function commitAttachment(
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
export const FILE_GONE_WITH_ITS_CONNECTION = "this file came over an earlier connection and cannot be fetched again";

/** Where one file's bytes are read to, and what decides that read still counts.
 *
 * Two things can own a read: the session a file arrived over, and the archive on
 * this device. They differ in what makes a read stale and in which tables the
 * bookkeeping lands in, and in nothing else, so the read itself is written once
 * and asks its owner the rest. */
interface AttachmentSink {
	/** Whether this read is still the one to publish. */
	live(): boolean;
	progress(key: string, id: number, got: number): void;
	commit(key: string, id: number, fields: store.AttachmentFields): void;
	url(id: number, blob: Blob): string;
	/** Let the row go, its bytes now being in hand. */
	forget(id: number): void;
}

/** A read owned by the connection the file arrived over. Stale once that
 * session is replaced, or once the row is no longer the one registered. */
function sessionSink(owner: Live, row: HeldFile, id: number): AttachmentSink {
	return {
		live: () => isCurrent(owner) && owner.files.get(id) === row,
		progress: (key, at, got) => noteAttachmentProgress(owner, key, at, got),
		commit: (key, at, fields) => commitAttachment(owner, key, at, fields),
		url: (at, blob) => keepObjectUrl(owner, at, blob),
		forget: (at) => void owner.files.delete(at),
	};
}

/** A read owned by this device's archive. No session is involved, so none can
 * make it stale: what does is the row being released, which is what a dropped
 * line or a closed conversation does. */
function archiveSink(page: RoomsPageContext, key: string, row: HeldFile, id: number): AttachmentSink {
	const history = page.history;
	const rows = () => history.archived.get(key);
	const live = () => rows()?.get(id) === row;
	return {
		live,
		progress: (at, file, got) => noteProgress(page, history.progress, live, at, file, got),
		commit: (at, file, fields) => {
			discardProgress(history.progress, at, [file]);
			store.updateAttachments(page.projection, at, new Map([[file, fields]]));
		},
		url: (at, blob) => keepUrl(history.urls, at, blob),
		forget: (at) => void rows()?.delete(at),
	};
}

/** Fetch a posted file's bytes and hand it an object URL to draw or download
 * from. Idempotent: a file already holding its bytes, or already
 * fetching them, is left alone. */
export function openAttachment(page: RoomsPageContext, key: string, id: number): void {
	const item = store.historyOf(page.projection, key).find((line) =>
		line.kind === "chat" && line.attachments?.some((file) => file.id === id)
	);
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
	// The connection's own row first, then the one the archive holds. A file that
	// arrived over a live session is read back through it; a file this device
	// kept is read off the disk, and needs no session at all — which is why the
	// two are looked up rather than one being asked to stand for both.
	const owner = convSession(page, key);
	const live = owner?.files.get(id);
	const kept = page.history.archived.get(key)?.get(id);
	const row = live ?? kept;
	if (row === undefined) {
		store.updateAttachment(page.projection, key, id, { error: FILE_GONE_WITH_ITS_CONNECTION, lost: true });
		return;
	}
	const into = live !== undefined && owner !== null
		? sessionSink(owner, live, id)
		: archiveSink(page, key, kept!, id);
	into.commit(key, id, { got: 0, error: undefined });
	row.fetch((got) => {
		if (into.live()) into.progress(key, id, got);
	})
		.then((bytes) => {
			// Conversation teardown releases and removes the held row. A fetch that
			// settled at the same time must not mint a URL after that cleanup, or
			// attach its bytes to a later session.
			if (!into.live()) return;
			row.release();
			into.forget(id);
			into.commit(key, id, {
				got: undefined,
				url: into.url(id, blobOf(bytes, row.attachment.mime)),
			});
		})
		.catch((err) => {
			if (!into.live()) return;
			// A room drops its oldest files to stay under its media ceiling, and
			// keeps saying so on every later read. Nothing brings that one back,
			// so the row must not go on inviting a press.
			const evicted = roomErrorOf(err)?.code === BLOB_EXPIRED;
			into.commit(key, id, { got: undefined, error: reason(err), lost: evicted ? true : undefined });
		});
}

/** Move the viewer through this conversation's images, fetching the next one
 * on demand through the same transfer path as an explicit press in the log. */
export function stepViewer(page: RoomsPageContext, direction: ViewerDirection): void {
	const key = page.projection.get().viewing?.key;
	const file = store.stepViewer(page.projection, direction);
	if (key !== undefined && file !== null && file.url === undefined) openAttachment(page, key, file.id);
}

export function holdRoomFile(room: Room, attachment: Attachment): HeldFile {
	let fetching: Promise<Uint8Array> | null = null;
	return {
		attachment,
		fetch: (onProgress) => {
			if (fetching == null) {
				fetching = room.fetch(attachment, onProgress).catch((error) => {
					fetching = null;
					throw error;
				});
			}
			return fetching;
		},
		release: () => {
			settleCapabilityCleanup("room file capability release failed", () => room.release(attachment));
		},
	};
}

export function holdDirectFile(
	session: Session,
	attachment: Attachment,
): HeldFile {
	let fetching: Promise<Uint8Array> | null = null;
	return {
		attachment,
		fetch: (onProgress) => {
			if (fetching == null) {
				fetching = fetchBlob(session, attachment, onProgress).catch((error) => {
					fetching = null;
					throw error;
				});
			}
			return fetching;
		},
		release: () => {
			settleCapabilityCleanup("direct file capability release failed", () => session.release(attachment.blob));
		},
	};
}

export function releaseRoomAttachment(room: Room, attachment: Attachment): void {
	settleCapabilityCleanup("unused room file capability release failed", () => room.release(attachment));
}

export function releaseRoomAttachments(room: Room, attachments: readonly Attachment[]): void {
	for (const attachment of attachments) releaseRoomAttachment(room, attachment);
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

/** Mint the object URL one file owns, replacing any retry's prior URL. The
 * session is the one whose capability produced the bytes, and it is what the URL
 * is released with when that directory goes. */
function keepUrl(urls: Map<number, string>, id: number, blob: Blob): string {
	const url = URL.createObjectURL(blob);
	const old = urls.get(id);
	if (old !== undefined) URL.revokeObjectURL(old);
	urls.set(id, url);
	return url;
}

export function keepObjectUrl(owner: Live, id: number, blob: Blob): string {
	return keepUrl(owner.objectUrls, id, blob);
}

/** Release every object URL and blob capability this session minted. */
export function releaseFiles(session: Live): void {
	const page = session.page;
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
	for (const conv of page.projection.get().convs.values()) {
		if (conv.dir !== session.id) continue;
		const stalled = new Map<number, store.AttachmentFields>();
		const kept = page.history.archived.get(conv.key);
		for (const item of store.historyOf(page.projection, conv.key)) {
			if (item.kind !== "chat") continue;
			for (const file of item.attachments ?? []) {
				if (file.got === undefined) continue;
				// A read off this device is not one this connection was carrying, so
				// it neither stalls nor goes when the connection does. Saying it did
				// took away a file whose bytes were still on the disk.
				if (kept?.has(file.id) === true) continue;
				stalled.set(file.id, { got: undefined, error: FILE_GONE_WITH_ITS_CONNECTION, lost: true });
			}
		}
		store.updateAttachments(page.projection, conv.key, stalled);
	}
}

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

/** Let go of everything a set of lines was holding: the bytes of each file they
 * carried, the URL a picture was drawn from, and the reference that governed one
 * of our own. Called for a conversation whose history is about to disappear, and
 * for the oldest lines of one that has passed the far end of its log. */
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
			settleCapabilityCleanup("posted line capability release failed", () => posted.release());
			session.posted.delete(item.id);
		}
	}
	discardAttachmentProgress(session, key, fileIds);
}
