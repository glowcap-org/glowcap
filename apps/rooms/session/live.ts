// Runtime-owned directory, room, and direct-line aggregate shapes.

import type { InboxOfferer } from "../lib/dm_inbox.ts";
import type { Directory } from "../lib/directory.ts";
import type { PostedLine, Room } from "../lib/room_client.ts";
import type { DurableDirectLine } from "./direct_line.ts";
import type { RoomFileCustody } from "./room_files.ts";
import type { DurableRoomViewState } from "./room_view.ts";
import type { RoomRealization } from "./room_realization.ts";
import type { DurableDirectoryView } from "./directory_view.ts";
import type { DirectConversationRouteAttempt } from "./direct_route_attempt.ts";

export interface DirectIntent {
	peer: string;
	peerRegistrationId: string;
	topology: string;
}

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
}

export interface LiveRoom {
	topology: string;
	ircIntent: string;
	room: Room;
	generation: string;
	pendingLines: Promise<PostedLine | null>[];
	postedLines: Map<number, PostedLine>;
	files: RoomFileCustody;
	view: DurableRoomViewState;
	standing: string | null;
}
