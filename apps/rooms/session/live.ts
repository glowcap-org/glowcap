// Runtime-owned directory, room, and direct-line aggregate shapes.

import type { InboxOfferer } from "../lib/dm_inbox.ts";
import type { Directory } from "../lib/directory.ts";
import type { PostedLine, Room } from "../lib/room/client.ts";
import type { DurableDirectLine } from "./direct_line.ts";
import type { RoomFileCustody } from "./room_files.ts";
import type { DurableRoomViewState } from "./room_view.ts";
import type { RoomRealization } from "./room_realization.ts";
import type { DurableDirectoryView } from "./directory_view.ts";
import type { DirectConversationRouteAttempt } from "./direct_route_attempt.ts";
import type { RoomEntryKind } from "../lib/directory_publications.ts";

export interface DirectIntent {
	peer: string;
	peerRegistrationId: string;
	topology: string;
}

/** One directory connection this runtime currently holds. Call sites often name
 * the value `held`. That is this object, not checkpoint `held`, which means the
 * room is private or source-owned. */
export interface LiveDirectory {
	id: string;
	topology: string;
	nick: string;
	directory: Directory;
	view: DurableDirectoryView;
	roomRealization: RoomRealization;
	directs: Map<string, DurableDirectLine>;
	directIntents: Map<string, DirectIntent>;
	directRouteAttempts: Map<string, DirectConversationRouteAttempt>;
	directConversationByRegistration: Map<string, string | null>;
	offerer: InboxOfferer;
	stopClose: () => void;
	/** Inbox that answers WebRTC offers on this directory session. Present after
	 * a webrtc `memberLocator` register; closed before the directory session. */
	signaling?: { close(): Promise<void> } | null;
}

export interface LiveRoom {
	topology: string;
	source: RoomEntryKind | "unknown";
	bridgeIntent: string;
	room: Room;
	generation: string;
	pendingLines: Promise<PostedLine | null>[];
	postedLines: Map<number, PostedLine>;
	files: RoomFileCustody;
	view: DurableRoomViewState;
	standing: string | null;
}
