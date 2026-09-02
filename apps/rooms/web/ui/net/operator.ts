// The Rooms application operator capability as this browser tab holds it.

import * as store from "../store.ts";
import {
	clearOperatorTrouble,
	disconnectSession,
	giveRoomManager,
	giveStewardship,
	type OperatorCategory,
	operatorPage,
	type OperatorReferenceKind,
	type OperatorResetScope,
	type OperatorRetireBatch,
	operatorRetireMatching,
	releaseOperatorReference,
	removeOperatorRoom,
	resetOperatorScope,
	revokeNick,
	revokeRoomAuthority,
	revokeRoomLink,
	revokeStewardship,
	snapshotOperator,
	type StewardshipRow,
	subscribeOperator,
	takeRoomsOperator,
} from "../../../lib/room/client.ts";
import type { DirId, RoomsOperatorState } from "../types.ts";
import type { RoomAuthorityKind } from "../../../lib/room/authority.ts";
import { DIRECTORY_NOT_CONNECTED, liveHomeDir, opsLost, reason } from "./common.ts";
import type { RoomsPageContext } from "../page.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";
import { invalidateOperations } from "../ops/invalidation.ts";
import { settleCapabilityCleanup } from "../../../lib/capability_cleanup.ts";
import { type HeldDirectoryCapability, releaseHeldCapability } from "./held_capability.ts";
import { OperatorRefreshQueue } from "../ops/operator_refresh.ts";
import type { Ref, Session } from "@glowcap/runtime";
type OperatorFilter = { search: string; referenceKind: OperatorReferenceKind | null };

interface HeldOperator extends HeldDirectoryCapability {
	stopWatch: (() => void) | null;
	refresh: OperatorRefreshQueue<OperatorFilter>;
}

/** The Rooms operator capability one page fetched. */
export class PageOperator {
	held: HeldOperator | null = null;
}

function heldOperator(page: RoomsPageContext, session: Session, cap: Ref, dir: DirId): HeldOperator {
	const held: HeldOperator = {
		session,
		cap,
		dir,
		stopWatch: null,
		refresh: new OperatorRefreshQueue((filter, current) => readOperator(page, held, filter, current)),
	};
	return held;
}

function retireOperator(page: RoomsPageContext, held: HeldOperator | null): void {
	if (held == null) return;
	settleCapabilityCleanup("operator watcher cleanup failed", () => held.stopWatch?.());
	releaseHeldCapability(held, "operator capability release failed");
	if (page.operator.held !== held) return;
	page.operator.held = null;
	store.setRoomsOperator(page.projection, null);
}

function viewOf(row: StewardshipRow) {
	return {
		name: row.name,
		label: row.label,
		visibility: row.visibility,
		generation: row.generation,
		issued: row.issued,
		stewardLink: row.steward,
	};
}

export function operatorStateOf(
	snapshot: Awaited<ReturnType<typeof snapshotOperator>>,
	search = "",
	referenceKind: OperatorReferenceKind | null = null,
): RoomsOperatorState {
	return {
		revision: snapshot.revision,
		totals: snapshot.totals,
		search,
		referenceKind,
		stewardships: snapshot.stewardships.map(viewOf),
		links: snapshot.links,
		registrations: snapshot.registrations,
		sessions: snapshot.sessions,
		rooms: snapshot.rooms,
		references: snapshot.references,
		trouble: snapshot.trouble,
		next: snapshot.next,
	};
}

export function appendOperatorPage(current: RoomsOperatorState, page: Awaited<ReturnType<typeof operatorPage>>) {
	const next = {
		...current,
		next: { ...current.next, [page.category]: page.next },
		totals: { ...current.totals, [page.category]: page.total },
	};
	if (page.category === "stewardships") {
		next.stewardships = [...current.stewardships, ...page.rows.map(viewOf)];
	} else if (page.category === "links") {
		next.links = [...current.links, ...page.rows];
	} else if (page.category === "registrations") {
		next.registrations = [...current.registrations, ...page.rows];
	} else if (page.category === "sessions") {
		next.sessions = [...current.sessions, ...page.rows];
	} else if (page.category === "rooms") {
		next.rooms = [...current.rooms, ...page.rows];
	} else if (page.category === "references") {
		next.references = [...current.references, ...page.rows];
	} else next.trouble = [...current.trouble, ...page.rows];
	return next;
}

export function dropOperatorHold(page: RoomsPageContext): void {
	retireOperator(page, page.operator.held);
}

export function dropOperatorCap(page: RoomsPageContext, updateVault = true): void {
	const held = page.operator.held;
	if (held == null) return;
	if (updateVault && !forgetOpsSwiss(page, "operator", held.dir)) {
		store.noteTrouble(
			page.projection,
			"capability storage",
			"the saved Rooms operator capability could not be removed",
		);
		return;
	}
	retireOperator(page, held);
}

export async function takeOperatorCap(page: RoomsPageContext, pasted: string, remember = false): Promise<string> {
	const live = liveHomeDir(page);
	if (live === null) return DIRECTORY_NOT_CONNECTED;
	try {
		const taken = await takeRoomsOperator(live.dir.session, pasted);
		const held = heldOperator(page, live.dir.session, taken.cap, live.id);
		try {
			held.stopWatch = await subscribeOperator(
				held.session,
				held.cap,
				() => {
					if (page.operator.held === held) void invalidateOperations(page, live.id);
				},
			);
		} catch (error) {
			settleCapabilityCleanup(
				"unwatched operator capability release failed",
				() => held.session.release(held.cap),
			);
			return reason(error);
		}
		const stored = remember
			? rememberOpsSwiss(page, "operator", live.id, pasted)
			: forgetOpsSwiss(page, "operator", live.id);
		if (!stored) {
			retireOperator(page, held);
			return "This browser refused to update the saved Rooms operator capability.";
		}
		const previous = page.operator.held;
		page.operator.held = held;
		retireOperator(page, previous);
		store.setRoomsOperator(page.projection, operatorStateOf(taken.snapshot));
		return "";
	} catch (error) {
		return reason(error);
	}
}

export function refreshOperator(
	page: RoomsPageContext,
	search?: string,
	referenceKind: OperatorReferenceKind | null = null,
): Promise<void> {
	const held = page.operator.held;
	if (held == null) return Promise.resolve();
	return held.refresh.request(search == null ? undefined : { search, referenceKind });
}

async function readOperator(
	page: RoomsPageContext,
	held: HeldOperator,
	filter: OperatorFilter | undefined,
	currentRequest: () => boolean,
): Promise<void> {
	if (page.operator.held !== held) return;
	const currentFilter = page.projection.get().operator;
	const asked = filter?.search ?? currentFilter?.search ?? "";
	const referenceKind = filter != null ? filter.referenceKind : currentFilter?.referenceKind ?? null;
	try {
		const rows = await snapshotOperator(held.session, held.cap, asked, referenceKind);
		if (page.operator.held !== held || !currentRequest()) return;
		const current = page.projection.get().operator;
		// A search answer is the newest word about what matches, even when the
		// inventory has not moved, so only an *older* inventory is dropped.
		if (
			current != null && rows.revision < current.revision && asked === current.search &&
			referenceKind === current.referenceKind
		) return;
		store.setRoomsOperator(page.projection, operatorStateOf(rows, asked, referenceKind));
	} catch (error) {
		if (page.operator.held !== held || !currentRequest()) return;
		dropOperatorHold(page);
		opsLost(page.projection, "operator", reason(error));
	}
}

async function mutate(page: RoomsPageContext, run: (session: Session, cap: Ref) => Promise<void>): Promise<string> {
	const held = page.operator.held;
	if (held == null) return "This tab no longer holds the Rooms operator capability.";
	try {
		await run(held.session, held.cap);
		if (page.operator.held === held) await invalidateOperations(page, held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}

export function requestRoomLinkRevoke(page: RoomsPageContext, name: string): Promise<string> {
	return mutate(page, (session, cap) => revokeRoomLink(session, cap, name));
}

export function requestRoomAuthorityRevoke(
	page: RoomsPageContext,
	kind: RoomAuthorityKind,
	token: string,
): Promise<string> {
	return mutate(page, (session, cap) => revokeRoomAuthority(session, cap, kind, token));
}

export async function requestRoomManager(
	page: RoomsPageContext,
	roomIdentity: string,
): Promise<{ manager: string } | { refused: string }> {
	let manager = "";
	const refused = await mutate(page, async (session, cap) => {
		manager = await giveRoomManager(session, cap, roomIdentity);
	});
	return refused === "" ? { manager } : { refused };
}

export function requestNickRevoke(page: RoomsPageContext, nick: string, sessionId: string): Promise<string> {
	return mutate(page, (session, cap) => revokeNick(session, cap, nick, sessionId));
}

export function requestSessionDisconnect(page: RoomsPageContext, id: string): Promise<string> {
	return mutate(page, (session, cap) => disconnectSession(session, cap, id));
}

export function requestOperatorRoomRemove(page: RoomsPageContext, id: string): Promise<string> {
	return mutate(page, (session, cap) => removeOperatorRoom(session, cap, id));
}

export function requestOperatorReferenceRelease(page: RoomsPageContext, id: string): Promise<string> {
	return mutate(page, (session, cap) => releaseOperatorReference(session, cap, id));
}

export function requestOperatorTroubleClear(page: RoomsPageContext): Promise<string> {
	return mutate(page, (session, cap) => clearOperatorTrouble(session, cap));
}

/** Retire one bounded batch of the rows matching a search. The caller runs
 * again while rows remain, so a sweep over a very large inventory stays
 * interruptible and its progress is a number the reader watches fall. */
export async function retireMatchingOperator(
	page: RoomsPageContext,
	category: OperatorCategory,
	query: string,
	limit: number,
	referenceKind: OperatorReferenceKind | null = null,
): Promise<OperatorRetireBatch | string> {
	const held = page.operator.held;
	if (held == null) return "This tab no longer holds the Rooms operator capability.";
	try {
		// No invalidation per batch: a sweep is many calls, and asking every
		// pane to read seven inventories between them is the cost this act
		// exists to avoid. The sweep refreshes once when it settles, and the
		// number it shows meanwhile is the directory's own answer.
		return await operatorRetireMatching(held.session, held.cap, category, query, limit, referenceKind);
	} catch (error) {
		return reason(error);
	}
}

export async function loadMoreOperator(page: RoomsPageContext, category: OperatorCategory): Promise<string> {
	const held = page.operator.held;
	const current = page.projection.get().operator;
	if (held == null || current == null) return "This tab no longer holds the Rooms operator capability.";
	const cursor = current.next[category];
	if (cursor == null) return "";
	try {
		const nextPage = await operatorPage(
			held.session,
			held.cap,
			category,
			cursor,
			current.search,
			current.referenceKind,
		);
		if (page.operator.held !== held) return "";
		const latest = page.projection.get().operator;
		if (latest == null) return "";
		if (nextPage.revision !== latest.revision) {
			if (nextPage.revision > latest.revision) await refreshOperator(page);
			return "";
		}
		if (latest.next[category] !== cursor) return "";
		store.setRoomsOperator(page.projection, appendOperatorPage(latest, nextPage));
		return "";
	} catch (error) {
		return reason(error);
	}
}

export function requestOperatorReset(
	page: RoomsPageContext,
	scope: OperatorResetScope,
): Promise<string> {
	return mutate(page, (session, cap) => resetOperatorScope(session, cap, scope));
}

export function requestStewardGive(page: RoomsPageContext, name: string): Promise<string> {
	return mutate(page, async (session, cap) => {
		await giveStewardship(session, cap, name);
	});
}

export function requestStewardRevoke(page: RoomsPageContext, name: string): Promise<string> {
	return mutate(page, async (session, cap) => {
		await revokeStewardship(session, cap, name);
	});
}
