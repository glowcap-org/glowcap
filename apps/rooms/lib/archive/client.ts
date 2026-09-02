// Session-side calls for independently revocable archive-peer shares (ADR-0140).

import type { Ref, Session } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import { type ArchiveFilter, archiveFilterRow, parseArchiveFilter } from "./protocol.ts";
import { ARCHIVE_LIST_SHARES, ARCHIVE_REVOKE_SHARE, ARCHIVE_SHARE } from "./durable_protocol.ts";
import { parseRoomsSturdyref } from "../locator.ts";
import type { ArchiveDurableShareView } from "./facet.ts";

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
