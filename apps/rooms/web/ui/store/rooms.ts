// What this tab remembers about one room it is in.
//
// The module next door owns which conversations exist and how to find one.
// This owns what is true of a room once found: what its reader told the bridge
// behind it, what the room's policy and membership are, and which of its
// authorities this tab holds. Each is a small replace-if-changed write, because
// the projection rewrites a conversation object only when something actually
// moved and a needless rewrite re-renders a roster.

import type { RoomConv } from "../types.ts";
import type { PageProjection } from "./core.ts";
import { getConv, put } from "./convs.ts";
import type { RoomAuthorityChange } from "../../../lib/room/authority.ts";
import { roomAuthorityToken } from "../application.ts";
import type { RoomMembershipKind } from "../../../lib/room/membership.ts";
import type { RoomPolicy } from "../room_policy.ts";
import type { WorkspaceRoomBridgeIntent } from "../../../lib/rooms_state.ts";

/** Remember what this reader told a bridge, here and everywhere it reaches.
 *
 * Scope is the bridge's own word for how far one answer goes, and this is the
 * same rule the durable command applies: the room it was answered in, plus
 * every room already under that scope. */
export function setRoomBridgeIntent(
	projection: PageProjection,
	key: string,
	intent: WorkspaceRoomBridgeIntent | null,
	scope: string,
): void {
	const current = projection.get();
	const convs = new Map(current.convs);
	let changed = false;
	for (const [candidateKey, candidate] of convs) {
		if (candidate.type !== "room") continue;
		// The room's own stated scope first, because a channel nobody has linked
		// on yet has no saved intent to match and is still on the network this
		// answer reaches. What was already saved is the fallback for a room whose
		// bridge facts have not arrived on this tab yet.
		const inScope = candidateKey === key || candidate.bridge?.scope === scope ||
			candidate.bridgeIntent?.scope === scope;
		if (!inScope || JSON.stringify(candidate.bridgeIntent) === JSON.stringify(intent)) continue;
		convs.set(candidateKey, { ...candidate, bridgeIntent: intent });
		changed = true;
	}
	if (changed) projection.set({ convs });
}

/** What this reader told this one room's bridge, or nothing.
 *
 * Undefined and null are different answers: never having answered leaves a
 * bridge to its own defaults, and answering with nothing is a choice to stay
 * out, so the field is removed rather than nulled for the first. */
function setRoomBridgeIntentHere(
	projection: PageProjection,
	key: string,
	intent: WorkspaceRoomBridgeIntent | null | undefined,
): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || JSON.stringify(conv.bridgeIntent) === JSON.stringify(intent)) return;
	if (intent === undefined) {
		const { bridgeIntent: _intent, ...automatic } = conv;
		put(projection, automatic);
		return;
	}
	put(projection, { ...conv, bridgeIntent: intent });
}

/** Forget what this reader told a bridge, across everything that scope reached.
 *
 * The scope comes from what was saved, because a reader taking something back
 * is taking back exactly what they gave. This is forgetting rather than
 * disconnecting: choosing to stay Rooms-only is itself an answer, and it is
 * remembered by submitting it, not by clearing this. */
export function clearRoomBridgeIntent(projection: PageProjection, key: string): void {
	const conv = getConv(projection, key);
	const scope = conv?.type === "room" ? conv.bridgeIntent?.scope : undefined;
	if (scope === undefined) setRoomBridgeIntentHere(projection, key, null);
	else setRoomBridgeIntent(projection, key, null, scope);
}

export function setRoomBridgeIssue(projection: PageProjection, key: string, issue: string): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || conv.bridgeIssue === issue) return;
	put(projection, { ...conv, bridgeIssue: issue });
}

export function setRoomPolicy(projection: PageProjection, key: string, policy: RoomPolicy, name?: string): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	put(projection, { ...conv, policy, ...(name == null ? {} : { id: name }) });
}

export function setRoomMembershipKind(
	projection: PageProjection,
	key: string,
	membershipKind: RoomMembershipKind,
): void {
	const conv = getConv(projection, key);
	if (conv?.type === "room" && conv.membershipKind !== membershipKind) put(projection, { ...conv, membershipKind });
}

export function setRoomMembership(
	projection: PageProjection,
	key: string,
	membership: RoomConv["membership"],
	issue = "",
): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || (conv.membership === membership && conv.membershipIssue === issue)) return;
	put(projection, { ...conv, membership, membershipIssue: membership === "unavailable" ? issue : "" });
}

/** The token a bearer string is kept as here. The store never holds the
 * string itself: a token says an authority is held and tells one from
 * another, and that is all a row needs to draw. */
export function authorityToken(bearer: string): string {
	return roomAuthorityToken(bearer);
}

/** Note a room link this tab already holds, so the conversation card can
 * offer to copy it. Does not make one: that is `/link`, and looking at a room
 * is not that. */
export function noteRoomLink(projection: PageProjection, key: string, link: string): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	const linkToken = authorityToken(link);
	if (conv.linkToken === linkToken) return;
	put(projection, { ...conv, linkToken });
}

export function noteRoomManager(projection: PageProjection, key: string, manager: string): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	const managerToken = authorityToken(manager);
	if (conv.managerToken === managerToken) return;
	put(projection, { ...conv, managerToken });
}

export function dropRoomManager(projection: PageProjection, key: string, token: string): boolean {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || conv.managerToken == null || conv.managerToken !== token) return false;
	const { managerToken: _manager, ...withoutManager } = conv;
	put(projection, withoutManager);
	return true;
}

/** Note the matching room and moderator authorities after a claim or handover
 * has been validated. They move together because the moderator was accepted
 * for this exact room; recording only one would discard the evidence the
 * operation just established. */
export function noteRoomSteward(projection: PageProjection, key: string, roomLink: string, steward: string): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return;
	const linkToken = authorityToken(roomLink);
	const stewardToken = authorityToken(steward);
	if (conv.linkToken === linkToken && conv.stewardToken === stewardToken) return;
	put(projection, { ...conv, linkToken, stewardToken });
}

export function clearRoomAuthority(projection: PageProjection, key: string, change: RoomAuthorityChange): boolean {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return false;
	const held = change.kind === "room"
		? conv.linkToken
		: change.kind === "manager"
		? conv.managerToken
		: conv.stewardToken;
	if (held != null && held !== change.token) return false;
	if (change.kind === "manager") {
		const { managerToken: _manager, ...withoutManager } = conv;
		put(projection, withoutManager);
		return true;
	}
	const grants = new Set(conv.grants);
	grants.delete("steward");
	const { stewardToken: _steward, ...withoutSteward } = conv;
	if (change.kind === "steward") {
		put(projection, { ...withoutSteward, grants });
		return true;
	}
	const { linkToken: _link, ...withoutLink } = withoutSteward;
	put(projection, { ...withoutLink, grants });
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
