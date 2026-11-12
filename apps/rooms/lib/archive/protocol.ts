// The member-owned Rooms archive capability (ADR-0044).
//
// This is application protocol, not a storage engine. An archive is one
// ordinary object whose storage verbs are `put` and `read`. `narrow` creates a
// monotonically scoped forwarding facet without touching storage. Browser
// IndexedDB and the standalone peer implement the same backend boundary. Every
// value here can cross either Rooms wire profile, and no binding-local object
// shape participates in the contract.

import { type Argument, type Behavior, currentSession, type Ref, type Session } from "@glowcap/runtime";
import { ARCHIVE_BLOB_UNHANDLED, ARCHIVE_PUT_FILES, dispatchArchiveBlob } from "./blob_protocol.ts";
import { ARCHIVE_SHARE_UNHANDLED, dispatchArchiveDurableShare } from "./durable_protocol.ts";
import { boundedString, opaqueId } from "./record.ts";
import { type ArchiveFilter, archiveMatches, intersectArchiveFilters } from "./scope.ts";
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
export type { ArchivedAttachment } from "./record_attachments.ts";

export const ARCHIVE_PUT = "put";
export const ARCHIVE_READ = "read";
export const ARCHIVE_NARROW = "narrow";
export { ARCHIVE_ATTACHMENT, ARCHIVE_BLOB, ARCHIVE_PUT_FILES } from "./blob_protocol.ts";
export { ARCHIVE_LIST_SHARES, ARCHIVE_REVOKE_SHARE, ARCHIVE_SHARE } from "./durable_protocol.ts";

/** Largest page one read can answer in a single CapTP turn. */
import { MAX_ARCHIVE_FACETS_PER_SESSION, MAX_ARCHIVE_READ } from "./limits.ts";
export { MAX_ARCHIVE_READ } from "./limits.ts";
/** Fresh forwarding actors one caller session may create over its lifetime.
 * Released facets do not refill the budget, because actor churn is still work
 * and consumes monotonic export positions even when no occurrence remains live. */
export { MAX_ARCHIVE_FACETS_PER_SESSION } from "./limits.ts";

// The record itself, and the one validator behind every form of it, live in
// `record.ts` so a reader with no session can hold one. The verbs stay here.
export {
	type ArchiveCoordinates,
	type ArchiveLine,
	type ArchiveLineState,
	type ArchiveRecord,
	archiveRecordRow,
	type ArchiveStanding,
	MAX_ARCHIVE_CONTEXT_BYTES,
	MAX_ARCHIVE_CONVERSATION_BYTES,
	MAX_ARCHIVE_ID_BYTES,
	parseArchiveCoordinates,
	parseArchiveRecord,
} from "./record.ts";
import {
	type ArchiveRecord,
	archiveRecordRow,
	MAX_ARCHIVE_CONTEXT_BYTES,
	MAX_ARCHIVE_CONVERSATION_BYTES,
	parseArchiveRecord,
} from "./record.ts";
export { sameArchiveCoordinates } from "./coordinates.ts";

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

/** A revision or cursor off the wire, as the page's number. */
export function safeRevision(raw: unknown, what: string): number {
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
		if (verb === null) throw new Error("archive has no positional invocation");
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
