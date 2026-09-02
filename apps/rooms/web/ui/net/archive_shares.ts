// Read-only archive facets another member hands this tab over a direct line.
//
// The store sees only bounded presentation rows. This module owns every live
// imported Ref until the reader reads it once or gives it back, and validates
// the sender's claimed scope against the receiving directory before retention.

import * as store from "../store.ts";
import { type Ref, type Session } from "@glowcap/runtime";
import {
	ALL_ARCHIVE_RECORDS,
	type ArchiveFilter,
	archiveFilterRow,
	type ArchiveRecord,
	parseArchiveFilter,
	readAllArchiveRecords,
} from "../../../lib/archive/protocol.ts";
import { archiveShareFilter, type ArchiveShareKind, parseArchiveShareKind } from "../../../lib/archive/handover.ts";
import { parseRoomsSturdyref } from "../../../lib/locator.ts";
import { MAX_PENDING_ARCHIVE_SHARES } from "../../../lib/limits.ts";
import type { DirId } from "../types.ts";
import { reason, trouble } from "./common.ts";
import { releaseIncomingRef } from "./direct_custody.ts";
import { hydrateDm, prependSharedArchive } from "./history.ts";
import { isCurrent, type Live } from "./live.ts";
import type { RoomsPageContext } from "../page.ts";
import { bootRuntime } from "./runtime_boot.ts";

interface HeldArchiveShare {
	readonly owner: Session;
	readonly archive: Ref;
	readonly filter: ArchiveFilter;
	readonly directory: DirId;
	readonly conversationKey: string;
	readonly from: string;
	readonly kind: ArchiveShareKind;
	readonly stopClose: () => void;
}

/** Incoming archive-share occurrences until one read or give-back. */
export class PageArchiveShares {
	readonly held = new Map<string, HeldArchiveShare>();
	sequence = 0n;
}

function disposeShare(page: RoomsPageContext, id: string, what: string): void {
	const projection = page.projection;
	const held = page.shares.held.get(id);
	page.shares.held.delete(id);
	store.dropArchiveShare(projection, id);
	if (held === undefined) return;
	try {
		held.stopClose();
	} catch (error) {
		trouble(projection, "an archive-share close observer would not stop", error);
	}
	if (held.owner.sessionOpen) releaseIncomingRef(projection, held.owner, held.archive, what);
}

function scopeOf(
	kindRaw: unknown,
	directory: unknown,
	conversation: unknown,
): ArchiveFilter {
	const kind = parseArchiveShareKind(kindRaw);
	if (typeof directory !== "string") throw new Error("archive history must name this directory");
	if (kind !== "standing" && typeof conversation !== "string") {
		throw new Error("archive history must name a conversation");
	}
	if (conversation !== null && typeof conversation !== "string") {
		throw new Error("archive history conversation must be a string or null");
	}
	return parseArchiveFilter(archiveFilterRow(archiveShareFilter(kind, directory, conversation)));
}

function shareSaid(kind: ArchiveShareKind, conversation: string | null, from: string): string {
	if (kind === "direct") {
		return `${from} shared read-only history for this conversation. Open conversation details to read or give it back.`;
	}
	if (kind === "standing") {
		return conversation == null
			? `${from} shared a read-only archive standing for this directory. Open conversation details to read or give it back.`
			: `${from} shared a read-only archive standing for ${conversation}. Open conversation details to read or give it back.`;
	}
	return `${from} shared a read-only archive account of ${conversation}. Open conversation details to read or give it back.`;
}

/** Retain one incoming facet or refuse and release it in the same turn. */
export function receiveArchiveShare(
	home: Live,
	owner: Session,
	directory: unknown,
	kindRaw: unknown,
	conversation: unknown,
	archive: Ref,
	from: string,
	fromRegistrationId: string,
): void {
	const page = home.page;
	let filter: ArchiveFilter;
	let kind: ArchiveShareKind;
	try {
		kind = parseArchiveShareKind(kindRaw);
		filter = scopeOf(kindRaw, directory, conversation);
	} catch (error) {
		releaseIncomingRef(page.projection, owner, archive, "refused malformed archive share");
		throw error;
	}
	if (filter.directory !== home.id) {
		releaseIncomingRef(page.projection, owner, archive, "refused mis-scoped archive share");
		throw new Error("archive history must be scoped to this directory");
	}
	if (kind !== "standing" && filter.conversation == null) {
		releaseIncomingRef(page.projection, owner, archive, "refused mis-scoped archive share");
		throw new Error("archive history must name a conversation");
	}
	if (!isCurrent(home) || page.projection.get().archiveShares.length >= MAX_PENDING_ARCHIVE_SHARES) {
		releaseIncomingRef(page.projection, owner, archive, "refused archive share");
		throw new Error(
			!isCurrent(home)
				? "they are between connections. Ask again in a moment"
				: "their shared-history list is full. Ask again after they answer one",
		);
	}
	const conv = store.ensureDm(page.projection, home.id, from, fromRegistrationId);
	if (conv === null) {
		releaseIncomingRef(page.projection, owner, archive, "refused archive share without a conversation");
		throw new Error("they cannot open another direct conversation");
	}
	hydrateDm(home.page, conv);
	home.page.shares.sequence += 1n;
	const id = `archive-share:${home.page.shares.sequence}`;
	const stopClose = owner.onClose(() => {
		if (!home.page.shares.held.has(id)) return;
		store.patchArchiveShare(page.projection, id, {
			status: "unavailable",
			error: "The direct session carrying this archive share has ended.",
		});
	});
	home.page.shares.held.set(id, {
		owner,
		archive,
		filter,
		directory: home.id,
		conversationKey: conv.key,
		from,
		kind,
		stopClose,
	});
	store.addArchiveShare(page.projection, {
		id,
		conversationKey: conv.key,
		from,
		status: "offered",
		error: "",
		kind,
		scopeConversation: filter.conversation,
		custody: "live",
		sturdyref: "",
	});
	store.deliver(
		page.projection,
		conv.key,
		store.sysItem(page.projection, shareSaid(kind, filter.conversation, from)),
	);
}

/** Retain a durable archive-peer share independently of the carrying DM. */
export function receiveDurableArchiveOffer(
	home: Live,
	directory: unknown,
	kindRaw: unknown,
	conversation: unknown,
	sturdyref: unknown,
	from: string,
	fromRegistrationId: string,
): void {
	const page = home.page;
	const kind = parseArchiveShareKind(kindRaw);
	const filter = scopeOf(kindRaw, directory, conversation);
	if (typeof sturdyref !== "string") {
		throw new Error("a durable archive offer needs a sturdyref");
	}
	parseRoomsSturdyref(sturdyref);
	if (filter.directory !== home.id) {
		throw new Error("archive history must be scoped to this directory");
	}
	if (kind !== "standing" && filter.conversation == null) {
		throw new Error("archive history must name a conversation");
	}
	if (!isCurrent(home) || page.projection.get().archiveShares.length >= MAX_PENDING_ARCHIVE_SHARES) {
		throw new Error(
			!isCurrent(home)
				? "they are between connections. Ask again in a moment"
				: "their shared-history list is full. Ask again after they answer one",
		);
	}
	const conv = store.ensureDm(page.projection, home.id, from, fromRegistrationId);
	if (conv === null) throw new Error("they cannot open another direct conversation");
	hydrateDm(home.page, conv);
	home.page.shares.sequence += 1n;
	const id = `archive-share:${home.page.shares.sequence}`;
	store.addArchiveShare(page.projection, {
		id,
		conversationKey: conv.key,
		from,
		status: "offered",
		error: "",
		kind,
		scopeConversation: filter.conversation,
		custody: "durable",
		sturdyref,
	});
	store.deliver(
		page.projection,
		conv.key,
		store.sysItem(
			page.projection,
			`${from} offered a durable archive share. It stays valid until they revoke it.`,
		),
	);
}

async function readDurableShare(page: RoomsPageContext, id: string): Promise<string> {
	const projection = page.projection;
	const view = projection.get().archiveShares.find((share) => share.id === id);
	if (view == null || view.custody !== "durable") return "That shared archive is no longer available.";
	store.patchArchiveShare(projection, id, { status: "reading", error: "" });
	const parsed = parseRoomsSturdyref(view.sturdyref);
	const runtime = await bootRuntime(page);
	const session = await runtime.connect(parsed.locator);
	try {
		const archive = await session.enliven(view.sturdyref);
		const records = await readAllArchiveRecords(session, archive, ALL_ARCHIVE_RECORDS);
		if (projection.get().archiveShares.every((share) => share.id !== id)) return "";
		prependSharedArchive(page, view.conversationKey, records, view.from);
		store.patchArchiveShare(projection, id, { status: "offered", error: "" });
		store.deliver(
			projection,
			view.conversationKey,
			store.sysItem(projection, `You read the durable archive ${view.from} offered.`),
		);
		return "";
	} catch (error) {
		const why = reason(error);
		if (projection.get().archiveShares.some((share) => share.id === id)) {
			store.patchArchiveShare(projection, id, { status: "unavailable", error: why });
		}
		return why;
	} finally {
		await session.close();
	}
}

/** Read one offered snapshot. A live facet is returned after one read; a durable
 * share remains until the issuer revokes it or this tab forgets the reminder. */
export async function readArchiveShare(page: RoomsPageContext, id: string): Promise<string> {
	const offered = page.projection.get().archiveShares.find((share) => share.id === id);
	if (offered?.custody === "durable") return await readDurableShare(page, id);
	const projection = page.projection;
	const held = page.shares.held.get(id);
	if (held === undefined) return "That shared archive is no longer available.";
	store.patchArchiveShare(projection, id, { status: "reading", error: "" });
	try {
		const records: ArchiveRecord[] = await readAllArchiveRecords(held.owner, held.archive, held.filter);
		if (page.shares.held.get(id) !== held) return "";
		prependSharedArchive(page, held.conversationKey, records, held.from);
		store.deliver(
			projection,
			held.conversationKey,
			store.sysItem(projection, `You read the history ${held.from} shared and gave it back.`),
		);
		disposeShare(page, id, "consumed archive share");
		return "";
	} catch (error) {
		const why = reason(error);
		if (page.shares.held.get(id) === held) {
			store.patchArchiveShare(projection, id, { status: "unavailable", error: why });
		}
		return why;
	}
}

export function dropArchiveShare(page: RoomsPageContext, id: string): void {
	disposeShare(page, id, "declined archive share");
}

export function releaseArchiveSharesForConversation(page: RoomsPageContext, key: string): void {
	for (const [id, held] of page.shares.held) {
		if (held.conversationKey === key) disposeShare(page, id, "closed archive-share conversation");
	}
}

export function releaseArchiveSharesForDirectory(page: RoomsPageContext, dir: DirId): void {
	for (const [id, held] of page.shares.held) {
		if (held.directory === dir) disposeShare(page, id, "abandoned archive share");
	}
	for (const share of page.projection.get().archiveShares) {
		if (share.custody !== "durable") continue;
		const conversation = store.getConv(page.projection, share.conversationKey);
		if (conversation?.dir === dir) store.dropArchiveShare(page.projection, share.id);
	}
}
