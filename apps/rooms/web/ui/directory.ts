// A directory the page is connected to: its identity, its live view, and the
// marks that tell several of them apart.

import type { DirectoryMember, RoomInfo } from "../../lib/directory_publications.ts";

export type DirId = string & { readonly __dir: unique symbol };

export type LiveRooms = ReadonlyMap<string, RoomInfo>;

export function liveRoomNames(rooms: LiveRooms): string[] {
	return [...rooms.values()].map((room) => room.name);
}

export function liveRoomCounts(rooms: LiveRooms): ReadonlyMap<string, number | null> {
	return new Map([...rooms.values()].map((room) => [room.name, room.count]));
}

export function dirId(locator: string): DirId {
	return locator as DirId;
}

const DIR_MARKS = 5;

export function dirsAreNamed(dirs: ReadonlyMap<DirId, DirView>): boolean {
	return dirs.size > 1;
}

export function dirsWearMarks(dirs: ReadonlyMap<DirId, DirView>): boolean {
	return dirsAreNamed(dirs) && dirs.size <= DIR_MARKS;
}

export function dirMark(
	dir: DirId,
	home: DirId | null,
	slot: number | null | undefined,
): "home" | string | undefined {
	if (home !== null && dir === home) return "home";
	return slot != null ? String(slot) : undefined;
}

export function dirMarkIn(
	dir: DirId,
	home: DirId | null,
	dirs: ReadonlyMap<DirId, DirView>,
): string | undefined {
	return dirsWearMarks(dirs) ? dirMark(dir, home, dirs.get(dir)?.slot) : undefined;
}

export interface DirView {
	id: DirId;
	/** Where this tab reaches the directory: the address the session dialed,
	 * `host:port` for TCP, else the locator. Empty until one is known. */
	address: string;
	liveRooms: LiveRooms;
	dmablePeers: ReadonlyMap<string, DirectoryMember>;
	/** The exact nickname this workspace will ask for on reconstruction. */
	requestedNick: string;
	/** The nickname this live directory connection granted. */
	nick: string;
	slot: number;
	/** Once true, this tab has had an answer from this directory. First Connect
	 * and a standing drop are different words because of this, not because a row
	 * exists. */
	reached: boolean;
	session: SessionPhase;
	statusText: string;
	/** The transport the live connection runs over, as the registered notice
	 * named it, and empty before one has. */
	transport: string;
	dmUnreachable: string;
	standing: string | null;
}

export type SessionPhase = "connecting" | "connected" | "disconnected" | "reconnecting";
