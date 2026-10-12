// Media in messages, the half every rooms peer shares: the record a posted
// file rides on and the chunked read a viewer runs. Room posts fill a
// room-hosted blob through an upload capability. Direct messages instead host
// the blob on their existing peer session. Both use the same record and reader,
// so transports and presentation code see one file contract.
//
// Nothing here holds a whole file except at its natural owners: a room store or
// direct sender has the selected file, and a viewer assembles what it asks for.
// In between, every message carries at most `BLOB_CHUNK`.

import { Ref } from "@glowcap/runtime";
import type { Argument, Behavior, Session } from "@glowcap/runtime";
import { ATTACH, DISCARD, POST_FILES, READ, WRITE } from "./protocol.ts";
import { answerWithin } from "./deadline.ts";
import { releaseUnclaimedCapabilityArguments } from "./argument_custody.ts";
import {
	attachmentRefusal,
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
	/** The picture's pixel size, zero when it is not a picture or nobody
	 * measured it. A reader uses it to leave the right space before the bytes
	 * arrive. Nothing depends on it being true. */
	width: number;
	height: number;
}

/** A file a sender is posting: its description and its bytes. */
export interface AttachmentSource {
	name: string;
	mime: string;
	/** Existing callers may own bytes already. Browser files provide a bounded
	 * reader instead, so selecting a file does not duplicate it in memory. */
	bytes?: Uint8Array;
	size?: number;
	read?: (offset: number, length: number) => Promise<Uint8Array>;
	width?: number;
	height?: number;
}

export function attachmentCapabilities(attachments: readonly Attachment[]): Set<Ref> {
	const capabilities = new Set<Ref>();
	for (const attachment of attachments) capabilities.add(attachment.blob);
	return capabilities;
}

function sourceSize(source: AttachmentSource): number {
	return source.bytes?.length ?? source.size ?? 0;
}

/** Where an attachment record normally sits in a room line's arguments: after
 * the sender and the caption, at the same place a presence change would be. */
const ROOM_RECORD_AT = 2;

/** How many arguments one file record spans. */
export const ATTACHMENT_RECORD_SPAN = 7;

/** Read the file records a message carries, one after another from `recordAt`,
 * each `"file", name, mime, size, blob, width, height`. Empty for an ordinary
 * line. A record that does not read ends the walk, because the rest of the
 * line can no longer be trusted to be what it claims. */
export function readAttachments(args: Argument[], recordAt = ROOM_RECORD_AT): Attachment[] {
	const out: Attachment[] = [];
	for (let at = recordAt; args[at] === "file"; at += ATTACHMENT_RECORD_SPAN) {
		// Stop at the cap and do not throw. This walks a message a peer or room
		// controls, and a throw here escapes the receive turn and erases the
		// whole message, which is worse than showing the first files, as a
		// malformed record below already does. Bound on receive, one way.
		if (out.length === MAX_MESSAGE_FILES) break;
		const record = readAttachmentRecord(args, at);
		if (record === null) break;
		out.push(record);
	}
	return out;
}

/** Parse an attachment suffix as one complete, bounded record sequence. This
 * is for mutation verbs that must not accept a valid prefix while ignoring a
 * trailing capability or malformed record. Ordinary message display keeps the
 * tolerant reader above because its input is remote content, not an admitted
 * state transition. */
export function readAttachmentsExact(args: Argument[], recordAt = ROOM_RECORD_AT): Attachment[] {
	const remaining = args.length - recordAt;
	if (remaining < 0 || remaining % ATTACHMENT_RECORD_SPAN !== 0) {
		throw new Error("attachment arguments do not form complete file records");
	}
	const count = remaining / ATTACHMENT_RECORD_SPAN;
	if (count > MAX_MESSAGE_FILES) {
		throw new Error(`a message may carry at most ${MAX_MESSAGE_FILES} files`);
	}
	const out: Attachment[] = [];
	for (let at = recordAt; at < args.length; at += ATTACHMENT_RECORD_SPAN) {
		const record = readAttachmentRecord(args, at);
		if (record === null) throw new Error("attachment arguments contain a malformed file record");
		out.push(record);
	}
	return out;
}

/** Parse exactly one attachment record. Message readers may stop on null.
 * Mutation verbs use the same parser but reject null and trailing arguments,
 * so the record vocabulary has one authority and ordinary message display is
 * not all-or-nothing. */
function readAttachmentRecord(args: Argument[], at: number): Attachment | null {
	if (args[at] !== "file") return null;
	const name = args[at + 1];
	const mime = args[at + 2];
	const size = args[at + 3];
	const blob = args[at + 4];
	if (typeof name !== "string" || name.length === 0 || name.length > MAX_FILE_NAME) return null;
	if (typeof mime !== "string" || mime.length > MAX_MIME) return null;
	if (typeof size !== "bigint" || size < 0n || size > BigInt(MAX_ATTACHMENT_BYTES)) return null;
	if (!(blob instanceof Ref)) return null;
	return {
		name,
		mime,
		size: Number(size),
		blob,
		width: pixelCount(args[at + 5]),
		height: pixelCount(args[at + 6]),
	};
}

/** Read a direct line's `refile(caption, ...keep, ...records)` arguments: the
 * caption, the kept indices, and the new files riding inline.
 *
 * This is the receiving half of `PostedLine.refile` with sources. Every
 * argument is the peer's, so the shape is refused and not trusted: an index
 * that repeats, or names no file among the line's `currentFiles`, and a result
 * past `MAX_MESSAGE_FILES` all throw. The count bound matters beyond one call.
 * Kept files compound across refiles, so without it a peer could grow one
 * line's set without limit, one refile at a time. */
export function readRefileChange(
	args: Argument[],
	currentFiles: number,
): { caption: string; keep: number[]; records: Attachment[] } {
	if (typeof args[0] !== "string") throw new Error("refile needs a caption");
	const caption = args[0];
	// Keep indices are the bigints after the caption, up to where the file
	// records begin. A record always opens with the string "file".
	let recordAt = 1;
	const keep: number[] = [];
	const seen = new Set<number>();
	while (recordAt < args.length && typeof args[recordAt] === "bigint") {
		const at = Number(args[recordAt] as bigint);
		if (!Number.isSafeInteger(at) || at < 0 || at >= currentFiles) {
			throw new Error(`no file at index ${at} on this line`);
		}
		if (seen.has(at)) throw new Error(`file ${at} is kept twice`);
		seen.add(at);
		keep.push(at);
		recordAt += 1;
	}
	const records: Attachment[] = [];
	while (recordAt < args.length) {
		const record = readAttachmentRecord(args, recordAt);
		if (record === null) throw new Error("refile has a malformed file record");
		records.push(record);
		recordAt += ATTACHMENT_RECORD_SPAN;
	}
	if (keep.length + records.length > MAX_MESSAGE_FILES) {
		throw new Error(`a message may carry at most ${MAX_MESSAGE_FILES} files`);
	}
	return { caption, keep, records };
}

export { attachmentRefusal };

/** Validate a source before creating an actor for it. A direct-message sender
 * is its file host, so this is the same admission boundary the room server owns
 * for room-hosted files. */
export function validateAttachmentSource(source: AttachmentSource): number {
	const size = sourceSize(source);
	const refused = attachmentRefusal(source.name, source.mime, size);
	if (refused !== null) throw new Error(refused);
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
// short and bounded, so removing a completed row by identity is simpler than
// maintaining a second index that could disagree with its order.
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
 * copy. Retaining a browser `File` in the sender's Host after that point would
 * keep every sent file alive until the tab closed. */
function sourceBlob(slot: HostedSource, session: Session): Behavior {
	const { name, size } = slot;
	let servedPrefix = 0;
	return async (verb, args): Promise<Uint8Array> => {
		releaseUnclaimedCapabilityArguments(
			session,
			args,
			"a direct sender blob could not return an unexpected capability",
		);
		if (verb !== READ) throw new Error(`blob has no method ${verb}`);
		if (args.length !== 2) throw new Error("read needs an offset and maximum length");
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

/** Append sender-hosted files to any application message. `leading` stays
 * that message type's vocabulary, and attachment records are one additive
 * suffix. The resulting capabilities travel over the target's existing CapTP
 * session, whatever its byte channel is.
 *
 * The local handles are handed back after the send settles. A successful send
 * has already granted the receiver the export retain that keeps each blob
 * callable, and a failed one granted nobody anything.
 *
 * Answers whatever the target answered. A direct line's `dm` answers a line
 * handle the sender holds to change or take the message back, so this passes it
 * up instead of discarding it. */
export async function sendWithAttachments(
	session: Session,
	target: Ref,
	verb: string,
	leading: Argument[],
	sources: AttachmentSource[],
): Promise<Argument> {
	if (sources.length === 0) {
		return await answerWithin(
			session.send(target, verb, leading),
			"they did not answer the message",
			REQUEST_TIMEOUT_MS,
		);
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
			const blob = session.spawn(sourceBlob(slot, session));
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
		const answer = await answerWithin(
			session.send(target, verb, [...leading, ...records]),
			"they did not answer the message its files ride on",
			REQUEST_TIMEOUT_MS,
		);
		delivered = true;
		return answer;
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
 * Unknown and nonsense read the same here: both mean the reader has no space
 * to reserve, which is a layout decision and not a refusal. */
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

/** Ask the room to admit one file and create the capability that will carry it.
 * No bytes move here. A composer can establish every file's authority, publish
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

/** Thrown when an upload is stopped and did not fail on its own. A caller can
 * tell a reader's decision apart from a transfer that broke. */
export class UploadStopped extends Error {
	constructor() {
		// A person reads this text as the file's row afterward, and it records
		// the reader's decision and not a fault.
		super("Stopped");
		this.name = "UploadStopped";
	}
}

/** Wait for one chunk's answer, and give up if it never comes. The bound is
 * larger than an ordinary request's because a read for bytes the room has not
 * received yet waits instead of answering short, and that wait is expected. */
function chunkWithin<T>(answer: Promise<T>, what: string, stallMs: number): Promise<T> {
	return answerWithin(answer, what, stallMs);
}

/** Fill one admitted file. Writes within a file stay ordered, and callers run
 * one of these per file concurrently.
 *
 * `signal` stops it. A file is written one bounded chunk per round trip, so
 * stopping means not starting the next one. There is no write to interrupt and
 * nothing half-sent beyond the chunk already in the air. A stop therefore
 * takes at most one chunk, whatever the file's size, which lets a reader who
 * picked the wrong sixty-megabyte file take it back instead of waiting. */

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

/** Throw away the staged file removed from a half-written message. */
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
 * round trip. The record's size bounds the allocation up front. A blob that
 * answers more than it declared, or dries up short of it, is refused and not
 * trusted. `onProgress` hears bytes-so-far after each chunk. */
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

/** Read one validated bounded slice without allocating the complete blob. A
 * durable session uses this to proxy a live attachment capability to each
 * attached view. */
export async function fetchBlobChunk(
	session: Session,
	attachment: Attachment,
	offset: number,
	maxLen: number,
	stallMs: number = TRANSFER_STALL_MS,
): Promise<Uint8Array> {
	if (!Number.isSafeInteger(offset) || offset < 0) throw new Error("blob offset must be a non-negative integer");
	if (!Number.isSafeInteger(maxLen) || maxLen <= 0) throw new Error("blob length must be a positive integer");
	if (offset >= attachment.size) return new Uint8Array();
	const expected = Math.min(maxLen, BLOB_CHUNK, attachment.size - offset);
	const chunk = await chunkWithin(
		session.send(attachment.blob, READ, [BigInt(offset), BigInt(expected)]),
		`"${attachment.name}" stopped arriving at ${offset} of ${attachment.size} bytes`,
		stallMs,
	);
	if (!(chunk instanceof Uint8Array) || chunk.length === 0 || chunk.length > expected) {
		throw new Error(
			`blob answered ${chunk instanceof Uint8Array ? chunk.length : 0} bytes for a ${expected}-byte read`,
		);
	}
	return chunk;
}
