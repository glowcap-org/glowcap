// Read-only archive facets another member hands this tab over a direct line.
//
// The store sees only bounded presentation rows. This module owns every live
// imported Ref until the reader reads it once or gives it back, and validates
// the sender's claimed scope against the receiving directory before retention.

import { type Ref, type Session } from "@pancake/runtime";
import {
	ALL_ARCHIVE_RECORDS,
	type ArchiveFilter,
	archiveFilterRow,
	type ArchiveRecord,
	parseArchiveFilter,
	readAllArchiveRecords,
} from "../../../lib/archive.ts";
import { MAX_PENDING_ARCHIVE_SHARES } from "../../../lib/limits.ts";
import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { reason, trouble } from "./common.ts";
import { releaseIncomingRef } from "./direct_custody.ts";
import { hydrateDm, prependSharedArchive } from "./history.ts";
import { isCurrent, type Live } from "./live.ts";

interface HeldArchiveShare {
	readonly owner: Session;
	readonly archive: Ref;
	readonly filter: ArchiveFilter;
	readonly directory: DirId;
	readonly conversationKey: string;
	readonly from: string;
	readonly stopClose: () => void;
}

const heldShares = new Map<string, HeldArchiveShare>();
let shareSequence = 0n;

function disposeShare(id: string, what: string): void {
	const held = heldShares.get(id);
	heldShares.delete(id);
	store.dropArchiveShare(id);
	if (held === undefined) return;
	try {
		held.stopClose();
	} catch (error) {
		trouble("an archive-share close observer would not stop", error);
	}
	if (held.owner.sessionOpen) releaseIncomingRef(held.owner, held.archive, what);
}

/** Retain one incoming facet or refuse and release it in the same turn. */
export function receiveArchiveShare(
	home: Live,
	owner: Session,
	directory: unknown,
	conversation: unknown,
	archive: Ref,
	from: string,
	fromRegistrationId: string,
): void {
	let filter: ArchiveFilter;
	try {
		filter = parseArchiveFilter(archiveFilterRow({
			...ALL_ARCHIVE_RECORDS,
			kind: "line",
			conversationKind: "direct",
			directory: typeof directory === "string" ? directory : "",
			conversation: typeof conversation === "string" ? conversation : "",
		}));
	} catch (error) {
		releaseIncomingRef(owner, archive, "refused malformed archive share");
		throw error;
	}
	if (filter.directory !== home.id || filter.conversation == null) {
		releaseIncomingRef(owner, archive, "refused mis-scoped archive share");
		throw new Error("archive history must be scoped to this direct conversation");
	}
	if (!isCurrent(home) || store.get().archiveShares.length >= MAX_PENDING_ARCHIVE_SHARES) {
		releaseIncomingRef(owner, archive, "refused archive share");
		throw new Error(
			!isCurrent(home)
				? "they are between connections. Ask again in a moment"
				: "their shared-history list is full. Ask again after they answer one",
		);
	}
	const conv = store.ensureDm(home.id, from, fromRegistrationId);
	if (conv === null) {
		releaseIncomingRef(owner, archive, "refused archive share without a conversation");
		throw new Error("they cannot open another direct conversation");
	}
	hydrateDm(conv);
	shareSequence += 1n;
	const id = `archive-share:${shareSequence}`;
	const stopClose = owner.onClose(() => {
		if (!heldShares.has(id)) return;
		store.patchArchiveShare(id, {
			status: "unavailable",
			error: "The direct session carrying this archive share has ended.",
		});
	});
	heldShares.set(id, {
		owner,
		archive,
		filter,
		directory: home.id,
		conversationKey: conv.key,
		from,
		stopClose,
	});
	store.addArchiveShare({ id, conversationKey: conv.key, from, status: "offered", error: "" });
	store.deliver(
		conv.key,
		store.sysItem(
			`${from} shared read-only history for this conversation. Open conversation details to read or give it back.`,
		),
	);
}

/** Read one offered snapshot, attribute it, then return the capability. */
export async function readArchiveShare(id: string): Promise<string> {
	const held = heldShares.get(id);
	if (held === undefined) return "That shared archive is no longer available.";
	store.patchArchiveShare(id, { status: "reading", error: "" });
	try {
		const records: ArchiveRecord[] = await readAllArchiveRecords(held.owner, held.archive, held.filter);
		if (heldShares.get(id) !== held) return "";
		prependSharedArchive(held.conversationKey, records, held.from);
		store.deliver(
			held.conversationKey,
			store.sysItem(`You read the history ${held.from} shared and gave it back.`),
		);
		disposeShare(id, "consumed archive share");
		return "";
	} catch (error) {
		const why = reason(error);
		if (heldShares.get(id) === held) store.patchArchiveShare(id, { status: "unavailable", error: why });
		return why;
	}
}

export function dropArchiveShare(id: string): void {
	disposeShare(id, "declined archive share");
}

export function releaseArchiveSharesForConversation(key: string): void {
	for (const [id, held] of heldShares) {
		if (held.conversationKey === key) disposeShare(id, "closed archive-share conversation");
	}
}

export function releaseArchiveSharesForDirectory(dir: DirId): void {
	for (const [id, held] of heldShares) {
		if (held.directory === dir) disposeShare(id, "abandoned archive share");
	}
}
