// Bounded presentation state accumulated for one live room.

import type { Message } from "../lib/room_client.ts";
import type { RoomsSessionRoomView } from "../lib/rooms_session.ts";
import { applyRoomPresence, type RoomMemberState } from "../lib/room_presence.ts";

export interface DurableRoomViewState {
	members: Map<string, RoomMemberState>;
	topic: string | null;
	lineBytes: number | null;
}

export function freshRoomView(): DurableRoomViewState {
	return { members: new Map(), topic: null, lineBytes: null };
}

export function applyRoomView(view: DurableRoomViewState, message: Message): void {
	if (message.presence != null) view.members = applyRoomPresence(view.members, message.presence);
	if (message.facts?.topic != null) view.topic = message.facts.topic;
	if (message.facts?.lineBytes != null) view.lineBytes = message.facts.lineBytes;
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
		members,
		membersMore: members.length < view.members.size,
		topic: view.topic,
		lineBytes: view.lineBytes,
		canSetTopic,
		canModerate,
	};
}
