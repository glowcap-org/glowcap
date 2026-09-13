// One directory's view row, and the verbs that change it.
//
// Split from `store.ts` by subject: a room list, a set of reachable peers,
// and a connection's health all belong to one directory, and each verb here
// names the directory it acts on. That is the whole of the change from one
// directory to several — reporting these without saying which directory is
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
 * it in the same state transition; retaining only its id would reopen the card
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

/** Name the directory this page came with. Written once, by the one open that
 * had no locator to start with.
 *
 * One field and nothing else. Which locator a reader means by "here" is a
 * question the join card resolves as it draws, so this can be learned late
 * without anything reaching into what the reader is looking at. */
export function setHomeDir(projection: PageProjection, dir: DirId): void {
	if (projection.get().homeDir === dir) return;
	projection.set({ homeDir: dir });
}

/** Record that this directory has answered. One way only: one that has been
 * reached once stays reached for the life of the tab, because what the flag
 * exists to tell apart is "this address may be wrong" from "this directory has
 * gone away", and only the first of those is ever true before the first
 * answer. */
export function markDirReached(projection: PageProjection, dir: DirId): void {
	patchDir(projection, dir, { reached: true });
}

/** Whether this directory has ever answered in this tab. An unknown one reads
 * as not reached, which is the safe answer: it is the arm that gives up. */
export function dirReached(projection: PageProjection, dir: DirId): boolean {
	return projection.get().dirs.get(dir)?.reached ?? false;
}
export function setDirStatus(projection: PageProjection, dir: DirId, statusText: string): void {
	patchDir(projection, dir, { statusText });
}

/** Say whether others can reach this tab for direct messages on `dir`: a reason
 * when they cannot, empty when they can. */
export function setDmUnreachable(projection: PageProjection, dir: DirId, why: string): void {
	if ((projection.get().dirs.get(dir)?.dmUnreachable ?? "") === why) return;
	patchDir(projection, dir, { dmUnreachable: why });
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

/** The publication `name` must be entered through, or null to enter by name.
 *
 * Foreign and bridged rooms answer with their listing entry: the exact
 * publication generation is their identity in this directory, and retaining
 * it keeps presentation and re-entry tied to that room rather than to a
 * reusable human label. A local room is the opposite —
 * it is always reachable by name, and keying its conversation by a listing
 * entry made one room two conversations whenever the listing arrived after
 * the first entry, with the address mirror then re-entering whichever copy
 * the reader had just left. Every entry path asks this one question so that
 * split cannot come back. */
export function enteredPublication(projection: PageProjection, dir: DirId, name: string): RoomInfo | null {
	const live = liveRoom(projection, dir, name);
	return live !== null && live.kind !== "local" ? live : null;
}

/** Where one exact bridged publication's channel lives, or null for every
 * other publication. Publication ids are non-bearer directory identity; the
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
export function resetLiveRooms(projection: PageProjection, dir: DirId, rooms: Iterable<RoomInfo>): void {
	const held = projection.get().dirs.get(dir);
	if (held == null) return;
	const liveRooms = new Map([...rooms].map((room) => [liveRoomKey(room.name), room]));
	patchDir(projection, dir, { liveRooms: sameRows(held.liveRooms, liveRooms) ? held.liveRooms : liveRooms });
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
export function clearDmable(projection: PageProjection, dir: DirId): void {
	const held = projection.get().dirs.get(dir);
	if (held == null || held.dmablePeers.size === 0) return;
	patchDir(projection, dir, { dmablePeers: new Map() });
}

export function peerRegistration(projection: PageProjection, dir: DirId, name: string): DirectoryMember | null {
	return projection.get().dirs.get(dir)?.dmablePeers.get(name.toLowerCase()) ?? null;
}
