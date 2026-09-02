// Blob verbs layered on the member-owned archive record protocol.

import { type Argument, currentSession, type Ref, type Session } from "@glowcap/runtime";
import { type Attachment, attachmentCapabilities, fetchBlobChunk, readAttachmentsExact } from "../attachment.ts";
import {
	hasCapabilityArguments,
	releaseUnexpectedCapabilityArguments,
	throwAfterReleasingCapabilities,
} from "../argument_custody.ts";
import { settleCapabilityCleanup } from "../capability_cleanup.ts";
import { ALL_ARCHIVE_RECORDS, type ArchiveAccess, type ArchiveFilter, intersectArchiveFilters } from "./scope.ts";
import { archiveMatches } from "./scope.ts";
import {
	attachmentMetadataEqual,
	type BlobArchiveBackend,
	isBlobArchiveBackend,
	lineAttachmentAddress,
} from "./blobs.ts";
import type { ArchiveBackend, ArchiveLine, ArchiveRecord } from "./protocol.ts";
import { BLOB_CHUNK } from "../limits.ts";

export const ARCHIVE_PUT_FILES = "putFiles";
export const ARCHIVE_ATTACHMENT = "attachment";
export const ARCHIVE_BLOB = "blob";
export const ARCHIVE_BLOB_UNHANDLED = Symbol("archive blob verb not handled");
export const MAX_ARCHIVE_BLOB_READS_PER_SESSION = 512;

const blobReadsMinted = new WeakMap<Session, number>();

interface ArchiveBlobFacet {
	readonly scope: ArchiveFilter;
	readonly access: ArchiveAccess;
}

interface ArchiveBlobParsers {
	record(raw: unknown): ArchiveRecord;
}

export function dispatchArchiveBlob(
	verb: string,
	args: Argument[],
	backend: ArchiveBackend,
	facet: ArchiveBlobFacet,
	parse: ArchiveBlobParsers,
): ReturnType<import("@glowcap/runtime").Behavior> | typeof ARCHIVE_BLOB_UNHANDLED {
	if (verb !== ARCHIVE_PUT_FILES && verb !== ARCHIVE_ATTACHMENT && verb !== ARCHIVE_BLOB) {
		return ARCHIVE_BLOB_UNHANDLED;
	}
	const session = currentSession();
	if (session == null) throw new Error(`archive ${verb} needs a live caller session`);
	if (verb === ARCHIVE_ATTACHMENT && hasCapabilityArguments(args)) {
		throwAfterReleasingCapabilities(
			session,
			args,
			new Error("archive attachment does not take capability arguments"),
		);
	}
	if (!isBlobArchiveBackend(backend)) {
		const error = new Error("this archive does not retain blob bytes");
		if (verb === ARCHIVE_PUT_FILES) throwAfterReleasingCapabilities(session, args, error);
		throw error;
	}
	if (verb === ARCHIVE_PUT_FILES) {
		const refuse = (error: unknown): never => throwAfterReleasingCapabilities(session, args, error);
		if (args.length < 2) refuse(new Error("archive putFiles needs one line and its file records"));
		if (facet.access !== "read-write") refuse(new Error("archive facet is read-only"));
		const record: ArchiveRecord = (() => {
			try {
				return parse.record(args[0]);
			} catch (error) {
				return refuse(error);
			}
		})();
		if (record.kind !== "line") return refuse(new Error("archive putFiles needs a line record"));
		if (!archiveMatches(record, facet.scope)) refuse(new Error("archive facet does not permit that record"));
		const attachments: Attachment[] = (() => {
			try {
				return readAttachmentsExact(args, 1);
			} catch (error) {
				return refuse(error);
			}
		})();
		releaseUnexpectedCapabilityArguments(
			session,
			args,
			attachmentCapabilities(attachments),
			"archive putFiles could not return an unexpected capability",
		);
		if (
			attachments.length !== record.attachments.length ||
			attachments.some((attachment, index) => !attachmentMetadataEqual(attachment, record.attachments[index]))
		) {
			releaseAttachments(session, attachments);
			throw new Error("archive file records do not match their line metadata");
		}
		const sources = attachments.map((attachment, index) => ({
			...record.attachments[index],
			read: (offset: number, maxLength: number) => fetchBlobChunk(session, attachment, offset, maxLength),
		}));
		return backend.putWithAttachments(record, sources).then((revision) => {
			if (!Number.isSafeInteger(revision) || revision < 1) {
				throw new Error("archive backend returned an invalid revision");
			}
			return BigInt(revision);
		}).finally(() => releaseAttachments(session, attachments));
	}

	if (verb === ARCHIVE_BLOB) {
		if (args.length !== 1 || typeof args[0] !== "string" || !/^[0-9a-f]{64}$/.test(args[0])) {
			throw new Error("archive blob needs one content digest");
		}
		const digest = args[0];
		const scope = intersectArchiveFilters(facet.scope, { ...ALL_ARCHIVE_RECORDS, digest });
		if (scope === null) throw new Error("archive facet does not permit that blob");
		const record = backend.peekLine(scope);
		if (record == null) {
			throw new Error("that archived blob is unavailable through this facet");
		}
		const index = record.attachments.findIndex((attachment) => attachment.blob === digest);
		if (index < 0) throw new Error("that archived blob is unavailable through this facet");
		return mintArchiveBlob(session, backend, facet, record, index);
	}

	if (
		args.length !== 2 || typeof args[1] !== "bigint" || args[1] < 0n ||
		args[1] > BigInt(Number.MAX_SAFE_INTEGER)
	) throw new Error("archive attachment needs one line record and file index");
	const record = parse.record(args[0]);
	const index = Number(args[1]);
	if (record.kind !== "line" || record.attachments[index]?.blob == null) {
		throw new Error("archive attachment names no retained file bytes");
	}
	if (!archiveMatches(record, facet.scope)) throw new Error("archive facet does not permit that attachment");
	return mintArchiveBlob(session, backend, facet, record, index);
}

function mintArchiveBlob(
	session: Session,
	backend: BlobArchiveBackend,
	facet: ArchiveBlobFacet,
	record: ArchiveLine,
	index: number,
): Ref {
	const address = lineAttachmentAddress(record, index);
	const minted = blobReadsMinted.get(session) ?? 0;
	if (minted >= MAX_ARCHIVE_BLOB_READS_PER_SESSION) {
		throw new Error("archive blob read mint ceiling reached for this session");
	}
	const blob = session.spawn(async (readVerb, readArgs) => {
		const caller = currentSession();
		if (caller == null) throw new Error("an archive blob is reachable only over a session");
		if (hasCapabilityArguments(readArgs)) {
			throwAfterReleasingCapabilities(
				caller,
				readArgs,
				new Error(`archive blob ${readVerb} does not take capability arguments`),
			);
		}
		if (
			readVerb !== "read" || readArgs.length !== 2 || typeof readArgs[0] !== "bigint" ||
			readArgs[0] < 0n || readArgs[0] > BigInt(Number.MAX_SAFE_INTEGER) ||
			typeof readArgs[1] !== "bigint" || readArgs[1] <= 0n || readArgs[1] > BigInt(BLOB_CHUNK)
		) throw new Error("archive blob read takes a bounded offset and length");
		const found = await backend.readAttachment(address);
		if (found == null || !archiveMatches(found.record, facet.scope)) {
			throw new Error("that archived attachment is unavailable through this facet");
		}
		return await found.attachment.read(Number(readArgs[0]), Number(readArgs[1]));
	});
	blobReadsMinted.set(session, minted + 1);
	return blob;
}

function releaseAttachments(session: Session, attachments: readonly Attachment[]): void {
	for (const attachment of attachments) {
		settleCapabilityCleanup("archive source attachment release failed", () => session.release(attachment.blob));
	}
}
