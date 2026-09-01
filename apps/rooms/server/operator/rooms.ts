// Operator inventory and removal for room-shaped application owners.
//
// This is not a generic CapTP table. Each row is an application owner with a
// cleanup transaction: a local room releases membership capabilities, a
// peered publication releases its retained room reference, and an IRC bridge
// parts through the gateway that owns its sockets and seats.

import type { Session } from "@pancake/runtime";
import { MAX_OPERATOR_MEMBERS_PER_ROOM } from "../../lib/limits.ts";
import { notifyLocalRoom, notifyPublicRoom } from "../discovery.ts";
import { operatorBridgeMembers, operatorPartBridge } from "../irc_gateway.ts";
import { leaveRoom } from "../presence.ts";
import type { RoomServerContext } from "../context.ts";
import type { RoomState } from "../registry.ts";
import { type OperatorRowPage, type OperatorRowSource, queryPage, searchText } from "./page.ts";

export type OperatorRoomKind = "local" | "private" | "peered" | "pending-peered" | "irc";

export interface OperatorRoomMember {
	readonly nick: string;
	readonly session: Session;
	readonly state: string;
}

export interface OperatorRoomRow {
	readonly id: string;
	readonly kind: OperatorRoomKind;
	readonly name: string;
	readonly origin: string;
	readonly proof: "local" | "authenticated" | "session" | "bridge";
	/** Exact room-owned capability occurrences when that owner exposes a count.
	 * Null means the owner can remove them as one transaction but does not expose
	 * an occurrence count. */
	readonly retainedCapabilities: number | null;
	readonly members: readonly OperatorRoomMember[];
	readonly membersMore: boolean;
}

function localRetained(state: RoomState): number {
	let retained = 0;
	for (const member of state.members) {
		retained += 1 + Number(member.seat !== null) + Number(member.topic !== null) + member.lines.length;
	}
	for (const uploads of state.uploads.values()) {
		for (const upload of uploads) if (upload.ref !== null) retained += 1;
	}
	return retained;
}

/** Every room-shaped owner, as rows a search can scan without building them.
 * The text is the row's identity — its id, what kind of owner it is, its name
 * and where it came from — so a hundred thousand rooms cost a hundred thousand
 * string tests rather than a hundred thousand member lists. */
export function* operatorRoomFaces(ctx: RoomServerContext): Iterable<OperatorRowSource<OperatorRoomRow>> {
	for (const state of ctx.live.rooms.values()) {
		const kind: OperatorRoomKind = state.policy.visibility === "secret" ? "private" : "local";
		yield {
			text: searchText(state.entryId, kind, state.name),
			build: () => ({
				id: state.entryId,
				kind,
				name: state.name,
				origin: "",
				proof: "local",
				retainedCapabilities: localRetained(state),
				members: state.members.slice(0, MAX_OPERATOR_MEMBERS_PER_ROOM).map((member) => ({
					nick: member.nick,
					session: member.session,
					state: member.away,
				})),
				membersMore: state.members.length > MAX_OPERATOR_MEMBERS_PER_ROOM,
			}),
		};
	}
	for (const entry of ctx.live.publicRooms.values()) {
		if (entry.kind === "local") continue;
		if (entry.kind === "foreign") {
			yield {
				text: searchText(entry.id, "peered", entry.name, entry.origin),
				build: () => ({
					id: entry.id,
					kind: "peered",
					name: entry.name,
					origin: entry.origin,
					proof: entry.proof,
					retainedCapabilities: 1,
					members: [],
					membersMore: false,
				}),
			};
			continue;
		}
		yield {
			text: searchText(entry.id, "irc", entry.name, entry.origin),
			build: () => {
				const members = operatorBridgeMembers(ctx, entry.id);
				return {
					id: entry.id,
					kind: "irc" as const,
					name: entry.name,
					origin: entry.origin,
					proof: "bridge" as const,
					retainedCapabilities: null,
					members: members.slice(0, MAX_OPERATOR_MEMBERS_PER_ROOM),
					membersMore: members.length > MAX_OPERATOR_MEMBERS_PER_ROOM,
				};
			},
		};
	}
	for (const pending of ctx.peering.rows()) {
		yield {
			text: searchText(pending.id, "pending-peered", pending.name, pending.origin),
			build: () => ({
				id: pending.id,
				kind: "pending-peered" as const,
				name: pending.name,
				origin: pending.origin,
				proof: pending.proof,
				retainedCapabilities: 1,
				members: [],
				membersMore: false,
			}),
		};
	}
}

function operatorRoomPage(
	ctx: RoomServerContext,
	offset: number,
	limit: number,
	query = "",
): OperatorRowPage<OperatorRoomRow> {
	return queryPage(operatorRoomFaces(ctx), query, offset, limit);
}

function localById(ctx: RoomServerContext, id: string): RoomState | null {
	for (const state of ctx.live.rooms.values()) if (state.entryId === id) return state;
	return null;
}

function closeLocal(ctx: RoomServerContext, state: RoomState): void {
	const sessions = new Set(state.members.map((member) => member.session));
	for (const session of sessions) leaveRoom(ctx, state, session, { ended: "An operator removed this room." });
	if (ctx.live.rooms.get(state.key) !== state) return;
	// An opened room may not have subscribed yet. It owns no membership to drive
	// the ordinary last-member cleanup, so close that empty generation here.
	ctx.files.dropRoomFiles(state);
	ctx.live.forgetRoom(state);
	notifyLocalRoom(ctx, state, "closed", 0);
}

/** Remove one exact room owner and every capability occurrence it owns. */
export async function removeOperatorRoom(ctx: RoomServerContext, id: string): Promise<boolean> {
	if (ctx.peering.remove(id)) return true;
	const local = localById(ctx, id);
	if (local !== null) {
		closeLocal(ctx, local);
		return true;
	}
	const published = ctx.live.publicRoomById(id);
	if (published?.kind === "foreign") {
		const removed = ctx.live.forgetForeignRoom(id);
		if (removed !== null) notifyPublicRoom(ctx, removed, "closed", null);
		return removed !== null;
	}
	if (published?.kind === "bridge") return await operatorPartBridge(ctx, id);
	return false;
}

/** Remove the snapshot present at admission. Exact ids prevent a replacement
 * generation from being swept by an older reset walk. */
export async function resetOperatorRooms(ctx: RoomServerContext): Promise<number> {
	let removed = 0;
	while (true) {
		const row = operatorRoomPage(ctx, 0, 1).rows[0];
		if (row == null || !await removeOperatorRoom(ctx, row.id)) return removed;
		removed += 1;
	}
}
