// The bytes a room holds for the files posted in it.
//
// A room hosts media rather than relaying a reference to whoever posted it, so
// a picture outlives the tab that sent it and a member nothing can dial can
// post one at all. That choice makes storage the room's problem, and most of
// this file is its consequences: a byte ceiling that evicts oldest first, a
// reservation taken before a byte moves so admitted uploads cannot overcommit,
// and an idle clock so an upload that goes quiet gives its share back rather
// than being waited on forever.
//
// An evicted file breaks on read rather than answering empty, which a reader
// can tell apart from a file that really was empty.

import type { Session } from "@pancake/runtime";
import type { Argument } from "@pancake/runtime";
import { attachmentArgs } from "../lib/attachment.ts";
import { DISCARD, LINE, NOTIFY, READ, REFILED, WRITE } from "../lib/protocol.ts";
import { ATTACHMENT_REFUSED, BLOB_EXPIRED, RoomError, UPLOAD_INCOMPLETE } from "../lib/errors.ts";
import {
	BLOB_CHUNK,
	MAX_BLOB_READERS,
	MAX_ROOM_ATTACHMENT_BYTES,
	MAX_ROOM_ATTACHMENTS,
	MAX_SERVER_ATTACHMENT_BYTES,
	MAX_SERVER_PENDING_BYTES,
	UPLOAD_IDLE_MS,
} from "../lib/limits.ts";
import { handBack, type PendingUpload, type PostedFile, type RoomState } from "./registry.ts";
import { noteTrouble } from "./journal.ts";

/** Every file the server holds, oldest first, and the bytes they add up to.
 * Eviction is server-wide because the resource is: a per-room budget times
 * unbounded rooms bounds nothing. */
const heldFiles: PostedFile[] = [];

let heldBytes = 0;

/** Bytes reserved by uploads that have been admitted and not yet posted.
 * Reserved at `attach` against the size declared there, because that is what
 * the member may write, and released when the upload is posted or dropped. */
let pendingBytes = 0;

/** Reserve and allocate one upload of `size` bytes against the server's
 * in-flight budget, or refuse it.
 *
 * Held media can be evicted; bytes nobody has seen cannot, because there is no
 * owner to tell. So an upload that would not fit is refused against the size it
 * declares, before allocating the buffer it would fill. Allocation belongs in
 * this transaction too: if it fails after admission, the reservation is
 * restored here before the error escapes. The reservation and the releases
 * that undo it live together here; a budget maintained from two files is one
 * that drifts. */
export function allocateUpload(size: number): Uint8Array | null {
	if (pendingBytes + size > MAX_SERVER_PENDING_BYTES) return null;
	pendingBytes += size;
	try {
		return new Uint8Array(size);
	} catch (error) {
		pendingBytes -= size;
		throw error;
	}
}

/** Forget one held file's bytes wherever they are counted. The record and its
 * capability stay, so a member holding a dropped file's reference hears
 * `blob-expired` rather than an empty answer it could not tell from a real
 * empty file. */
export function dropFileBytes(file: PostedFile): void {
	if (file.bytes === null) return;
	if (file.written === file.size && file.failure === null) {
		heldBytes -= file.bytes.length;
		file.room.fileBytes -= file.bytes.length;
	}
	file.bytes = null;
	wakeBlobWaiters(file);
}

/** Make room for one more file of `incoming` bytes in `state`, under the
 * server's ceilings and the room's own. The server's are the ones that hold
 * memory; the room's keep any single room from taking the lot. */
function dropOldestFiles(state: RoomState, incoming: number): void {
	// Server-wide first, oldest anywhere: a busy room should not be able to
	// push a quiet room's files out ahead of its own older ones.
	while (heldFiles.length > 0 && heldBytes + incoming > MAX_SERVER_ATTACHMENT_BYTES) {
		dropFileBytes(heldFiles[0]);
		forgetFile(heldFiles[0]);
	}
	// Then this room's own share.
	while (
		state.files.length > 0 &&
		(state.fileBytes + incoming > MAX_ROOM_ATTACHMENT_BYTES ||
			state.files.length >= MAX_ROOM_ATTACHMENTS)
	) {
		dropFileBytes(state.files[0]);
		forgetFile(state.files[0]);
	}
}

/** Let go of every file a closing room held. A room is deleted when its last
 * member leaves, and its files go with it: the server counts them, so leaving
 * them on the held list would charge the budget for rooms that no longer
 * exist and only reclaim them under eviction pressure. */
export function dropRoomFiles(state: RoomState): void {
	for (const file of [...state.files]) {
		dropFileBytes(file);
		forgetFile(file);
	}
}

/** Drop one emptied file from both lists it sits in, so neither grows with
 * everything ever posted. */
/** The two lists a file is dropped from are the room's and the server's — never
 * the line's own set, and that omission is load-bearing rather than an
 * oversight. A refile names the files it keeps by their position on the line, so
 * a line's set has to mean the same thing before and after an eviction it never
 * asked for; splicing it here would silently slide every later index down, and a
 * reader keeping "the second one" would keep a different file. An evicted file
 * left in place breaks on read instead, which is what the reference already
 * promises and what a reader can tell apart from an empty file. */
export function forgetFile(file: PostedFile): void {
	const held = heldFiles.indexOf(file);
	if (held >= 0) heldFiles.splice(held, 1);
	const own = file.room.files.indexOf(file);
	if (own >= 0) file.room.files.splice(own, 1);
}

/** Forget every upload `session` began here without posting. Called when a
 * member leaves, so bytes nobody has seen never outlive their uploader, and
 * the object each one was driven through goes back with them. */
export function dropUploads(state: RoomState, session: Session): void {
	for (const upload of state.uploads.get(session) ?? []) dropUpload(state, session, upload);
	state.uploads.delete(session);
}

/** Reclaim one upload that will not be posted: release its reservation, drop
 * the bytes it collected, and hand its capability back. Idempotent, because
 * the idle timer and a departure can both reach the same upload. */
export function dropUpload(state: RoomState, session: Session, upload: PendingUpload): void {
	if (upload.spent) return;
	upload.spent = true;
	if (upload.expires !== null) clearTimeout(upload.expires);
	pendingBytes -= upload.size;
	upload.file.failure = upload.posted ? "the upload ended before this file arrived" : "the upload was discarded";
	upload.file.bytes = null;
	state.uploads.get(session)?.delete(upload);
	if (upload.ref !== null) handBack(session, upload.ref);
	wakeBlobWaiters(upload.file);
	if (!upload.posted) upload.posted = true;
}

function wakeBlobWaiters(file: PostedFile): void {
	for (const waiter of [...file.waiters]) {
		if (file.failure !== null || file.bytes === null) {
			file.waiters.delete(waiter);
			waiter.reject(new RoomError(BLOB_EXPIRED, file.failure ?? `"${file.name}" is no longer held by this room`));
		} else if (waiter.offset < file.written || file.written === file.size) {
			file.waiters.delete(waiter);
			const len = Math.min(waiter.maxLen, BLOB_CHUNK, file.written - waiter.offset);
			waiter.resolve(file.bytes.subarray(waiter.offset, waiter.offset + len));
		}
	}
}

function finishUpload(state: RoomState, session: Session, upload: PendingUpload): void {
	upload.spent = true;
	if (upload.expires !== null) clearTimeout(upload.expires);
	pendingBytes -= upload.size;
	state.uploads.get(session)?.delete(upload);
	if (state.uploads.get(session)?.size === 0) state.uploads.delete(session);
	if (upload.file.bytes === null) {
		// Its line withdrew or refiled this file out while its bytes were still
		// arriving. The reservation is released above; the file must not join the
		// held list, because nothing refers to it and its bytes are gone. Hand the
		// room's own retain back and stop, so the accounting a live file owns is
		// never charged for a dead one.
		if (upload.ref !== null) handBack(session, upload.ref);
		return;
	}
	dropOldestFiles(state, upload.size);
	state.files.push(upload.file);
	state.fileBytes += upload.size;
	heldFiles.push(upload.file);
	heldBytes += upload.size;
	if (upload.ref !== null) handBack(session, upload.ref);
	wakeBlobWaiters(upload.file);
}

/** Start this upload's idle clock over. Every chunk re-arms it, so the window
 * bounds silence rather than the whole upload. */
export function armUploadTimer(state: RoomState, session: Session, upload: PendingUpload): void {
	if (upload.expires !== null) clearTimeout(upload.expires);
	upload.expires = setTimeout(() => dropUpload(state, session, upload), UPLOAD_IDLE_MS);
}

export function uploadBehavior(state: RoomState, session: Session, upload: PendingUpload) {
	return (verb: string, args: Argument[]): Argument => {
		if (upload.spent) {
			throw new RoomError(UPLOAD_INCOMPLETE, "this upload is spent; attach again");
		}
		if (verb === WRITE) {
			if (!upload.posted) {
				throw new RoomError(UPLOAD_INCOMPLETE, "publish this upload before writing its bytes");
			}
			const chunk = args[0];
			if (!(chunk instanceof Uint8Array)) throw new Error("write needs a byte chunk");
			if (chunk.length > BLOB_CHUNK) {
				throw new RoomError(UPLOAD_INCOMPLETE, `a chunk may be at most ${BLOB_CHUNK} bytes`);
			}
			if (upload.file.written + chunk.length > upload.size) {
				throw new RoomError(UPLOAD_INCOMPLETE, `write runs past the declared ${upload.size} bytes`);
			}
			upload.file.bytes?.set(chunk, upload.file.written);
			upload.file.written += chunk.length;
			wakeBlobWaiters(upload.file);
			if (upload.file.written === upload.size) finishUpload(state, session, upload);
			else armUploadTimer(state, session, upload);
			return null;
		}
		if (verb === DISCARD) {
			dropUpload(state, session, upload);
			return null;
		}
		throw new Error(`upload has no method ${verb}`);
	};
}

/** Commit this connection's staged uploads into `into`, oldest first, and
 * answer how many were added.
 *
 * Marks each posted so its bytes may be written, and finishes the empty ones on
 * the spot, so afterwards the connection holds no pending staged set. Both a
 * first post and a refile spend the same staged set this way; neither broadcasts
 * here, because who the line is named to and how it is tagged is the caller's. */
export function postStaged(state: RoomState, session: Session, into: PostedFile[]): number {
	const staged = [...state.uploads.get(session) ?? []].filter((upload) => !upload.posted);
	for (const upload of staged) {
		upload.posted = true;
		into.push(upload.file);
		if (upload.size === 0) finishUpload(state, session, upload);
	}
	return staged.length;
}

/** Push one message's posted files to every subscriber. Each member gets one
 * blob reference per record, minted on that member's session, so no capability
 * crosses a connection it was not made on and the room relays nothing it does
 * not host.
 *
 * The room gives its own retain back as soon as the line is out. What keeps a
 * blob alive after that is the member holding it, which is the right owner:
 * the file's bytes are already bounded by the room's ceiling, and its object
 * retires when the last member that can name it lets go. Holding the retain
 * here instead would pin one object per file per member for the life of the
 * room, whatever anybody did with them. */
export function broadcastFiles(
	state: RoomState,
	from: string,
	caption: string,
	files: PostedFile[],
	tag: typeof LINE | typeof REFILED,
	id: number,
): void {
	for (const m of [...state.members]) {
		const blobs = files.map((file) => m.session.spawn(blobBehavior(file)));
		const records = files.flatMap((file, index) =>
			attachmentArgs({
				name: file.name,
				mime: file.mime,
				size: file.size,
				blob: blobs[index],
				width: file.width,
				height: file.height,
			})
		);
		// The line's id rides where a text line's does, so a file line is named
		// and its later edit, refile, or withdrawal can reach it; the records
		// follow the id. On a refile the tag is `refiled` and the run is the
		// complete new set, so a member replaces rather than appends.
		m.session.tell(m.inbox, NOTIFY, [
			from,
			caption,
			tag,
			BigInt(id),
			...records,
		]).then(
			() => blobs.forEach((blob) => handBack(m.session, blob)),
			(error) => {
				blobs.forEach((blob) => handBack(m.session, blob));
				noteTrouble(`a file notify to ${m.nick} failed`, error);
			},
		);
	}
}

/** The blob capability members read a posted file through: `read(offset,
 * maxLen)` answers at most `BLOB_CHUNK` bytes, and an empty slice at the end.
 * A file the room has dropped to stay under its ceiling breaks `blob-expired`
 * rather than answering empty, which a reader could not tell from a real
 * empty file. */
function blobBehavior(file: PostedFile) {
	return (verb: string, args: Argument[]): Argument | Promise<Uint8Array> => {
		if (verb !== READ) throw new Error(`blob has no method ${verb}`);
		if (file.bytes === null) {
			throw new RoomError(BLOB_EXPIRED, `"${file.name}" is no longer held by this room`);
		}
		const offset = args[0];
		const maxLen = args[1];
		if (typeof offset !== "bigint" || offset < 0n) throw new Error("read needs offset >= 0");
		if (typeof maxLen !== "bigint" || maxLen <= 0n) throw new Error("read needs maxLen > 0");
		const start = Number(offset > BigInt(file.size) ? BigInt(file.size) : offset);
		const wanted = Math.min(Number(maxLen), BLOB_CHUNK);
		if (start < file.written || file.written === file.size) {
			const len = Math.min(wanted, file.written - start);
			return file.bytes.subarray(start, start + len);
		}
		if (file.waiters.size >= MAX_BLOB_READERS) {
			throw new RoomError(
				ATTACHMENT_REFUSED,
				`"${file.name}" already has ${MAX_BLOB_READERS} readers waiting on the bytes it has not received yet`,
			);
		}
		return new Promise((resolve, reject) => {
			file.waiters.add({ offset: start, maxLen: wanted, resolve, reject });
		});
	};
}
