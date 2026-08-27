// Pure topology projections for durable Rooms reconciliation.

import type { RoomsSessionState, WorkspaceConversation, WorkspaceDirectory } from "../lib/rooms_state.ts";

export type RoomConversation = Extract<WorkspaceConversation, { kind: "room" }>;
export type DirectConversation = Extract<WorkspaceConversation, { kind: "direct" }>;

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
		link: conversation.link ?? null,
		steward: conversation.steward ?? null,
		publicationId: conversation.publicationId ?? null,
	});
}

export function roomsIrcIntentTopology(conversation: RoomConversation): string {
	return conversation.irc === undefined ? "automatic" : JSON.stringify(conversation.irc);
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

export function roomsStandingTopology(checkpoint: RoomsSessionState): string {
	const directories = new Map(checkpoint.directories.map((directory) => [directory.id, directory]));
	return JSON.stringify(checkpoint.conversations.flatMap((conversation) =>
		conversation.kind !== "room" ? [] : [[
			conversation.id,
			conversation.standing ?? directories.get(conversation.directory)?.standing ?? checkpoint.standing,
		]]
	));
}
