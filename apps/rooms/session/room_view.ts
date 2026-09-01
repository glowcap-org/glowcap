// Bounded presentation state accumulated for one live room.

import type { Message } from "../lib/room/client.ts";
import type { BridgeFacts } from "../lib/room/message.ts";
import type { RoomsSessionRoomView } from "../lib/session/client.ts";
import { applyRoomPresence, type RoomMemberState } from "../lib/room/presence.ts";
import type { RoomMembershipKind } from "../lib/room/membership.ts";
import type { RoomPolicy } from "../lib/room/policy.ts";

export interface DurableRoomViewState {
	members: Map<string, RoomMemberState>;
	topic: string | null;
	lineBytes: number | null;
	/** What the bridge behind this room calls its own, when one said so.
	 *
	 * Kept here for the same reason the topic is: an attached reader who reloads
	 * rebuilds from this view rather than from the welcome, and a roster whose
	 * bridge facts did not survive draws its foreign members under their row keys
	 * with no badge.
	 *
	 * Null rather than absent, so "no bridge said anything" has one form here
	 * instead of two the projection would have to treat alike. */
	bridge: BridgeFacts | null;
	membershipKind: RoomMembershipKind;
	policy: RoomPolicy;
}

export function freshRoomView(membershipKind: RoomMembershipKind, policy: RoomPolicy): DurableRoomViewState {
	return { members: new Map(), topic: null, lineBytes: null, bridge: null, membershipKind, policy };
}

export function applyRoomView(view: DurableRoomViewState, message: Message): void {
	if (message.presence != null) view.members = applyRoomPresence(view.members, message.presence);
	if (message.facts?.topic != null) view.topic = message.facts.topic;
	if (message.facts?.lineBytes != null) view.lineBytes = message.facts.lineBytes;
	if (message.facts?.bridge != null) view.bridge = message.facts.bridge;
}

export function projectRoomView(
	conversationId: string,
	view: DurableRoomViewState,
	canSetTopic = false,
	canModerate = false,
	memberLimit = view.members.size,
): RoomsSessionRoomView {
	const members = [...view.members].slice(0, memberLimit);
	return {
		conversationId,
		membershipKind: view.membershipKind,
		policy: view.policy,
		members,
		membersMore: members.length < view.members.size,
		topic: view.topic,
		lineBytes: view.lineBytes,
		bridge: view.bridge,
		canSetTopic,
		canModerate,
	};
}
