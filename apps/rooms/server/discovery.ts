// The directory's public room list and its live deltas.

import type { Argument } from "@pancake/runtime";
import type { RoomRecordShape } from "../lib/protocol.ts";
import { localRoomEntry, type PublicRoomEntry, publicRooms, type RoomState } from "./registry.ts";
import { notifyWatchers } from "./watchers.ts";

export type RoomListEvent = "opened" | "closed" | "count";
export type MemberListEvent = "registered" | "unregistered";
/** Encode one public-room generation for both list snapshots and watch deltas. */
export function roomRecord(
	entry: PublicRoomEntry,
	shape: RoomRecordShape,
	count?: number | null,
): Argument[] {
	const current = count === undefined ? entry.kind === "local" ? entry.state.members.length : null : count;
	const baseline: Argument[] = [
		entry.name,
		current === null ? null : BigInt(current),
	];
	if (shape === "baseline") return baseline;
	return [
		...baseline,
		entry.id,
		entry.kind,
		entry.kind === "local" ? "" : entry.origin,
		entry.kind === "local" ? "local" : entry.proof,
	];
}

/** Every discoverable room, with foreign occupancy left explicitly unknown. */
export function roomSnapshot(shape: RoomRecordShape): Argument[] {
	const live: Argument[] = [];
	for (const entry of publicRooms.values()) {
		if (entry.kind === "local" && entry.state.members.length === 0) continue;
		live.push(roomRecord(entry, shape));
	}
	return live;
}

/** Announce one exact local-room generation unless it is private. */
export function notifyLocalRoom(
	state: RoomState,
	event: RoomListEvent,
	count: number,
): void {
	if (state.private) return;
	notifyPublicRoom(localRoomEntry(state), event, count);
}

/** Announce one exact public-room generation. */
export function notifyPublicRoom(
	entry: PublicRoomEntry,
	event: RoomListEvent,
	count?: number | null,
): void {
	notifyWatchers(
		[event, ...roomRecord(entry, "baseline", count)],
		[event, ...roomRecord(entry, "publication", count)],
	);
}

/** Member reachability shares the watcher but is not a room publication. */
export function notifyMember(event: MemberListEvent, name: string, count: 0 | 1): void {
	notifyWatchers([event, name, BigInt(count)]);
}
