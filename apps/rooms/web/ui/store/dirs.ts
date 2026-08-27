// One directory's view row, and the verbs that change it.
//
// Split from `store.ts` by subject: a room list, a set of reachable peers,
// and a connection's health all belong to one directory, and each verb here
// names the directory it acts on. That is the whole of the change from one
// directory to several — reporting these without saying which directory is
// what made holding two of them unspellable.

import type { DirId, DirView, SessionPhase } from "../types.ts";
import type { DirectoryMember, RoomInfo } from "../../../lib/directory_publications.ts";
import { MAX_DIRECTORY_DISCOVERY_ROWS } from "../../../lib/limits.ts";
import { get, set } from "./core.ts";

/** Replace one directory's view, leaving every other directory alone. */
export function patchDir(dir: DirId, fields: Partial<DirView>): void {
	const current = get().dirs;
	const held = current.get(dir);
	if (held === undefined) return;
	const dirs = new Map(current);
	dirs.set(dir, { ...held, ...fields });
	set({ dirs });
}

/** Start holding `dir`, or leave it as it stands if this tab already does.
 *
 * Idempotent because asking for a directory twice must never be a way to lose
 * what is already on it: the rooms are conversations, but the room list and the
 * reachable peers live here. */
export function openDir(dir: DirId, locator = dir as string): void {
	const current = get().dirs;
	if (current.has(dir)) {
		if (current.get(dir)?.locator !== locator) patchDir(dir, { locator });
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
	set({ dirs });
}

/** Stop holding `dir`. Its conversations are forgotten by their own verb: this
 * is the directory's own state and nothing else. */
export function forgetDir(dir: DirId): void {
	const current = get().dirs;
	if (!current.has(dir)) return;
	const dirs = new Map(current);
	dirs.delete(dir);
	set({ dirs });
}

export function setDirSession(dir: DirId, session: SessionPhase): void {
	patchDir(dir, { session });
}

/** Name the directory this page came with. Written once, by the one open that
 * had no locator to start with.
 *
 * One field and nothing else. Which locator a reader means by "here" is a
 * question the join card resolves as it draws, so this can be learned late
 * without anything reaching into what the reader is looking at. */
export function setHomeDir(dir: DirId): void {
	if (get().homeDir === dir) return;
	set({ homeDir: dir });
}

/** Record that this directory has answered. One way only: one that has been
 * reached once stays reached for the life of the tab, because what the flag
 * exists to tell apart is "this address may be wrong" from "this directory has
 * gone away", and only the first of those is ever true before the first
 * answer. */
export function markDirReached(dir: DirId): void {
	patchDir(dir, { reached: true });
}

/** Whether this directory has ever answered in this tab. An unknown one reads
 * as not reached, which is the safe answer: it is the arm that gives up. */
export function dirReached(dir: DirId): boolean {
	return get().dirs.get(dir)?.reached ?? false;
}
export function setDirStatus(dir: DirId, statusText: string): void {
	patchDir(dir, { statusText });
}

/** Say whether others can reach this tab for direct messages on `dir`: a reason
 * when they cannot, empty when they can. */
export function setDmUnreachable(dir: DirId, why: string): void {
	if ((get().dirs.get(dir)?.dmUnreachable ?? "") === why) return;
	patchDir(dir, { dmUnreachable: why });
}

/** Whether `name` is the name this directory granted this tab.
 *
 * A direct line, an invitation, and an inbox offer are acts toward somebody
 * else. This is the one answer those paths share, so a forgotten check cannot
 * mint a conversation with yourself. Empty until a name is granted, because
 * there is then no "you" to compare to. */
export function isSelf(dir: DirId, name: string): boolean {
	const nick = get().dirs.get(dir)?.nick ?? "";
	return nick !== "" && name.toLowerCase() === nick.toLowerCase();
}
function liveRoomKey(name: string): string {
	return name.toLowerCase();
}

export function liveRoom(dir: DirId, name: string): RoomInfo | null {
	return get().dirs.get(dir)?.liveRooms.get(liveRoomKey(name)) ?? null;
}

/** The publication `name` must be entered through, or null to enter by name.
 *
 * Only a foreign room answers with its listing entry: entering its name with
 * an ordinary open would mint a fresh local room wearing it, so the exact
 * publication generation is the one way in. A local room is the opposite —
 * it is always reachable by name, and keying its conversation by a listing
 * entry made one room two conversations whenever the listing arrived after
 * the first entry, with the address mirror then re-entering whichever copy
 * the reader had just left. Every entry path asks this one question so that
 * split cannot come back. */
export function enteredPublication(dir: DirId, name: string): RoomInfo | null {
	const live = liveRoom(dir, name);
	return live !== null && live.kind === "foreign" ? live : null;
}

/** Where a bridged room's channel lives, or null for every other room. Read
 * from the directory view a component already holds, so presentation does not
 * reach past its props; the key fold stays this module's. */
export function bridgedOrigin(
	view: { liveRooms: ReadonlyMap<string, RoomInfo> } | undefined,
	name: string,
): string | null {
	const live = view?.liveRooms.get(liveRoomKey(name));
	return live !== undefined && live.kind === "bridge" ? live.origin : null;
}

export function setLiveRoom(dir: DirId, room: RoomInfo): void {
	const held = get().dirs.get(dir);
	if (held === undefined) return;
	const liveRooms = new Map(held.liveRooms);
	liveRooms.set(liveRoomKey(room.name), room);
	patchDir(dir, { liveRooms });
}
export function dropLiveRoom(dir: DirId, room: RoomInfo): void {
	const held = get().dirs.get(dir);
	if (held === undefined) return;
	const liveRooms = new Map(held.liveRooms);
	const key = liveRoomKey(room.name);
	if (liveRooms.get(key)?.id !== room.id) return;
	liveRooms.delete(key);
	patchDir(dir, { liveRooms });
}
export function resetLiveRooms(dir: DirId, rooms: Iterable<RoomInfo>): void {
	patchDir(dir, { liveRooms: new Map([...rooms].map((room) => [liveRoomKey(room.name), room])) });
}
export function setDmable(dir: DirId, name: string, registrationId: string, reachable: boolean): boolean {
	const held = get().dirs.get(dir);
	if (held == null) return true;
	const key = name.toLowerCase();
	const current = held.dmablePeers.get(key);
	if (reachable && current?.name === name && current.registrationId === registrationId) return true;
	if (!reachable && current?.registrationId !== registrationId) return true;
	if (reachable && current == null && held.dmablePeers.size >= MAX_DIRECTORY_DISCOVERY_ROWS) return false;
	const dmablePeers = new Map(held.dmablePeers);
	if (reachable) dmablePeers.set(key, { name, registrationId });
	else dmablePeers.delete(key);
	patchDir(dir, { dmablePeers });
	return true;
}
export function resetDirectoryDiscovery(
	dir: DirId,
	rooms: Iterable<RoomInfo>,
	peers: Iterable<DirectoryMember>,
): void {
	patchDir(dir, {
		liveRooms: new Map([...rooms].map((room) => [liveRoomKey(room.name), room])),
		dmablePeers: new Map([...peers].map((peer) => [peer.name.toLowerCase(), peer])),
	});
}
export function clearDmable(dir: DirId): void {
	patchDir(dir, { dmablePeers: new Map() });
}

export function peerRegistration(dir: DirId, name: string): DirectoryMember | null {
	return get().dirs.get(dir)?.dmablePeers.get(name.toLowerCase()) ?? null;
}
