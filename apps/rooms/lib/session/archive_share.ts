// Client protocol for archive shares offered through a durable Rooms session.

import type { Ref, Session } from "@glowcap/runtime";
import { ask } from "../ask.ts";
import {
	type ArchiveRecord,
	MAX_ARCHIVE_READ,
	MAX_ARCHIVE_RECORDS,
	parseArchiveFilter,
	parseArchiveRecord,
} from "../archive/protocol.ts";
import type { ArchiveDurableShareView } from "../archive/facet.ts";
import { parseRoomsSturdyref } from "../locator.ts";
import { parseRoomsSessionArchiveShare, type RoomsSessionArchiveShare } from "./messages.ts";

export const ROOMS_SESSION_ARCHIVE_SHARE = "shareArchive";
export const ROOMS_SESSION_ARCHIVE_SHARE_READ = "readArchiveShare";
export const ROOMS_SESSION_ARCHIVE_SHARE_DROP = "dropArchiveShare";
export const ROOMS_SESSION_OFFER_DURABLE_ARCHIVE = "offerDurableArchive";
export const ROOMS_SESSION_LIST_ARCHIVE_SHARES = "listArchiveShares";
export const ROOMS_SESSION_REVOKE_ARCHIVE_SHARE = "revokeArchiveShare";

function sameArchiveShare(left: RoomsSessionArchiveShare, right: RoomsSessionArchiveShare): boolean {
	return left.id === right.id && left.directory === right.directory && left.conversationId === right.conversationId &&
		left.from === right.from && left.status === right.status && left.error === right.error &&
		left.kind === right.kind && left.scopeConversation === right.scopeConversation &&
		left.custody === right.custody && left.sturdyref === right.sturdyref;
}

export function shareRoomsSessionArchive(
	session: Session,
	capability: Ref,
	kind: string,
	conversationId: string,
	peer = "",
): Promise<void> {
	return ask(
		session,
		capability,
		ROOMS_SESSION_ARCHIVE_SHARE,
		peer === "" ? [kind, conversationId] : [kind, conversationId, peer],
		"the Rooms session did not share archive history",
	).then(() => {});
}

export async function readRoomsSessionArchiveShare(
	session: Session,
	capability: Ref,
	id: string,
): Promise<{ view: RoomsSessionArchiveShare; records: ArchiveRecord[] }> {
	const records: ArchiveRecord[] = [];
	let after = 0;
	let view: RoomsSessionArchiveShare | null = null;
	let more = true;
	do {
		const raw = await ask(
			session,
			capability,
			ROOMS_SESSION_ARCHIVE_SHARE_READ,
			[id, BigInt(after)],
			"the Rooms session did not read shared archive history",
		);
		if (
			!Array.isArray(raw) || raw.length !== 4 || typeof raw[0] !== "string" || raw[0].length > 128 * 1024 ||
			typeof raw[1] !== "bigint" || raw[1] < 0n || raw[1] > BigInt(Number.MAX_SAFE_INTEGER) ||
			typeof raw[2] !== "boolean" || !Array.isArray(raw[3]) || raw[3].length > MAX_ARCHIVE_READ
		) {
			throw new Error("the Rooms session answered an invalid archive share");
		}
		let decodedView: unknown;
		try {
			decodedView = JSON.parse(raw[0]);
		} catch {
			throw new Error("the Rooms session answered an archive-share view that is not JSON");
		}
		const parsedView = parseRoomsSessionArchiveShare(decodedView);
		if (view == null) view = parsedView;
		else if (!sameArchiveShare(view, parsedView)) {
			throw new Error("the Rooms session changed an archive-share view between pages");
		}
		records.push(...raw[3].map(parseArchiveRecord));
		if (records.length > MAX_ARCHIVE_RECORDS) throw new Error("the shared archive exceeds its record ceiling");
		const next = Number(raw[1]);
		more = raw[2];
		if (next < after || (more && next === after)) {
			throw new Error("the Rooms session archive share did not advance its cursor");
		}
		after = next;
	} while (more);
	if (view == null) throw new Error("the Rooms session answered no archive-share view");
	return { view, records };
}

export function dropRoomsSessionArchiveShare(session: Session, capability: Ref, id: string): Promise<void> {
	return ask(
		session,
		capability,
		ROOMS_SESSION_ARCHIVE_SHARE_DROP,
		[id],
		"the Rooms session did not drop the archive share",
	).then(() => {});
}

export function offerRoomsSessionDurableArchive(
	session: Session,
	capability: Ref,
	kind: string,
	conversationId: string,
	peer = "",
): Promise<void> {
	return ask(
		session,
		capability,
		ROOMS_SESSION_OFFER_DURABLE_ARCHIVE,
		peer === "" ? [kind, conversationId] : [kind, conversationId, peer],
		"the Rooms session did not offer a durable archive share",
	).then(() => {});
}

export function revokeRoomsSessionArchiveShare(session: Session, capability: Ref, id: string): Promise<boolean> {
	return ask(
		session,
		capability,
		ROOMS_SESSION_REVOKE_ARCHIVE_SHARE,
		[id],
		"the Rooms session did not revoke the archive share",
	).then((raw) => {
		if (typeof raw !== "boolean") {
			throw new Error("the Rooms session answered revokeArchiveShare without a boolean");
		}
		return raw;
	});
}

export async function listRoomsSessionIssuedArchiveShares(
	session: Session,
	capability: Ref,
): Promise<ArchiveDurableShareView[]> {
	const raw = await ask(
		session,
		capability,
		ROOMS_SESSION_LIST_ARCHIVE_SHARES,
		[],
		"the Rooms session did not list archive shares",
	);
	if (!Array.isArray(raw)) throw new Error("the Rooms session answered an invalid archive share list");
	return raw.map((entry) => {
		if (
			!Array.isArray(entry) || entry.length !== 4 || typeof entry[0] !== "string" ||
			typeof entry[1] !== "string" || typeof entry[3] !== "string"
		) {
			throw new Error("the Rooms session answered an invalid issued archive share");
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
