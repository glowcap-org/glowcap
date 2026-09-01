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
import { type RoomAuthorityChange, roomAuthorityToken } from "../../../lib/room/authority.ts";
import type { RoomMembershipKind } from "../../../lib/room/membership.ts";
import type { RoomPolicy } from "../../../lib/room/policy.ts";
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

/** Remember a room link this tab already holds, so the conversation card can
 * copy it. Does not mint: a mint is `/link`, and looking at a room is not that. */
export function noteRoomLink(projection: PageProjection, key: string, link: string): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || conv.link === link) return;
	put(projection, { ...conv, link });
}

export function noteRoomManager(projection: PageProjection, key: string, manager: string): void {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || conv.manager === manager) return;
	put(projection, { ...conv, manager });
}

export function dropRoomManager(projection: PageProjection, key: string, token: string): boolean {
	const conv = getConv(projection, key);
	if (conv?.type !== "room" || conv.manager == null || roomAuthorityToken(conv.manager) !== token) return false;
	const { manager: _manager, ...withoutManager } = conv;
	put(projection, withoutManager);
	return true;
}

/** Remember the matching room and steward authorities after a claim or
 * handover has been validated. They move together because the steward was
 * accepted specifically for this room; recording only one would discard the
 * evidence the operation just established. */
export function noteRoomSteward(projection: PageProjection, key: string, roomLink: string, steward: string): void {
	const conv = getConv(projection, key);
	if (
		conv?.type !== "room" ||
		(conv.link === roomLink && conv.steward === steward)
	) return;
	put(projection, { ...conv, link: roomLink, steward });
}

export function clearRoomAuthority(projection: PageProjection, key: string, change: RoomAuthorityChange): boolean {
	const conv = getConv(projection, key);
	if (conv?.type !== "room") return false;
	const bearer = change.kind === "room" ? conv.link : change.kind === "manager" ? conv.manager : conv.steward;
	if (bearer != null && roomAuthorityToken(bearer) !== change.token) return false;
	if (change.kind === "manager") {
		const { manager: _manager, ...withoutManager } = conv;
		put(projection, withoutManager);
		return true;
	}
	const grants = new Set(conv.grants);
	grants.delete("steward");
	const { steward: _steward, ...withoutSteward } = conv;
	if (change.kind === "steward") {
		put(projection, { ...withoutSteward, grants });
		return true;
	}
	const { link: _link, ...withoutLink } = withoutSteward;
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
