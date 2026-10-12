// The join card: the sentence over the fields, and the fields' own hints.
//
// The lead carries the ordinary act, which is naming a room. The alternatives
// (another directory's OCapN locator, a room entry link) belong on the address
// field, where a reader who has one in hand puts it.

import type { RoomPreset } from "../room/policy.ts";

/** The lead when the reader has nothing in hand: type a name and go. The
 * second sentence explains why there is no separate "create a room" step:
 * entering a name creates the room. */
export const joinLeadPlain =
	"There's no account to make. Type a room name to go there. If no room has that name yet, going there makes one.";

/** The lead when a link decided the destination. The reader did not choose
 * this room, so the card says what it shows before asking for anything. */
export const joinLeadLink = "This link opens one particular room. The name below is just what you'll see it as here.";

export function joinLeadNamedRoom(room: string, where: string): string {
	return `This address opens #${room} in ${where}.`;
}

export function joinLeadNamedDirectory(where: string): string {
	return `This address reaches ${where}. Name a room to enter there.`;
}

export function joinLeadPressedRoom(room: string, where: string): string {
	return `This is #${room} in ${where}. Pick the name you'll use.`;
}

/** On the name field, not in the lead. A join nickname is the directory-wide
 * identity that rooms and direct messages share. Saying so here keeps a later
 * join from looking like a room-local rename. */
export const joinNickLabel = "Display name";
export const joinNickHint = "Your name in this directory, used in rooms and direct messages. It must be available.";

/** The address field's hint, where the two pasted forms belong. */
export const joinLocatorLabel = "Address";
export const joinLocatorHint =
	"Leave this alone for the rooms on this server. To reach another server's rooms, paste its OCapN locator. To open one room somebody sent you, paste their link.";
export const joinLocatorHere = "This server";
export const joinLocatorOptional = "Optional";
/** When a link is already in the field there is nothing to choose, so the
 * label says what is there. */
export const joinLinkLabel = "Room link";

/** The card's title, the lead when the session cannot join, the access
 * control's spoken label, and the button's states. */
export const joinTitleCreate = "Create a room";
export const joinTitleJoin = "Join a room";
export const joinLeadPaused = "Your session link is paused, so there is nothing here to browse or join.";
export const joinLeadReadOnly = "Your session link lets you browse the shared rooms but not join one.";
export function joinAccessFixedLabel(standing: string, room: string): string {
	return `Room access: ${standing}. The room called ${room} already exists, and its manager sets this.`;
}
export function joinAccessLabel(standing: string, next: string): string {
	return `Room access: ${standing}. Change to ${next}.`;
}
export function roomAccessFixedLabel(standing: string): string {
	return `Room access: ${standing}. Not this session's to change.`;
}
export const joinStopConnecting = "Stop connecting";
export const joinStopCreating = "Stop creating";
export const joinStopJoining = "Stop joining";
export const joinSessionPaused = "Session paused";
export const joinCallIt = "Call it";
export const joinReadOnlySession = "Read-only session";
export const joinChooseAnotherName = "Choose another name";
export const joinConnecting = "Connecting…";
export const joinConnect = "Connect";
export const joinCreating = "Creating…";
export const joinJoining = "Joining…";
export const joinCreateRoom = "Create room";
export const joinJoinRoom = "Join room";
export const joinBrowseLiveRooms = "Browse live rooms";
export const joinHideDirectories = "Hide your directories";
export const joinChooseDirectory = "Choose one of your directories";
export const joinNickTakenOnDirectory = "That name is already in use on this directory.";
export const joinNickTakenInRoom = "That name is already in this room.";

/** A private-room name the directory's live rooms already hold. The room name
 * renders with its `#`, so the sentence opens with the mark. It is written
 * here and not at its call site so the text catalog sees it. */
export function joinPrivateRoomTaken(name: string): string {
	return `#${name} is already live here. Turn off Private to open it, or choose another name for a new private room.`;
}
export const joinInstead = " instead.";

/** What the join card calls the room field from its resolved access. Open is
 * the ordinary room and needs no qualifier. Private and moderated name
 * themselves, whether the reader chose them or an existing room fixed them. */
export function roomFieldLabel(kind: RoomPreset): string {
	return kind === "private" ? "Private room" : kind === "moderated" ? "Moderated room" : "Room";
}
/** The sidebar has no persistent field label beside its compact input, so its
 * placeholder names all three access choices. */
export function roomNamePlaceholder(kind: RoomPreset): string {
	return kind === "private" ? "private room name" : kind === "moderated" ? "moderated room name" : "open room name";
}
