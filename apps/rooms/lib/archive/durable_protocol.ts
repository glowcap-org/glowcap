// Durable share verbs on the whole-archive root. Narrowed facets cannot create shares.

import { type Argument, type Behavior } from "@glowcap/runtime";
import { type ArchiveFacet, type ArchiveFacetIssuer } from "./facet.ts";
import { type ArchiveFilter } from "./scope.ts";
import { boundedText } from "../schema.ts";
import { MAX_SESSION_GRANT_LABEL } from "../limits.ts";
import * as z from "zod/mini";

const shareId = z.string().check(z.regex(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/));
const shareLabel = boundedText(MAX_SESSION_GRANT_LABEL).check(z.refine((label) => label.trim() !== ""));

export const ARCHIVE_SHARE = "share";
export const ARCHIVE_REVOKE_SHARE = "revokeShare";
export const ARCHIVE_LIST_SHARES = "shares";
export const ARCHIVE_SHARE_UNHANDLED = Symbol("archive durable share verb not handled");
export const ARCHIVE_CANNOT_MINT_SHARE = "this archive cannot mint a durable share";

function isWholeReadWrite(facet: ArchiveFacet): boolean {
	const scope = facet.scope;
	return facet.access === "read-write" && scope.source === null && scope.generation === null &&
		scope.kind === null && scope.conversationKind === null && scope.directory === null &&
		scope.conversation === null && scope.digest === null;
}

export function dispatchArchiveDurableShare(
	verb: string,
	args: Argument[],
	facet: ArchiveFacet,
	issuer: ArchiveFacetIssuer,
	parseFilter: (raw: unknown) => ArchiveFilter,
): ReturnType<Behavior> | typeof ARCHIVE_SHARE_UNHANDLED {
	if (verb !== ARCHIVE_SHARE && verb !== ARCHIVE_REVOKE_SHARE && verb !== ARCHIVE_LIST_SHARES) {
		return ARCHIVE_SHARE_UNHANDLED;
	}
	const shares = issuer.durableShares;
	if (shares == null) throw new Error(ARCHIVE_CANNOT_MINT_SHARE);
	if (!isWholeReadWrite(facet)) throw new Error("only the whole archive can mint a durable share");
	if (verb === ARCHIVE_LIST_SHARES) {
		if (args.length !== 0) throw new Error("archive shares takes no arguments");
		return shares.list().then((listed) =>
			listed.map((share) => [share.id, share.label, [
				share.filter.source,
				share.filter.generation,
				share.filter.kind,
				share.filter.conversationKind,
				share.filter.directory,
				share.filter.conversation,
				share.filter.digest,
			], share.sturdyref])
		);
	}
	if (verb === ARCHIVE_REVOKE_SHARE) {
		if (args.length !== 1 || typeof args[0] !== "string") {
			throw new Error("archive revokeShare takes one share id");
		}
		return shares.revoke(args[0]);
	}
	if (args.length !== 3 || typeof args[0] !== "string" || typeof args[1] !== "string") {
		throw new Error("archive share takes an id, label, and filter");
	}
	const id = z.safeParse(shareId, args[0]);
	if (!id.success) throw new Error("archive share id must be a UUID");
	const label = z.safeParse(shareLabel, args[1]);
	if (!label.success) throw new Error("archive share label is invalid");
	return shares.issue(id.data, label.data, parseFilter(args[2]));
}
