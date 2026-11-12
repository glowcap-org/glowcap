// The session side of the archive protocol (ADR-0044), as a floor-only
// client: put, read, narrow, attachments and independently revocable shares.
// The page reads its archive through the Rust session, so this client exists
// to prove the archive object and the deployable peer answer baseline OCapN
// that any binding can call, and it lives with the tests that make that claim.

import { Ref, type Session } from "@glowcap/runtime";
import { ask } from "../../../lib/ask.ts";
import { type Attachment, type AttachmentSource, sendWithAttachments } from "../../../lib/attachment.ts";
import {
	ALL_ARCHIVE_RECORDS,
	ARCHIVE_ATTACHMENT,
	ARCHIVE_BLOB,
	ARCHIVE_NARROW,
	ARCHIVE_PUT,
	ARCHIVE_PUT_FILES,
	ARCHIVE_READ,
	type ArchiveAccess,
	type ArchiveFilter,
	archiveFilterRow,
	type ArchiveLine,
	archiveMatches,
	type ArchivePage,
	type ArchiveRecord,
	archiveRecordKey,
	archiveRecordRow,
	MAX_ARCHIVE_READ,
	MAX_ARCHIVE_RECORDS,
	parseArchiveFilter,
	parseArchiveRecord,
	type RevisedArchiveRecord,
	safeRevision,
} from "../../../lib/archive/protocol.ts";
import { ARCHIVE_LIST_SHARES, ARCHIVE_REVOKE_SHARE, ARCHIVE_SHARE } from "../../../lib/archive/durable_protocol.ts";
import { parseRoomsSturdyref } from "../../../lib/locator.ts";
import type { ArchiveDurableShareView } from "../../../lib/archive/facet.ts";

export async function issueArchiveShare(
	session: Session,
	archive: Ref,
	id: string,
	label: string,
	filter: ArchiveFilter,
): Promise<string> {
	const raw = await ask(
		session,
		archive,
		ARCHIVE_SHARE,
		[id, label, archiveFilterRow(parseArchiveFilter(archiveFilterRow(filter)))],
		"the archive did not answer share",
	);
	if (typeof raw !== "string") {
		throw new Error("the archive answered an invalid durable share sturdyref");
	}
	parseRoomsSturdyref(raw);
	return raw;
}

export function revokeArchiveShare(session: Session, archive: Ref, id: string): Promise<boolean> {
	return ask(session, archive, ARCHIVE_REVOKE_SHARE, [id], "the archive did not answer revokeShare").then((raw) => {
		if (typeof raw !== "boolean") throw new Error("the archive answered revokeShare without a boolean");
		return raw;
	});
}

export async function listArchiveShares(
	session: Session,
	archive: Ref,
): Promise<ArchiveDurableShareView[]> {
	const raw = await ask(session, archive, ARCHIVE_LIST_SHARES, [], "the archive did not answer shares");
	if (!Array.isArray(raw)) throw new Error("the archive answered an invalid share list");
	return raw.map((entry) => {
		if (
			!Array.isArray(entry) || entry.length !== 4 || typeof entry[0] !== "string" ||
			typeof entry[1] !== "string" || typeof entry[3] !== "string"
		) {
			throw new Error("the archive answered an invalid durable share");
		}
		parseRoomsSturdyref(entry[3]);
		return {
			id: entry[0],
			label: entry[1],
			filter: parseArchiveFilter(entry[2]),
			sturdyref: entry[3],
		};
	});
}

export async function putArchive(session: Session, archive: Ref, record: ArchiveRecord): Promise<number> {
	const row = archiveRecordRow(record);
	parseArchiveRecord(row);
	return safeRevision(
		await ask(session, archive, ARCHIVE_PUT, [row], "the archive did not answer put"),
		"archive put revision",
	);
}

export async function putArchiveWithAttachments(
	session: Session,
	archive: Ref,
	record: ArchiveLine,
	sources: readonly AttachmentSource[],
): Promise<number> {
	const submitted = {
		...record,
		attachments: record.attachments.map((attachment) => ({ ...attachment, blob: null })),
	};
	const raw = await sendWithAttachments(
		session,
		archive,
		ARCHIVE_PUT_FILES,
		[archiveRecordRow(submitted)],
		[...sources],
	);
	return safeRevision(raw, "archive putFiles revision");
}

export async function readArchiveAttachment(
	session: Session,
	archive: Ref,
	record: ArchiveLine,
	index: number,
): Promise<Attachment | null> {
	const metadata = record.attachments[index];
	if (metadata?.blob == null) return null;
	const raw = await ask(
		session,
		archive,
		ARCHIVE_ATTACHMENT,
		[archiveRecordRow(record), BigInt(index)],
		"the archive did not answer attachment",
	);
	if (!(raw instanceof Ref)) throw new Error("the archive answered attachment without a capability");
	return { ...metadata, blob: raw };
}

export async function readArchiveBlob(
	session: Session,
	archive: Ref,
	digest: string,
): Promise<Ref> {
	if (!/^[0-9a-f]{64}$/.test(digest)) throw new Error("archive blob needs one content digest");
	const raw = await ask(session, archive, ARCHIVE_BLOB, [digest], "the archive did not answer blob");
	if (!(raw instanceof Ref)) throw new Error("the archive answered blob without a capability");
	return raw;
}

export async function readArchive(
	session: Session,
	archive: Ref,
	filter: ArchiveFilter = ALL_ARCHIVE_RECORDS,
	after = 0,
	limit = MAX_ARCHIVE_READ,
): Promise<ArchivePage> {
	if (!Number.isSafeInteger(after) || after < 0) {
		throw new Error("archive read revision must be a non-negative safe integer");
	}
	if (!Number.isSafeInteger(limit) || limit < 1) throw new Error("archive read limit must be positive");
	const checkedFilter = parseArchiveFilter(archiveFilterRow(filter));
	const effectiveLimit = Math.min(limit, MAX_ARCHIVE_READ);
	const raw = await ask(
		session,
		archive,
		ARCHIVE_READ,
		[archiveFilterRow(checkedFilter), BigInt(after), BigInt(effectiveLimit)],
		"the archive did not answer read",
	);
	if (!Array.isArray(raw) || raw.length !== 3 || typeof raw[1] !== "boolean" || !Array.isArray(raw[2])) {
		throw new Error("the archive answered an invalid read page");
	}
	const next = safeRevision(raw[0], "archive read cursor");
	if (next < after) throw new Error("the archive answered a regressing read cursor");
	let priorRevision = after;
	const records = raw[2].map((entry): RevisedArchiveRecord => {
		if (!Array.isArray(entry) || entry.length < 2) throw new Error("the archive answered an invalid record");
		const revision = safeRevision(entry[0], "archive record revision");
		if (revision <= priorRevision || revision > next) {
			throw new Error("the archive answered records outside its revision page");
		}
		priorRevision = revision;
		const record = parseArchiveRecord(entry.slice(1));
		if (!archiveMatches(record, checkedFilter)) throw new Error("the archive answered a record outside the filter");
		return { revision, record };
	});
	if (records.length > effectiveLimit) throw new Error("the archive answered too many records");
	if (raw[1] && (records.length !== effectiveLimit || next !== records.at(-1)?.revision)) {
		throw new Error("the archive answered an invalid continuing page");
	}
	return { next, more: raw[1], records };
}

/** Read one bounded current account across as many valid wire pages as it
 * needs. A peer may keep appending while this walk runs, so the resident-record
 * ceiling is also the per-walk allocation ceiling, and reaching it with more
 * still promised is a refusal and not an unbounded chase. */
export async function readAllArchiveRecords(
	session: Session,
	archive: Ref,
	filter: ArchiveFilter = ALL_ARCHIVE_RECORDS,
): Promise<ArchiveRecord[]> {
	const latest = new Map<string, RevisedArchiveRecord>();
	let scanned = 0;
	let after = 0;
	let more = true;
	while (more) {
		const page = await readArchive(session, archive, filter, after, MAX_ARCHIVE_READ);
		scanned += page.records.length;
		if (scanned > MAX_ARCHIVE_RECORDS) throw new Error("the archive exceeds its record ceiling");
		for (const entry of page.records) latest.set(archiveRecordKey(entry.record), entry);
		more = page.more;
		if (more && scanned === MAX_ARCHIVE_RECORDS) throw new Error("the archive exceeds its record ceiling");
		after = page.next;
	}
	return [...latest.values()].sort((a, b) => a.revision - b.revision).map((entry) => entry.record);
}

export async function narrowArchive(
	session: Session,
	archive: Ref,
	scope: ArchiveFilter,
	access: ArchiveAccess = "read",
): Promise<Ref> {
	const checked = parseArchiveFilter(archiveFilterRow(scope));
	const raw = await ask(
		session,
		archive,
		ARCHIVE_NARROW,
		[archiveFilterRow(checked), access],
		"the archive did not answer narrow",
	);
	if (!(raw instanceof Ref)) throw new Error("the archive answered narrow without a capability");
	return raw;
}
