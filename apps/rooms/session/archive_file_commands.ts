// Lazy archived-file readers issued through a durable Rooms session.

import { type Argument, type Behavior, type Session } from "@pancake/runtime";
import { parseArchiveRecord } from "../lib/archive.ts";
import { ROOMS_SESSION_ARCHIVED_ATTACHMENT, type RoomsSessionFacet } from "../lib/rooms_session.ts";
import { BLOB_CHUNK } from "../lib/limits.ts";
import { READ } from "../lib/protocol.ts";
import type { DurableRoomsRuntime } from "./runtime.ts";

export const ARCHIVED_FILE_UNHANDLED = Symbol("archived file verb not handled");
const MAX_ARCHIVED_ATTACHMENT_READS = 512;
const archivedAttachmentReads = new WeakMap<Session, number>();

export function dispatchArchivedFileCommand(
	rights: RoomsSessionFacet,
	verb: string,
	args: Argument[],
	session: Session,
	runtime: DurableRoomsRuntime,
): ReturnType<Behavior> | typeof ARCHIVED_FILE_UNHANDLED {
	if (verb !== ROOMS_SESSION_ARCHIVED_ATTACHMENT) return ARCHIVED_FILE_UNHANDLED;
	if (rights !== "admin") throw new Error("this Rooms session facet cannot read archived files");
	if (
		args.length !== 2 || typeof args[1] !== "bigint" || args[1] < 0n ||
		args[1] > BigInt(Number.MAX_SAFE_INTEGER)
	) throw new Error("archivedAttachment takes one archive line and file index");
	const record = parseArchiveRecord(args[0]);
	const index = Number(args[1]);
	if (record.kind !== "line" || record.attachments[index]?.blob == null) {
		throw new Error("archivedAttachment names no retained file bytes");
	}
	const minted = archivedAttachmentReads.get(session) ?? 0;
	if (minted >= MAX_ARCHIVED_ATTACHMENT_READS) {
		throw new Error("this attached view reached its archived-file reader ceiling");
	}
	type Source = NonNullable<Awaited<ReturnType<DurableRoomsRuntime["readArchivedAttachment"]>>>;
	let source: Source | null = null;
	let opening: Promise<Source | null> | null = null;
	let activeReads = 0;
	let releaseWhenIdle = false;
	const acquire = async (): Promise<Source> => {
		if (source != null) return source;
		opening ??= runtime.readArchivedAttachment(record, index);
		try {
			source = await opening;
		} finally {
			opening = null;
		}
		if (source == null) throw new Error("those archived file bytes are no longer available");
		return source;
	};
	const proxy = session.spawn(async (readVerb, readArgs) => {
		if (
			readVerb !== READ || readArgs.length !== 2 || typeof readArgs[0] !== "bigint" ||
			readArgs[0] < 0n || readArgs[0] > BigInt(Number.MAX_SAFE_INTEGER) ||
			typeof readArgs[1] !== "bigint" || readArgs[1] <= 0n || readArgs[1] > BigInt(BLOB_CHUNK)
		) throw new Error("archived file read takes a bounded offset and length");
		const held = await acquire();
		activeReads += 1;
		let failure: unknown | null = null;
		let result: Uint8Array | null = null;
		try {
			const offset = Number(readArgs[0]);
			result = await held.read(offset, Number(readArgs[1]));
			if (offset + result.length >= held.size) releaseWhenIdle = true;
		} catch (error) {
			failure = error;
			releaseWhenIdle = true;
		}
		activeReads -= 1;
		let cleanupFailure: unknown | null = null;
		if (activeReads === 0 && releaseWhenIdle && source === held) {
			try {
				held.release();
			} catch (cleanup) {
				cleanupFailure = cleanup;
			} finally {
				source = null;
				releaseWhenIdle = false;
			}
		}
		if (failure != null && cleanupFailure != null) {
			throw new AggregateError([failure, cleanupFailure], "archived file read and release both failed");
		}
		if (failure != null) throw failure;
		if (cleanupFailure != null) throw cleanupFailure;
		if (result == null) throw new Error("the archived file read produced no result");
		return result;
	});
	archivedAttachmentReads.set(session, minted + 1);
	return proxy;
}
