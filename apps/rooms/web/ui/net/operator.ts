// The Rooms application operator capability as this browser tab holds it.

import type { Ref, Session } from "@pancake/runtime";
import {
	clearOperatorTrouble,
	disconnectSession,
	giveStewardship,
	type OperatorCategory,
	operatorPage,
	type OperatorResetScope,
	type OperatorRetireBatch,
	operatorRetireMatching,
	releaseOperatorReference,
	removeOperatorRoom,
	resetOperatorScope,
	revokeNick,
	revokeRoomLink,
	revokeStewardship,
	snapshotOperator,
	type StewardshipRow,
	subscribeOperator,
	takeRoomsOperator,
} from "../../../lib/room_client.ts";
import * as store from "../store.ts";
import type { RoomsOperatorState } from "../types.ts";
import { opsLost, reason } from "./common.ts";
import { dirs } from "./live.ts";
import { forgetOpsSwiss, rememberOpsSwiss } from "./ops_memory.ts";
import { invalidateOperations } from "../ops/invalidation.ts";
import { settleCapabilityCleanup } from "../../../lib/capability_cleanup.ts";
import { type HeldDirectoryCapability, releaseHeldCapability } from "./held_capability.ts";

interface HeldOperator extends HeldDirectoryCapability {
	stopWatch: (() => void) | null;
}

let operatorHeld: HeldOperator | null = null;

function retireOperator(held: HeldOperator | null): void {
	if (held == null) return;
	settleCapabilityCleanup("operator watcher cleanup failed", () => held.stopWatch?.());
	releaseHeldCapability(held, "operator capability release failed");
	if (operatorHeld !== held) return;
	operatorHeld = null;
	store.setRoomsOperator(null);
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
): RoomsOperatorState {
	return {
		revision: snapshot.revision,
		totals: snapshot.totals,
		search,
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

export function dropOperatorHold(): void {
	retireOperator(operatorHeld);
}

export function dropOperatorCap(updateVault = true): void {
	const held = operatorHeld;
	if (held == null) return;
	if (updateVault && !forgetOpsSwiss("operator", held.dir)) {
		store.noteTrouble("capability storage", "the saved Rooms operator capability could not be removed");
		return;
	}
	retireOperator(held);
}

export async function takeOperatorCap(pasted: string, remember = false): Promise<string> {
	const home = store.get().homeDir;
	const live = home === null ? null : dirs.get(home) ?? null;
	if (home === null || live === null) return "This directory is not connected yet.";
	try {
		const taken = await takeRoomsOperator(live.dir.session, pasted);
		const held: HeldOperator = { session: live.dir.session, cap: taken.cap, dir: home, stopWatch: null };
		try {
			held.stopWatch = await subscribeOperator(
				held.session,
				held.cap,
				() => {
					if (operatorHeld === held) void invalidateOperations(home);
				},
			);
		} catch (error) {
			settleCapabilityCleanup(
				"unwatched operator capability release failed",
				() => held.session.release(held.cap),
			);
			return reason(error);
		}
		const stored = remember ? rememberOpsSwiss("operator", home, pasted) : forgetOpsSwiss("operator", home);
		if (!stored) {
			retireOperator(held);
			return "This browser refused to update the saved Rooms operator capability.";
		}
		const previous = operatorHeld;
		operatorHeld = held;
		retireOperator(previous);
		store.setRoomsOperator(operatorStateOf(taken.snapshot));
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** One inventory read at a time. Every change a directory makes tells this
 * holder to read again, and a bulk act makes a great many in a row; without
 * this a sweep would have the browser asking for seven inventories while the
 * last seven were still on the wire. A notice that arrives during a read is
 * remembered and answered once, so the last word is always read. */
let reading: Promise<void> | null = null;
let readAgain = false;
/** A search asked for while a read was in flight. Without it the read that
 * follows would fall back to the search the store already answers, which is
 * the one the reader has just typed past. */
let wantedSearch: string | undefined;

export function refreshOperator(search?: string): Promise<void> {
	if (search != null) wantedSearch = search;
	if (reading !== null) {
		readAgain = true;
		return reading;
	}
	const asked = wantedSearch;
	wantedSearch = undefined;
	const run = readOperator(asked).finally(() => {
		reading = null;
		if (readAgain) {
			readAgain = false;
			void refreshOperator();
		}
	});
	reading = run;
	return run;
}

async function readOperator(search?: string): Promise<void> {
	const held = operatorHeld;
	if (held === null) return;
	const asked = search ?? store.get().operator?.search ?? "";
	try {
		const rows = await snapshotOperator(held.session, held.cap, asked);
		if (operatorHeld !== held) return;
		const current = store.get().operator;
		// A search answer is the newest word about what matches, even when the
		// inventory has not moved, so only an *older* inventory is dropped.
		if (current != null && rows.revision < current.revision && asked === current.search) return;
		store.setRoomsOperator(operatorStateOf(rows, asked));
	} catch (error) {
		if (operatorHeld !== held) return;
		dropOperatorHold();
		opsLost("operator", reason(error));
	}
}

async function mutate(run: (session: Session, cap: Ref) => Promise<void>): Promise<string> {
	const held = operatorHeld;
	if (held == null) return "This tab no longer holds the Rooms operator capability.";
	try {
		await run(held.session, held.cap);
		if (operatorHeld === held) await invalidateOperations(held.dir);
		return "";
	} catch (error) {
		return reason(error);
	}
}

export function requestRoomLinkRevoke(name: string): Promise<string> {
	return mutate((session, cap) => revokeRoomLink(session, cap, name));
}

export function requestNickRevoke(nick: string, sessionId: string): Promise<string> {
	return mutate((session, cap) => revokeNick(session, cap, nick, sessionId));
}

export function requestSessionDisconnect(id: string): Promise<string> {
	return mutate((session, cap) => disconnectSession(session, cap, id));
}

export function requestOperatorRoomRemove(id: string): Promise<string> {
	return mutate((session, cap) => removeOperatorRoom(session, cap, id));
}

export function requestOperatorReferenceRelease(id: string): Promise<string> {
	return mutate((session, cap) => releaseOperatorReference(session, cap, id));
}

export function requestOperatorTroubleClear(): Promise<string> {
	return mutate((session, cap) => clearOperatorTrouble(session, cap));
}

/** Retire one bounded batch of the rows matching a search. The caller runs
 * again while rows remain, so a sweep over a very large inventory stays
 * interruptible and its progress is a number the reader watches fall. */
export async function retireMatchingOperator(
	category: OperatorCategory,
	query: string,
	limit: number,
): Promise<OperatorRetireBatch | string> {
	const held = operatorHeld;
	if (held == null) return "This tab no longer holds the Rooms operator capability.";
	try {
		// No invalidation per batch: a sweep is many calls, and asking every
		// pane to read seven inventories between them is the cost this act
		// exists to avoid. The sweep refreshes once when it settles, and the
		// number it shows meanwhile is the directory's own answer.
		return await operatorRetireMatching(held.session, held.cap, category, query, limit);
	} catch (error) {
		return reason(error);
	}
}

export async function loadMoreOperator(category: OperatorCategory): Promise<string> {
	const held = operatorHeld;
	const current = store.get().operator;
	if (held == null || current == null) return "This tab no longer holds the Rooms operator capability.";
	const cursor = current.next[category];
	if (cursor == null) return "";
	try {
		const page = await operatorPage(held.session, held.cap, category, cursor, current.search);
		if (operatorHeld !== held) return "";
		const latest = store.get().operator;
		if (latest == null) return "";
		if (page.revision !== latest.revision) {
			if (page.revision > latest.revision) await refreshOperator();
			return "";
		}
		if (latest.next[category] !== cursor) return "";
		store.setRoomsOperator(appendOperatorPage(latest, page));
		return "";
	} catch (error) {
		return reason(error);
	}
}

export function requestOperatorReset(
	scope: OperatorResetScope,
): Promise<string> {
	return mutate((session, cap) => resetOperatorScope(session, cap, scope));
}

export function requestStewardGive(name: string): Promise<string> {
	return mutate(async (session, cap) => {
		await giveStewardship(session, cap, name);
	});
}

export function requestStewardRevoke(name: string): Promise<string> {
	return mutate(async (session, cap) => {
		await revokeStewardship(session, cap, name);
	});
}
