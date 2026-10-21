// One directory's view row, and the verbs that change it.
//
// Split from `store.ts` by subject: a room list, a set of reachable peers,
// and a connection's health all belong to one directory, and each verb here
// names the directory it acts on. That is the whole of the change from one
// directory to several, reporting these without saying which directory is
// what made holding two of them unspellable.

import type { DirId, DirView, SessionPhase } from "../types.ts";
import type { DirectoryMember, RoomInfo } from "../../../lib/directory_publications.ts";
import { MAX_DIRECTORY_DISCOVERY_ROWS } from "../limits.ts";
import type { PageProjection } from "./core.ts";

/** Replace one directory's view, leaving every other directory alone. A patch
 * that changes no field writes nothing, so a snapshot that restates what the
 * store holds does not hand every subscriber a fresh map. */
export function patchDir(projection: PageProjection, dir: DirId, fields: Partial<DirView>): void {
	const current = projection.get().dirs;
	const held = current.get(dir);
	if (held === undefined) return;
	if ((Object.keys(fields) as (keyof DirView)[]).every((field) => held[field] === fields[field])) return;
	const dirs = new Map(current);
	dirs.set(dir, { ...held, ...fields });
	projection.set({ dirs });
}

/** Start holding `dir`, or leave it as it stands if this tab already does.
 *
 * Idempotent because asking for a directory twice must never be a way to lose
 * what is already on it: the rooms are conversations, but the room list and the
 * reachable peers live here. */
export function openDir(projection: PageProjection, dir: DirId, locator: string): void {
	const current = projection.get().dirs;
	if (current.has(dir)) {
		if (current.get(dir)?.locator !== locator) patchDir(projection, dir, { locator });
		return;
	}
	// The lowest mark nobody is wearing, so two directories can never share one
	// and one that leaves gives its mark back.
	const taken = new Set([...current.values()].map((held) => held.slot));
	let slot = 1;
	while (taken.has(slot)) slot += 1;
	const dirs = new Map(current);
	dirs.set(dir, {
		id: dir,
		locator,
		slot,
		requestedNick: "",
		nick: "",
		reached: false,
		liveRooms: new Map(),
		dmablePeers: new Map(),
		session: "connecting",
		// Empty is settled: the foot derives its resting words, and the net
		// layer writes a sentence here only while an act or failure needs one.
		statusText: "",
		dmUnreachable: "",
		standing: null,
	});
	projection.set({ dirs });
}

/** Stop holding `dir`. Its conversations are forgotten by their own verb. A
 * card about this directory is a view of the same authority, so removal closes
 * it in the same state transition. Retaining only its id would reopen the card
 * if that authority were later acquired again. */
export function forgetDir(projection: PageProjection, dir: DirId): void {
	const state = projection.get();
	const current = state.dirs;
	if (!current.has(dir)) return;
	const dirs = new Map(current);
	dirs.delete(dir);
	projection.set(state.aboutDir === dir ? { dirs, aboutDir: null, aboutDirLeave: false } : { dirs });
}

export function setDirSession(projection: PageProjection, dir: DirId, session: SessionPhase): void {
	patchDir(projection, dir, { session });
}

/** Whether `name` is the name this directory granted this tab.
 *
 * A direct line, an invitation, and an inbox offer are acts toward somebody
 * else. This is the one answer those paths share, so a forgotten check cannot
 * mint a conversation with yourself. Empty until a name is granted, because
 * there is then no "you" to compare to. */
export function isSelf(projection: PageProjection, dir: DirId, name: string): boolean {
	const nick = projection.get().dirs.get(dir)?.nick ?? "";
	return nick !== "" && name.toLowerCase() === nick.toLowerCase();
}

function liveRoomKey(name: string): string {
	return name.toLowerCase();
}

export function liveRoom(projection: PageProjection, dir: DirId, name: string): RoomInfo | null {
	return projection.get().dirs.get(dir)?.liveRooms.get(liveRoomKey(name)) ?? null;
}

/** Where one exact bridged publication's channel lives, or null for every
 * other publication. Publication ids are non-bearer directory identity. The
 * gateway capability remains the authority to administer the bridge. */
export function bridgedOrigin(
	view: { liveRooms: ReadonlyMap<string, RoomInfo> } | undefined,
	publicationId: string | undefined,
): string | null {
	const publication = roomPublication(view, publicationId);
	return publication?.kind === "bridge" ? publication.origin : null;
}

export function roomPublication(
	view: { liveRooms: ReadonlyMap<string, RoomInfo> } | undefined,
	publicationId: string | undefined,
): RoomInfo | null {
	if (publicationId === undefined) return null;
	for (const live of view?.liveRooms.values() ?? []) if (live.id === publicationId) return live;
	return null;
}

export function setLiveRoom(projection: PageProjection, dir: DirId, room: RoomInfo): void {
	const held = projection.get().dirs.get(dir);
	if (held === undefined) return;
	const liveRooms = new Map(held.liveRooms);
	liveRooms.set(liveRoomKey(room.name), room);
	patchDir(projection, dir, { liveRooms });
}

export function dropLiveRoom(projection: PageProjection, dir: DirId, room: RoomInfo): void {
	const held = projection.get().dirs.get(dir);
	if (held === undefined) return;
	const liveRooms = new Map(held.liveRooms);
	const key = liveRoomKey(room.name);
	if (liveRooms.get(key)?.id !== room.id) return;
	liveRooms.delete(key);
	patchDir(projection, dir, { liveRooms });
}
/** Whether two discovery maps say the same thing row for row, so a snapshot
 * that restates the listing does not hand out a fresh map. Rows are small
 * records compared field by field. */
function sameRows<V extends object>(held: ReadonlyMap<string, V>, next: ReadonlyMap<string, V>): boolean {
	if (held.size !== next.size) return false;
	for (const [key, row] of next) {
		const have = held.get(key);
		if (have === undefined) return false;
		if (have !== row && !(Object.keys(row) as (keyof V)[]).every((field) => have[field] === row[field])) {
			return false;
		}
	}
	return true;
}

export function setDmable(
	projection: PageProjection,
	dir: DirId,
	name: string,
	registrationId: string,
	reachable: boolean,
): boolean {
	const held = projection.get().dirs.get(dir);
	if (held == null) return true;
	const key = name.toLowerCase();
	const current = held.dmablePeers.get(key);
	if (reachable && current?.name === name && current.registrationId === registrationId) return true;
	if (!reachable && current?.registrationId !== registrationId) return true;
	if (reachable && current == null && held.dmablePeers.size >= MAX_DIRECTORY_DISCOVERY_ROWS) return false;
	const dmablePeers = new Map(held.dmablePeers);
	if (reachable) dmablePeers.set(key, { name, registrationId });
	else dmablePeers.delete(key);
	patchDir(projection, dir, { dmablePeers });
	return true;
}

export function resetDirectoryDiscovery(
	projection: PageProjection,
	dir: DirId,
	rooms: Iterable<RoomInfo>,
	peers: Iterable<DirectoryMember>,
): void {
	const held = projection.get().dirs.get(dir);
	if (held == null) return;
	const liveRooms = new Map([...rooms].map((room) => [liveRoomKey(room.name), room]));
	const dmablePeers = new Map([...peers].map((peer) => [peer.name.toLowerCase(), peer]));
	patchDir(projection, dir, {
		liveRooms: sameRows(held.liveRooms, liveRooms) ? held.liveRooms : liveRooms,
		dmablePeers: sameRows(held.dmablePeers, dmablePeers) ? held.dmablePeers : dmablePeers,
	});
}
