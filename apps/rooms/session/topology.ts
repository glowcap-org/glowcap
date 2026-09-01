// Pure topology projections for durable Rooms reconciliation.

import type {
	RoomsSessionState,
	WorkspaceConversation,
	WorkspaceDirectConversation,
	WorkspaceDirectory,
	WorkspaceRoomConversation,
} from "../lib/rooms_state.ts";

export type RoomConversation = WorkspaceRoomConversation;
export type DirectConversation = WorkspaceDirectConversation;

export function directoryRooms(
	directoryId: string,
	conversations: readonly WorkspaceConversation[],
): RoomConversation[] {
	return conversations.filter((conversation): conversation is RoomConversation =>
		conversation.kind === "room" && conversation.directory === directoryId
	);
}

export function directoryDirects(
	directoryId: string,
	conversations: readonly WorkspaceConversation[],
): DirectConversation[] {
	return conversations.filter((conversation): conversation is DirectConversation =>
		conversation.kind === "direct" && conversation.directory === directoryId
	);
}

export function roomsDirectoryConnectionTopology(directory: WorkspaceDirectory): string {
	return JSON.stringify({ id: directory.id, locator: directory.locator, nick: directory.nick });
}

export function roomsConversationTopology(conversation: RoomConversation): string {
	return JSON.stringify({
		id: conversation.id,
		name: conversation.name,
		held: conversation.held,
		publicationId: conversation.publicationId ?? null,
	});
}

/** What this room's reader has told its bridge, as one comparable value.
 *
 * Absent is not the same as null: never having answered a form leaves a bridge
 * to do whatever it does by default, and answering it with nothing is a choice
 * to stay out. Realization compares these to know whether anything changed. */
export function roomsBridgeIntentTopology(conversation: RoomConversation): string {
	return conversation.bridgeIntent === undefined ? "automatic" : JSON.stringify(conversation.bridgeIntent);
}

export function roomsDirectoryTopology(
	directory: WorkspaceDirectory,
	conversations: readonly WorkspaceConversation[],
): string {
	return JSON.stringify({
		directory: roomsDirectoryConnectionTopology(directory),
		rooms: directoryRooms(directory.id, conversations).map(roomsConversationTopology),
		directs: directoryDirects(directory.id, conversations).map((direct) => ({
			id: direct.id,
			peer: direct.peer,
			closed: direct.closed,
		})),
	});
}

export function roomsSessionTopology(checkpoint: RoomsSessionState): string {
	return JSON.stringify(
		{
			directories: checkpoint.directories.map((directory) =>
				roomsDirectoryTopology(directory, checkpoint.conversations)
			),
			operations: checkpoint.capabilities.operations,
			archivePeer: checkpoint.capabilities.archivePeer,
			peering: checkpoint.peering,
		},
	);
}
