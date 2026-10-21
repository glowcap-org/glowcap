// What this tab remembers about one room it is in.
//
// The module next door owns which conversations exist and how to find one.
// This owns what is true of a room once found: what its reader told the bridge
// behind it, what the room's policy and membership are, and which of its
// authorities this tab holds. Each is a small replace-if-changed write, because
// the projection rewrites a conversation object only when something actually
// moved and a needless rewrite re-renders a roster.

import type { RoomConv } from "../types.ts";
import type { PageProjection, State } from "./core.ts";
import { getConv, put } from "./convs.ts";
import { retireRoomLineIds } from "./items.ts";
import { roomAuthorityToken } from "../application.ts";
import type { RoomPolicy } from "../room_policy.ts";

export function setRoomPolicy(projection: PageProjection, key: string, policy: RoomPolicy, name?: string): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	put(projection, { ...conv, policy, policyHeard: true, ...(name == null ? {} : { id: name }) });
}

/** Whether a private-room address should still wait for the room named
 * `name` to state its policy before reading it as open.
 *
 * A room restored from the workspace reads as open until its directory says
 * otherwise. The wait ends when the room is unavailable or its directory
 * disconnects, because neither will answer. */
export function roomPolicyPending(state: Pick<State, "convs" | "dirs">, name: string): boolean {
	for (const conv of state.convs.values()) {
		if (conv.type !== "room" || conv.id !== name || conv.policyHeard) continue;
		if (conv.membership === "unavailable") continue;
		if (state.dirs.get(conv.dir)?.session === "disconnected") continue;
		return true;
	}
	return false;
}

export function setRoomMembership(
	projection: PageProjection,
	key: string,
	membership: RoomConv["membership"],
	issue = "",
): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || (conv.membership === membership && conv.membershipIssue === issue)) return;
	if (membership !== "joined") retireRoomLineIds(projection, key);
	put(projection, { ...conv, membership, membershipIssue: membership === "unavailable" ? issue : "" });
}

/** The token a bearer string is kept as here. The store never holds the
 * string itself: a token says an authority is held and tells one from
 * another, and that is all a row needs to draw. */
export function authorityToken(bearer: string): string {
	return roomAuthorityToken(bearer);
}

export function dropRoomManager(projection: PageProjection, key: string, token: string): boolean {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || conv.managerToken == null || conv.managerToken !== token) return false;
	const { managerToken: _manager, ...withoutManager } = conv;
	put(projection, withoutManager);
	return true;
}

/** Mint the identity for a room this tab holds a reference to.
 *
 * A private room is not named by anything anybody could look up, so exactly
 * like an introduced direct line, its conversation is keyed by the holding
 * rather than by what the room is called. */
export function heldRoomKey(projection: PageProjection): string {
	return projection.nextHeldRoom();
}
