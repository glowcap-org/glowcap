// The narrowing authority and per-root issuer state of an archive capability.

import type { Session } from "@glowcap/runtime";
import { ALL_ARCHIVE_RECORDS, type ArchiveAccess, type ArchiveFilter } from "./scope.ts";

export interface ArchiveFacet {
	readonly scope: ArchiveFilter;
	readonly access: ArchiveAccess;
}

export const WHOLE_ARCHIVE: ArchiveFacet = { scope: ALL_ARCHIVE_RECORDS, access: "read-write" };

/** Issues, revokes, and lists the durable shares of one archive root. */
export interface ArchiveDurableShareIssuer {
	issue(id: string, label: string, filter: ArchiveFilter): Promise<string>;
	revoke(id: string): Promise<boolean>;
	list(): Promise<readonly ArchiveDurableShareView[]>;
}

export interface ArchiveDurableShareView {
	readonly id: string;
	readonly label: string;
	readonly filter: ArchiveFilter;
	readonly sturdyref: string;
}

/** One archive root's facet issuer. A hosted archive normally learns the
 * caller from an inbound turn. A session-local occurrence also names the
 * session on which local application calls must create their returned refs. */
export interface ArchiveFacetIssuer {
	readonly localSession: Session | null;
	readonly mintedBySession: WeakMap<Session, number>;
	readonly durableShares: ArchiveDurableShareIssuer | null;
}

export function archiveFacetIssuer(
	localSession: Session | null,
	durableShares: ArchiveDurableShareIssuer | null = null,
): ArchiveFacetIssuer {
	return { localSession, mintedBySession: new WeakMap(), durableShares };
}

export function facetAccess(raw: unknown): ArchiveAccess {
	if (raw === "read" || raw === "read-write") return raw;
	throw new Error("archive narrow access must be read or read-write");
}
