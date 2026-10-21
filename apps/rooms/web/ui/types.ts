// Presentation types that belong to directories and page chrome.

import type { DirectoryMember, RoomInfo } from "../../lib/directory_publications.ts";
import type { RoomPolicy } from "./room_policy.ts";

export * from "./conversation.ts";

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

export interface RoomDestination {
	room: string;
	locator: string;
	hidden?: boolean;
	policy?: RoomPolicy;
}

export type ToastKind = "success" | "failure" | "warning";

export interface ToastNotice {
	id: number;
	kind: ToastKind;
	text: string;
}

export interface DirView {
	id: DirId;
	locator: string;
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
	dmUnreachable: string;
	standing: string | null;
}

/** Which person a member card is about.
 *
 * `conv` is the room whose roster the reading came from. It is null when the
 * reader opened their own card from the rail's foot, which is about them on the
 * page rather than in any one room, and the card says so rather than naming a
 * room that was never asked about. */
export interface MemberRef {
	readonly conv: string | null;
	readonly name: string;
}

export type SessionPhase = "connecting" | "connected" | "disconnected" | "reconnecting";

/** Actions the message log may offer for sends this controller owns. */
export interface SendControlPolicy {
	retry: boolean;
}

export const LOCAL_SEND_CONTROLS = { retry: true } as const;
export const SHARED_SEND_CONTROLS = { retry: false } as const;

export function sendControlsFor(kind: "local" | "attached" | "hosted"): SendControlPolicy {
	return kind === "local" ? LOCAL_SEND_CONTROLS : SHARED_SEND_CONTROLS;
}

export interface TroubleRow {
	readonly source: string;
	readonly reason: string;
	readonly count: number;
}

export * from "./ops/types.ts";
export type { RoomsSettingsTab as SettingsTab } from "../../lib/view_state.ts";
