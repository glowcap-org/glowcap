// Media in messages, the half every rooms peer shares: the record a posted
// file rides on and the chunked read a viewer runs. Room posts fill a
// room-hosted blob through an upload capability. Direct messages instead host
// the blob on their existing peer session. Both use the same record and reader,
// so transports and presentation code see one file contract.
//
// Nothing here holds a whole file except at its natural owners: a room store or
// direct sender has the selected file, and a viewer assembles what it asks for.
// In between, every message carries at most `BLOB_CHUNK`.

import { Ref } from "@pancake/runtime";
import type { Argument, Behavior, Session } from "@pancake/runtime";
import { ATTACH, DISCARD, POST_FILES, READ, WRITE } from "./protocol.ts";
import { answerWithin } from "./deadline.ts";
import {
	BLOB_CHUNK,
	MAX_ATTACHMENT_BYTES,
	MAX_DIRECT_ATTACHMENT_BYTES,
	MAX_DIRECT_ATTACHMENTS,
	MAX_FILE_NAME,
	MAX_IMAGE_DIM,
	MAX_MESSAGE_FILES,
	MAX_MIME,
	REQUEST_TIMEOUT_MS,
	TRANSFER_STALL_MS,
} from "./limits.ts";

/** One attachment as a member sees it: what the file is, and the live
 * capability its bytes come from. */
export interface Attachment {
	name: string;
	mime: string;
	size: number;
	blob: Ref;
	/** The picture's own pixel size, zero when it is not one or nobody
	 * measured it. A reader uses it to leave the right space before the bytes
	 * arrive; nothing depends on it being true. */
	width: number;
	height: number;
}

/** A file a sender is posting: its description and its bytes. */
export interface AttachmentSource {
	name: string;
	mime: string;
	/** Existing callers may own bytes already; browser files instead provide a
	 * bounded reader so selecting a file does not duplicate it in memory. */
	bytes?: Uint8Array;
	size?: number;
	read?: (offset: number, length: number) => Promise<Uint8Array>;
	width?: number;
	height?: number;
}

function sourceSize(source: AttachmentSource): number {
	return source.bytes?.length ?? source.size ?? 0;
}

/** Where an attachment record normally sits in a room line's arguments: after
 * the sender and the caption, at the same place a presence change would be. */
const ROOM_RECORD_AT = 2;

/** How many arguments one file record spans. */
const RECORD_SPAN = 7;

/** Read the file records a message carries, one after another from `recordAt`,
 * each `"file", name, mime, size, blob, width, height`. Empty for an ordinary
 * line. A record that does not read is where the walk stops, because the rest
 * of the line can no longer be trusted to be what it claims. */
export function readAttachments(args: Argument[], recordAt = ROOM_RECORD_AT): Attachment[] {
	const out: Attachment[] = [];
	for (let at = recordAt; args[at] === "file"; at += RECORD_SPAN) {
		if (out.length === MAX_MESSAGE_FILES) {
			throw new Error(`a message may carry at most ${MAX_MESSAGE_FILES} files`);
		}
		const name = args[at + 1];
		const mime = args[at + 2];
		const size = args[at + 3];
		const blob = args[at + 4];
		if (typeof name !== "string" || name.length === 0 || name.length > MAX_FILE_NAME) break;
		if (typeof mime !== "string" || mime.length > MAX_MIME) break;
		if (typeof size !== "bigint" || size < 0n || size > BigInt(MAX_ATTACHMENT_BYTES)) break;
		if (!(blob instanceof Ref)) break;
		out.push({
			name,
			mime,
			size: Number(size),
			blob,
			width: pixelCount(args[at + 5]),
			height: pixelCount(args[at + 6]),
		});
	}
	return out;
}

/** Validate a source before minting an actor for it. A direct-message sender is
 * its file host, so this is the same admission boundary the room server owns
 * for room-hosted files. */
export function validateAttachmentSource(source: AttachmentSource): number {
	const size = sourceSize(source);
	if (source.name.length === 0 || source.name.length > MAX_FILE_NAME) {
		throw new Error(`a file name may be 1 to ${MAX_FILE_NAME} characters`);
	}
	if (source.mime.length > MAX_MIME) {
		throw new Error(`a media type may be at most ${MAX_MIME} characters`);
	}
	if (!Number.isSafeInteger(size) || size < 0 || size > MAX_ATTACHMENT_BYTES) {
		throw new Error(`a file may be at most ${MAX_ATTACHMENT_BYTES} bytes`);
	}
	if (source.bytes === undefined && source.read === undefined && size > 0) {
		throw new Error("an attachment source with bytes needs a reader");
	}
	return size;
}

interface HostedSource {
	readonly name: string;
	readonly size: number;
	source: AttachmentSource | null;
}

// A room server owns a global held-media budget. Direct files have no server,
// so their sender owns the equivalent process-wide budget here. The queue is
// short and bounded; removing a completed row by identity is therefore simpler
// than maintaining a second index that could disagree with its order.
const hostedSources: HostedSource[] = [];
let hostedSourceBytes = 0;

function dropHostedSource(slot: HostedSource): void {
	if (slot.source === null) return;
	slot.source = null;
	hostedSourceBytes -= slot.size;
	const at = hostedSources.indexOf(slot);
	if (at >= 0) hostedSources.splice(at, 1);
}

function retainHostedSource(source: AttachmentSource, size: number): HostedSource {
	if (size === 0) return { name: source.name, size, source: null };
	while (
		hostedSources.length >= MAX_DIRECT_ATTACHMENTS ||
		hostedSourceBytes + size > MAX_DIRECT_ATTACHMENT_BYTES
	) {
		dropHostedSource(hostedSources[0]);
	}
	const slot = { name: source.name, size, source };
	hostedSources.push(slot);
	hostedSourceBytes += size;
	return slot;
}

/** One sender-hosted blob. This is the direct-message sibling of the room's
 * blob actor: the message carries a capability and the receiver pulls bounded
 * chunks over the session it already has, so no transport or relay learns a
 * file-transfer protocol.
 *
 * Once one ascending reader has received the complete file, the actor drops
 * its source. A DM has one recipient, and that recipient now owns the local
 * copy; retaining a browser `File` in the sender's Host after that point would
 * keep every sent file alive until the tab closed. */
function sourceBlob(slot: HostedSource): Behavior {
	const { name, size } = slot;
	let servedPrefix = 0;
	return async (verb, args): Promise<Uint8Array> => {
		if (verb !== READ) throw new Error(`blob has no method ${verb}`);
		const offset = args[0];
		const maxLen = args[1];
		if (typeof offset !== "bigint" || offset < 0n) throw new Error("read needs offset >= 0");
		if (typeof maxLen !== "bigint" || maxLen <= 0n) throw new Error("read needs maxLen > 0");
		const start = Number(offset > BigInt(size) ? BigInt(size) : offset);
		const length = Math.min(Number(maxLen), BLOB_CHUNK, size - start);
		if (length === 0) return new Uint8Array();
		const held = slot.source;
		if (held === null) throw new Error(`"${name}" is no longer held by its sender`);
		const chunk = held.bytes?.subarray(start, start + length) ?? await held.read?.(start, length);
		if (!(chunk instanceof Uint8Array) || chunk.length !== length) {
			throw new Error(`attachment source answered ${chunk?.length ?? 0} of ${length} requested bytes`);
		}
		if (start <= servedPrefix) servedPrefix = Math.max(servedPrefix, start + length);
		if (servedPrefix === size) dropHostedSource(slot);
		return chunk;
	};
}

/** Append sender-hosted files to any application message. `leading` remains
 * that message type's vocabulary; attachment records are one additive suffix.
 * The resulting capabilities travel over the target's existing CapTP session,
 * independently of how its byte channel was realized.
 *
 * The local handles are handed back after the send settles. A successful send
 * has already granted the receiver the export retain that keeps each blob
 * callable; a failed one granted nobody anything. */
export async function sendWithAttachments(
	session: Session,
	target: Ref,
	verb: string,
	leading: Argument[],
	sources: AttachmentSource[],
): Promise<void> {
	if (sources.length === 0) {
		await answerWithin(session.send(target, verb, leading), "they did not answer the message", REQUEST_TIMEOUT_MS);
		return;
	}
	if (sources.length > MAX_MESSAGE_FILES) {
		throw new Error(`a message may carry at most ${MAX_MESSAGE_FILES} files`);
	}
	const refs: Ref[] = [];
	const slots: HostedSource[] = [];
	const records: Argument[] = [];
	let delivered = false;
	try {
		const sizes = sources.map(validateAttachmentSource);
		const totalSize = sizes.reduce((sum, size) => sum + size, 0);
		if (totalSize > MAX_DIRECT_ATTACHMENT_BYTES) {
			throw new Error(`direct-message files may total at most ${MAX_DIRECT_ATTACHMENT_BYTES} bytes`);
		}
		for (const [index, source] of sources.entries()) {
			const size = sizes[index];
			const slot = retainHostedSource(source, size);
			slots.push(slot);
			const blob = session.spawn(sourceBlob(slot));
			refs.push(blob);
			records.push(...attachmentArgs({
				name: source.name,
				mime: source.mime,
				size,
				blob,
				width: sourcePixelCount(source.width),
				height: sourcePixelCount(source.height),
			}));
		}
		await answerWithin(
			session.send(target, verb, [...leading, ...records]),
			"they did not answer the message its files ride on",
			REQUEST_TIMEOUT_MS,
		);
		delivered = true;
	} finally {
		if (!delivered) {
			for (const slot of slots) dropHostedSource(slot);
		}
		for (const ref of refs) {
			try {
				session.release(ref);
			} catch {
				// Session teardown reclaimed it, or a prior failure already did.
			}
		}
	}
}

/** One declared pixel dimension, or zero for anything that is not a sane one.
 * Unknown and nonsense read the same here on purpose: both mean the reader
 * has no space to reserve, which is a layout decision rather than a refusal. */
function pixelCount(value: Argument | undefined): number {
	if (typeof value !== "bigint" || value <= 0n || value > BigInt(MAX_IMAGE_DIM)) return 0;
	return Number(value);
}

function sourcePixelCount(value: number | undefined): number {
	if (value === undefined || !Number.isSafeInteger(value) || value <= 0 || value > MAX_IMAGE_DIM) return 0;
	return value;
}

/** The trailing arguments a room broadcasts for one posted file. */
export function attachmentArgs(attachment: Attachment): Argument[] {
	return [
		"file",
		attachment.name,
		attachment.mime,
		BigInt(attachment.size),
		attachment.blob,
		BigInt(attachment.width),
		BigInt(attachment.height),
	];
}

/** Ask the room to admit one file and mint the capability that will carry it.
 * No bytes move here: a composer can establish every file's authority, publish
 * the message atomically, and only then drive those capabilities in parallel. */
export async function beginUpload(
	session: Session,
	room: Ref,
	source: AttachmentSource,
): Promise<Ref> {
	const upload = await answerWithin(
		session.send(room, ATTACH, [
			source.name,
			source.mime,
			BigInt(sourceSize(source)),
			BigInt(source.width ?? 0),
			BigInt(source.height ?? 0),
		]),
		`the room did not answer taking "${source.name}"`,
		REQUEST_TIMEOUT_MS,
	);
	if (!(upload instanceof Ref)) throw new Error("attach did not return an upload capability");
	return upload;
}

/** Thrown when an upload is stopped rather than failing on its own. Named so a
 * caller can tell a reader's own decision apart from a transfer that broke. */
export class UploadStopped extends Error {
	constructor() {
		// Read by a person: this text is what the file's row says afterwards, and
		// what it says is the reader's own decision rather than a fault.
		super("Stopped");
		this.name = "UploadStopped";
	}
}

/** Fill one admitted file. Writes within a file stay ordered; callers run one
 * of these per file concurrently.
 *
 * `signal` stops it. A file is written one bounded chunk per round trip, so
 * stopping is a matter of not starting the next one — there is no write to
 * interrupt and nothing half-sent beyond the chunk already in the air. That
 * makes the longest a stop can take one chunk, whatever the file's size, which
 * is what lets a reader who picked the wrong sixty-megabyte file take it back
 * rather than wait for it. */
/** Wait for one chunk's answer, and give up if it never comes. The bound is
 * larger than an ordinary request's because a read for bytes the room has not
 * received yet waits rather than answering short, and that wait is honest. */
function chunkWithin<T>(answer: Promise<T>, what: string, stallMs: number): Promise<T> {
	return answerWithin(answer, what, stallMs);
}

export async function fillUpload(
	session: Session,
	upload: Ref,
	source: AttachmentSource,
	onProgress?: (sent: number) => void,
	signal?: AbortSignal,
	stallMs: number = TRANSFER_STALL_MS,
): Promise<void> {
	const size = sourceSize(source);
	for (let sent = 0; sent < size; sent += BLOB_CHUNK) {
		if (signal?.aborted) throw new UploadStopped();
		const length = Math.min(BLOB_CHUNK, size - sent);
		const chunk = source.bytes?.subarray(sent, sent + length) ?? await source.read?.(sent, length);
		if (!(chunk instanceof Uint8Array) || chunk.length !== length) {
			throw new Error(`attachment source answered ${chunk?.length ?? 0} of ${length} requested bytes`);
		}
		await chunkWithin(
			session.send(upload, WRITE, [chunk]),
			`"${source.name}" stopped being taken after ${sent} of ${size} bytes`,
			stallMs,
		);
		onProgress?.(sent + chunk.length);
	}
}

/** Throw one staged file away, which is what removing it from a half-written
 * message does. */
export function discardUpload(session: Session, upload: Ref): Promise<unknown> {
	return answerWithin(
		session.send(upload, DISCARD, []),
		"the room did not answer discarding the file",
		REQUEST_TIMEOUT_MS,
	);
}

/** Publish every file staged on this connection as one message. */
export function postStagedFiles(session: Session, room: Ref, caption: string): Promise<unknown> {
	return answerWithin(
		session.send(room, POST_FILES, [caption]),
		"the room did not answer posting the files",
		REQUEST_TIMEOUT_MS,
	);
}

/** Pull a whole attachment through its blob capability, one bounded chunk per
 * round trip. The record's size bounds the allocation up front; a blob that
 * answers more than it declared, or dries up short of it, is refused rather
 * than trusted. `onProgress` hears bytes-so-far after each chunk. */
export async function fetchBlob(
	session: Session,
	attachment: Attachment,
	onProgress?: (got: number) => void,
	stallMs: number = TRANSFER_STALL_MS,
): Promise<Uint8Array> {
	const { size, blob } = attachment;
	if (size > MAX_ATTACHMENT_BYTES) throw new Error(`attachment declares ${size} bytes, over the cap`);
	const out = new Uint8Array(size);
	let got = 0;
	while (got < size) {
		const chunk = await chunkWithin(
			session.send(blob, READ, [BigInt(got), BigInt(BLOB_CHUNK)]),
			`"${attachment.name}" stopped arriving after ${got} of ${size} bytes`,
			stallMs,
		);
		if (!(chunk instanceof Uint8Array) || chunk.length === 0) {
			throw new Error(`blob ended at ${got} of ${size} bytes`);
		}
		if (got + chunk.length > size) throw new Error(`blob answered past its ${size} bytes`);
		out.set(chunk, got);
		got += chunk.length;
		onProgress?.(got);
	}
	return out;
}
