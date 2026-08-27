// Presentation types that belong to directories and page chrome.

import type { DirectoryMember, RoomInfo } from "../../lib/directory_publications.ts";

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
	/** The nickname this live directory connection actually granted. */
	nick: string;
	slot: number;
	reached: boolean;
	session: SessionPhase;
	statusText: string;
	dmUnreachable: string;
	standing: string | null;
}

export type SessionPhase = "connecting" | "connected" | "disconnected" | "reconnecting";

/** Actions the message log may offer for sends this controller owns. */
export interface SendControlPolicy {
	retry: boolean;
	stop: boolean;
}

export const LOCAL_SEND_CONTROLS = { retry: true, stop: true } as const;
export const SHARED_SEND_CONTROLS = { retry: false, stop: false } as const;

export function sendControlsFor(kind: "local" | "attached"): SendControlPolicy {
	return kind === "local" ? LOCAL_SEND_CONTROLS : SHARED_SEND_CONTROLS;
}

export interface TroubleRow {
	readonly source: string;
	readonly reason: string;
	readonly count: number;
}

export * from "./ops/types.ts";
export type { RoomsSettingsTab as SettingsTab } from "../../lib/rooms_state.ts";
