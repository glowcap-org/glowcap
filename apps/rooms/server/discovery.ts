// The directory's public room list and its live deltas.

import type { Argument } from "@pancake/runtime";
import type { RoomRecordShape } from "../lib/protocol.ts";
import { MAX_DIRECTORY_DISCOVERY_ROWS } from "../lib/limits.ts";
import { roomIsListed } from "../lib/room/policy.ts";
import { publicMembershipKind, roomPublicMayEnter } from "../lib/room/policy.ts";
import type { RoomServerContext } from "./context.ts";
import { localRoomEntry, type PublicRoomEntry, type RoomState } from "./registry.ts";
import { notifyWatchers } from "./watchers.ts";

export type RoomListEvent = "opened" | "closed" | "count";
export type MemberListEvent = "registered" | "unregistered";
/** Encode one public-room generation for both list snapshots and watch deltas. */
function roomRecord(
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
		entry.kind === "local"
			? roomPublicMayEnter(entry.state.policy) ? publicMembershipKind(entry.state.policy) : null
			: "participant",
	];
}

/** Every discoverable room, with foreign occupancy left explicitly unknown. */
export function roomSnapshot(
	ctx: RoomServerContext,
	shape: RoomRecordShape,
): { rows: Argument[]; omitted: number } {
	const rows: Argument[] = [];
	let omitted = 0;
	for (const entry of ctx.live.publicRooms.values()) {
		if (entry.kind === "local" && entry.state.members.length === 0) continue;
		if (rows.length === MAX_DIRECTORY_DISCOVERY_ROWS) omitted += 1;
		else rows.push(roomRecord(entry, shape));
	}
	return { rows, omitted };
}

/** One atomic watch baseline. Rooms and live registrations share the
 * discovery ceiling; `omitted` tells a client to treat the view as truncated
 * instead of mistaking a dropped notification for a complete peer set. */
export function directoryWatchSnapshot(ctx: RoomServerContext, shape: RoomRecordShape): Argument[] {
	const rooms = roomSnapshot(ctx, shape);
	const remaining = Math.max(0, MAX_DIRECTORY_DISCOVERY_ROWS - rooms.rows.length);
	const peers: Argument[] = [];
	for (const intro of ctx.live.introductions.values()) {
		if (peers.length === remaining) break;
		peers.push([intro.nick, intro.registrationId]);
	}
	const omitted = rooms.omitted + Math.max(0, ctx.live.introductions.size - peers.length);
	return [rooms.rows, peers, BigInt(omitted)];
}

/** Announce one exact local-room generation while it is listed. */
export function notifyLocalRoom(
	ctx: RoomServerContext,
	state: RoomState,
	event: RoomListEvent,
	count: number,
): void {
	if (!roomIsListed(state.policy)) return;
	notifyPublicRoom(ctx, localRoomEntry(state), event, count);
}

/** Announce one exact public-room generation. */
export function notifyPublicRoom(
	ctx: RoomServerContext,
	entry: PublicRoomEntry,
	event: RoomListEvent,
	count?: number | null,
): void {
	notifyWatchers(
		ctx.watchers,
		[event, ...roomRecord(entry, "baseline", count)],
		[event, ...roomRecord(entry, "publication", count)],
	);
}

/** Member reachability shares the watcher but is not a room publication. */
export function notifyMember(
	ctx: RoomServerContext,
	event: MemberListEvent,
	name: string,
	registrationId: string,
	count: 0 | 1,
): void {
	notifyWatchers(ctx.watchers, [event, name, BigInt(count), registrationId]);
}
