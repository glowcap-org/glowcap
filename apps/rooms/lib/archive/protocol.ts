// The member-owned Rooms archive capability (ADR-0129).
//
// This is application protocol, not a storage engine. An archive is one
// ordinary object whose storage verbs are `put` and `read`; `narrow` mints a
// monotonically scoped forwarding facet without touching storage. Browser
// IndexedDB and the standalone peer implement the same backend seam. Every
// value here can cross either Rooms wire profile; no binding-local object shape
// participates in the contract.

import { type Argument, type Behavior, currentSession, Ref, type Session } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import { type Attachment, attachmentRefusal, type AttachmentSource, sendWithAttachments } from "../attachment.ts";
import {
	ARCHIVE_ATTACHMENT,
	ARCHIVE_BLOB,
	ARCHIVE_BLOB_UNHANDLED,
	ARCHIVE_PUT_FILES,
	dispatchArchiveBlob,
} from "./blob_protocol.ts";
import { ARCHIVE_SHARE_UNHANDLED, dispatchArchiveDurableShare } from "./durable_protocol.ts";
import {
	MAX_IMAGE_DIM,
	MAX_LINE,
	MAX_MESSAGE_FILES,
	MAX_ROOM_ATTACHMENT_BYTES,
	nickRefusal,
	utf8Fits,
} from "../limits.ts";
import {
	ALL_ARCHIVE_RECORDS,
	type ArchiveAccess,
	type ArchiveConversationKind,
	type ArchiveFilter,
	archiveMatches,
	intersectArchiveFilters,
} from "./scope.ts";
import { archiveRecordKey, MAX_ARCHIVE_RECORDS } from "./index.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../argument_custody.ts";
import { type ArchiveFacet, type ArchiveFacetIssuer, archiveFacetIssuer, facetAccess, WHOLE_ARCHIVE } from "./facet.ts";

export {
	ALL_ARCHIVE_RECORDS,
	type ArchiveAccess,
	type ArchiveConversationKind,
	type ArchiveFilter,
	archiveMatches,
} from "./scope.ts";
export { ArchiveIndex, archiveRecordKey, MAX_ARCHIVE_RECORDS, MemoryArchiveBackend } from "./index.ts";

export const ARCHIVE_PUT = "put";
export const ARCHIVE_READ = "read";
export const ARCHIVE_NARROW = "narrow";
export { ARCHIVE_ATTACHMENT, ARCHIVE_BLOB, ARCHIVE_PUT_FILES } from "./blob_protocol.ts";
export { ARCHIVE_LIST_SHARES, ARCHIVE_REVOKE_SHARE, ARCHIVE_SHARE } from "./durable_protocol.ts";

/** Largest page one read can answer in a single CapTP turn. */
export const MAX_ARCHIVE_READ = 128;
/** Fresh forwarding actors one caller session may mint over its lifetime.
 * Released facets do not refill the budget: actor churn is still work and
 * consumes monotonic export positions even when no occurrence remains live. */
export const MAX_ARCHIVE_FACETS_PER_SESSION = 256;
/** Opaque recorder coordinates are deliberately small bearer-independent
 * labels. The shipped tab mints 128 bits as printable UUID text. */
export const MAX_ARCHIVE_ID_BYTES = 128;
/** Directory locators and contextual conversation labels are data from
 * another peer. Bound them independently of the much smaller room vocabulary. */
export const MAX_ARCHIVE_CONTEXT_BYTES = 8192;
export const MAX_ARCHIVE_CONVERSATION_BYTES = 512;

export type ArchiveLineState = "present" | "edited" | "withdrawn";

/** The durable fact that a file occupied one place on a line. Its bytes remain
 * separate capability authority; keeping metadata lets a restored message say
 * exactly what is no longer available instead of silently becoming text-only. */
export interface ArchivedAttachment {
	readonly name: string;
	readonly mime: string;
	readonly size: number;
	readonly width: number;
	readonly height: number;
	/** Content digest minted by the archive that holds the bytes, or null when
	 * this record retains metadata only. It identifies content, not authority. */
	readonly blob: string | null;
}

export interface ArchiveCoordinates {
	/** Opaque stable identity minted by this recorder. It is not a person ID. */
	readonly source: string;
	/** Opaque identity for one live conversation as this recorder saw it. */
	readonly generation: string;
	/** Opaque identity for this record inside the generation. */
	readonly id: string;
}

export function sameArchiveCoordinates(
	left: ArchiveCoordinates | null | undefined,
	right: ArchiveCoordinates | null | undefined,
): boolean {
	return left != null && right != null && left.source === right.source && left.generation === right.generation &&
		left.id === right.id;
}

/** Where the recorder stood: enough to offer a returning reader the same
 * place again, without claiming that its names still have the same holders. */
export interface ArchiveStanding extends ArchiveCoordinates {
	readonly kind: "standing";
	readonly directory: string;
	readonly room: string;
	readonly nick: string;
	readonly at: number;
}

/** One line as this recorder saw it. File metadata preserves the message's
 * shape; byte custody remains separate capability authority. */
export interface ArchiveLine extends ArchiveCoordinates {
	readonly kind: "line";
	readonly conversationKind: ArchiveConversationKind;
	readonly directory: string;
	readonly conversation: string;
	readonly from: string;
	readonly text: string;
	readonly mine: boolean;
	readonly at: number;
	readonly state: ArchiveLineState;
	readonly attachments: readonly ArchivedAttachment[];
}

export type ArchiveRecord = ArchiveStanding | ArchiveLine;

export interface RevisedArchiveRecord {
	readonly revision: number;
	readonly record: ArchiveRecord;
}

export interface ArchivePage {
	/** Resume strictly after this revision. */
	readonly next: number;
	readonly more: boolean;
	readonly records: RevisedArchiveRecord[];
}

/** Storage-owned authority: revision allocation, replacement, eviction, and
 * ordered scans are one transaction at this seam. */
export interface ArchiveBackend {
	put(record: ArchiveRecord): Promise<number>;
	read(filter: ArchiveFilter, after: number, limit: number): Promise<ArchivePage>;
}

/** Storage authority held by an owner that may erase its own archive account. */
export interface ErasableArchiveBackend extends ArchiveBackend {
	clear(): Promise<void> | void;
}

function boundedString(raw: unknown, what: string, maxBytes: number, empty = false): string {
	if (typeof raw !== "string") throw new Error(`${what} must be text`);
	if (!empty && raw.length === 0) throw new Error(`${what} may not be empty`);
	if (!utf8Fits(raw, maxBytes)) throw new Error(`${what} is too long`);
	return raw;
}

function opaqueId(raw: unknown, what: string): string {
	const value = boundedString(raw, what, MAX_ARCHIVE_ID_BYTES);
	// These are coordinates, never display text. Excluding controls makes their
	// accidental appearance in logs unambiguous and keeps composite keys safe.
	// deno-lint-ignore no-control-regex
	if (/[\u0000-\u001f\u007f-\u009f]/.test(value)) throw new Error(`${what} contains a control character`);
	return value;
}

export function parseArchiveCoordinates(source: unknown, generation: unknown, id: unknown): ArchiveCoordinates {
	return {
		source: opaqueId(source, "archive source"),
		generation: opaqueId(generation, "archive generation"),
		id: opaqueId(id, "archive record id"),
	};
}

function archiveName(raw: unknown, what: string): string {
	if (typeof raw !== "string") throw new Error(`${what} must be text`);
	const refusal = nickRefusal(raw);
	if (refusal !== null) throw new Error(`${what}: ${refusal}`);
	return raw;
}

function timestamp(raw: unknown): number {
	if (typeof raw !== "bigint" || raw < 0n || raw > BigInt(Number.MAX_SAFE_INTEGER)) {
		throw new Error("archive time must be a non-negative safe integer");
	}
	return Number(raw);
}

function readCommon(raw: Argument[]): ArchiveCoordinates {
	return parseArchiveCoordinates(raw[1], raw[2], raw[3]);
}

function archivedDimension(raw: unknown): number {
	if (typeof raw !== "bigint" || raw < 0n || raw > BigInt(MAX_IMAGE_DIM)) {
		throw new Error("archive attachment dimensions are invalid");
	}
	return Number(raw);
}

function parseArchivedAttachments(raw: unknown): ArchivedAttachment[] {
	if (!Array.isArray(raw) || raw.length > MAX_MESSAGE_FILES) {
		throw new Error(`an archive line may carry at most ${MAX_MESSAGE_FILES} attachment records`);
	}
	const attachments = raw.map((entry) => {
		if (
			!Array.isArray(entry) || entry.length !== 6 || typeof entry[0] !== "string" ||
			typeof entry[1] !== "string" || typeof entry[2] !== "bigint" || entry[2] > BigInt(Number.MAX_SAFE_INTEGER)
		) throw new Error("an archive attachment record has the wrong shape");
		const blob = entry[5];
		if (blob !== null && (typeof blob !== "string" || !/^[0-9a-f]{64}$/.test(blob))) {
			throw new Error("an archive attachment has an invalid blob digest");
		}
		const size = Number(entry[2]);
		const refused = attachmentRefusal(entry[0], entry[1], size);
		if (refused != null) throw new Error(`archive attachment: ${refused}`);
		return {
			name: entry[0],
			mime: entry[1],
			size,
			width: archivedDimension(entry[3]),
			height: archivedDimension(entry[4]),
			blob,
		};
	});
	if (attachments.reduce((total, attachment) => total + attachment.size, 0) > MAX_ROOM_ATTACHMENT_BYTES) {
		throw new Error(`archive line attachments may total at most ${MAX_ROOM_ATTACHMENT_BYTES} bytes`);
	}
	return attachments;
}

/** Decode and validate the exact passable record tuple accepted by `put`. */
export function parseArchiveRecord(raw: unknown): ArchiveRecord {
	if (!Array.isArray(raw)) throw new Error("archive put needs one record row");
	if (raw[0] === "standing") {
		if (raw.length !== 8) throw new Error("an archive standing row has the wrong shape");
		return {
			kind: "standing",
			...readCommon(raw as Argument[]),
			directory: boundedString(raw[4], "archive directory", MAX_ARCHIVE_CONTEXT_BYTES),
			room: boundedString(raw[5], "archive room", MAX_ARCHIVE_CONVERSATION_BYTES),
			nick: archiveName(raw[6], "archive nickname"),
			at: timestamp(raw[7]),
		};
	}
	if (raw[0] === "line") {
		if (raw.length !== 13) throw new Error("an archive line row has the wrong shape");
		const conversationKind = raw[4];
		if (conversationKind !== "room" && conversationKind !== "direct") {
			throw new Error("an archive line needs a conversation kind");
		}
		const state = raw[11];
		if (state !== "present" && state !== "edited" && state !== "withdrawn") {
			throw new Error("an archive line needs a state");
		}
		const text = boundedString(raw[8], "archive line", MAX_LINE, true);
		if (state === "withdrawn" && text !== "") throw new Error("a withdrawn archive line must erase its text");
		if (typeof raw[9] !== "boolean") throw new Error("an archive line needs its local direction");
		const attachments = parseArchivedAttachments(raw[12]);
		if (state === "withdrawn" && attachments.length > 0) {
			throw new Error("a withdrawn archive line must erase its attachment metadata");
		}
		return {
			kind: "line",
			...readCommon(raw as Argument[]),
			conversationKind,
			directory: boundedString(raw[5], "archive directory", MAX_ARCHIVE_CONTEXT_BYTES),
			conversation: boundedString(raw[6], "archive conversation", MAX_ARCHIVE_CONVERSATION_BYTES),
			from: archiveName(raw[7], "archive sender"),
			text,
			mine: raw[9],
			at: timestamp(raw[10]),
			state,
			attachments,
		};
	}
	throw new Error("archive record kind is unknown");
}

/** Encode one record without its storage-owned revision. */
export function archiveRecordRow(record: ArchiveRecord): Argument[] {
	if (record.kind === "standing") {
		return [
			"standing",
			record.source,
			record.generation,
			record.id,
			record.directory,
			record.room,
			record.nick,
			BigInt(record.at),
		];
	}
	return [
		"line",
		record.source,
		record.generation,
		record.id,
		record.conversationKind,
		record.directory,
		record.conversation,
		record.from,
		record.text,
		record.mine,
		BigInt(record.at),
		record.state,
		record.attachments.map((attachment) => [
			attachment.name,
			attachment.mime,
			BigInt(attachment.size),
			BigInt(attachment.width),
			BigInt(attachment.height),
			attachment.blob,
		]),
	];
}

function nullableString(raw: unknown, what: string, maxBytes: number): string | null {
	return raw === null ? null : boundedString(raw, what, maxBytes);
}

function archiveDigest(raw: unknown, what: string): string | null {
	if (raw === null) return null;
	if (typeof raw !== "string" || !/^[0-9a-f]{64}$/.test(raw)) throw new Error(`${what} has an invalid blob digest`);
	return raw;
}

export function parseArchiveFilter(raw: unknown): ArchiveFilter {
	if (!Array.isArray(raw) || raw.length !== 7) throw new Error("archive read needs one filter row");
	const kind = raw[2];
	if (kind !== null && kind !== "standing" && kind !== "line") throw new Error("archive filter kind is unknown");
	const conversationKind = raw[3];
	if (conversationKind !== null && conversationKind !== "room" && conversationKind !== "direct") {
		throw new Error("archive filter conversation kind is unknown");
	}
	return {
		source: raw[0] === null ? null : opaqueId(raw[0], "archive source filter"),
		generation: raw[1] === null ? null : opaqueId(raw[1], "archive generation filter"),
		kind,
		conversationKind,
		directory: nullableString(raw[4], "archive directory filter", MAX_ARCHIVE_CONTEXT_BYTES),
		conversation: nullableString(
			raw[5],
			"archive conversation filter",
			MAX_ARCHIVE_CONVERSATION_BYTES,
		),
		digest: archiveDigest(raw[6], "archive digest filter"),
	};
}

export function archiveFilterRow(filter: ArchiveFilter): Argument[] {
	return [
		filter.source,
		filter.generation,
		filter.kind,
		filter.conversationKind,
		filter.directory,
		filter.conversation,
		filter.digest,
	];
}

function safeRevision(raw: unknown, what: string): number {
	if (typeof raw !== "bigint" || raw < 0n || raw > BigInt(Number.MAX_SAFE_INTEGER)) {
		throw new Error(`${what} must be a non-negative safe integer`);
	}
	return Number(raw);
}

function readLimit(raw: unknown): number {
	if (typeof raw !== "bigint" || raw < 1n) throw new Error("archive read limit must be positive");
	return Number(raw > BigInt(MAX_ARCHIVE_READ) ? BigInt(MAX_ARCHIVE_READ) : raw);
}

function checkedBackendPage(
	page: ArchivePage,
	filter: ArchiveFilter,
	after: number,
	limit: number,
): ArchivePage {
	if (!Number.isSafeInteger(page.next) || page.next < after) {
		throw new Error("archive backend returned an invalid cursor");
	}
	if (page.records.length > limit) throw new Error("archive backend returned too many records");
	let prior = after;
	const records = page.records.map((entry): RevisedArchiveRecord => {
		if (!Number.isSafeInteger(entry.revision) || entry.revision <= prior || entry.revision > page.next) {
			throw new Error("archive backend returned records outside its revision page");
		}
		prior = entry.revision;
		const record = parseArchiveRecord(archiveRecordRow(entry.record));
		if (!archiveMatches(record, filter)) throw new Error("archive backend returned a record outside the filter");
		return { revision: entry.revision, record };
	});
	if (page.more && (records.length !== limit || page.next !== records.at(-1)?.revision)) {
		throw new Error("archive backend returned an invalid continuing page");
	}
	return { next: page.next, more: page.more, records };
}

/** The object hosted by a tab, archive peer, or narrowed facet. All untrusted
 * wire validation stays here, before storage sees a value. Narrowing returns a
 * session-scoped capability synchronously so it can cross as a capability. */
function archiveFacetBehavior(backend: ArchiveBackend, facet: ArchiveFacet, issuer: ArchiveFacetIssuer): Behavior {
	return (verb, args) => {
		const callerSession = currentSession() ?? issuer.localSession;
		if (verb !== ARCHIVE_PUT_FILES && hasCapabilityArguments(args)) {
			if (callerSession == null) throw new Error("an archive is reachable only over a session");
			throwAfterReleasingCapabilities(
				callerSession,
				args,
				new Error(`archive ${verb} does not take capability arguments`),
			);
		}
		if (verb === ARCHIVE_PUT) {
			if (args.length !== 1) throw new Error("archive put needs one record");
			if (facet.access !== "read-write") throw new Error("archive facet is read-only");
			const record = parseArchiveRecord(args[0]);
			if (!archiveMatches(record, facet.scope)) throw new Error("archive facet does not permit that record");
			return backend.put(record).then((revision) => {
				if (!Number.isSafeInteger(revision) || revision < 1) {
					throw new Error("archive backend returned an invalid revision");
				}
				return BigInt(revision);
			});
		}
		const blobResult = dispatchArchiveBlob(verb, args, backend, facet, {
			record: parseArchiveRecord,
		});
		if (blobResult !== ARCHIVE_BLOB_UNHANDLED) return blobResult;
		if (verb === ARCHIVE_READ) {
			if (args.length !== 3) throw new Error("archive read needs a filter, revision, and limit");
			const filter = intersectArchiveFilters(facet.scope, parseArchiveFilter(args[0]));
			const after = safeRevision(args[1], "archive read revision");
			const limit = readLimit(args[2]);
			if (filter === null) return [BigInt(after), false, []];
			return backend.read(filter, after, limit).then((raw) => {
				const page = checkedBackendPage(raw, filter, after, limit);
				return [
					BigInt(page.next),
					page.more,
					page.records.map((entry) => [BigInt(entry.revision), ...archiveRecordRow(entry.record)]),
				];
			});
		}
		if (verb === ARCHIVE_NARROW) {
			if (args.length !== 2) throw new Error("archive narrow needs a filter and access");
			const scope = intersectArchiveFilters(facet.scope, parseArchiveFilter(args[0]));
			if (scope === null) throw new Error("archive scopes do not overlap");
			const access = facetAccess(args[1]);
			if (facet.access === "read" && access === "read-write") {
				throw new Error("a read-only archive facet cannot be widened");
			}
			if (callerSession == null) throw new Error("archive narrow needs a live caller session");
			const minted = issuer.mintedBySession.get(callerSession) ?? 0;
			if (minted >= MAX_ARCHIVE_FACETS_PER_SESSION) {
				throw new Error("archive facet mint ceiling reached for this session");
			}
			const narrowed = callerSession.spawn(
				archiveFacetBehavior(backend, { scope, access }, { ...issuer, durableShares: null }),
			);
			issuer.mintedBySession.set(callerSession, minted + 1);
			return narrowed;
		}
		const shareResult = dispatchArchiveDurableShare(verb, args, facet, issuer, parseArchiveFilter);
		if (shareResult !== ARCHIVE_SHARE_UNHANDLED) return shareResult;
		throw new Error(`archive has no method ${verb}`);
	};
}

export function archiveBehavior(
	backend: ArchiveBackend,
	facet: ArchiveFacet = WHOLE_ARCHIVE,
	issuer: ArchiveFacetIssuer | null = null,
): Behavior {
	return archiveFacetBehavior(backend, facet, issuer ?? archiveFacetIssuer(null));
}

export function spawnArchive(session: Session, backend: ArchiveBackend): Ref {
	return session.spawn(archiveFacetBehavior(backend, WHOLE_ARCHIVE, archiveFacetIssuer(session)));
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
 * ceiling is also the per-walk allocation ceiling; reaching it with more still
 * promised is a refusal rather than an unbounded chase. */
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
