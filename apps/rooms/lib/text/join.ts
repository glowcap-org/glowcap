// The join card: the sentence over the fields, and the fields' own hints.
//
// The lead used to hand a first-time reader three alternatives at once — name
// a room in this page's directory, paste another directory's OCapN locator, or
// paste a room entry link — which is a correct description of the control and
// an unusable instruction. Two of the three are for somebody who already has
// something in their clipboard, and the one everybody does is buried in the
// middle of the protocol's vocabulary.
//
// So the lead carries the ordinary act, and the alternatives move to the field
// where a reader would put them. That is not a simplification: nothing is
// removed, and the address field now says the precise thing at the moment it
// is useful rather than in a sentence read before any of it applies.

import type { RoomPreset } from "../room/policy.ts";

/** The lead when the reader has nothing in hand: type a name and go. The
 * second sentence is the surprising half of this product and the reason there
 * is no "create a room" anywhere — entering is creating. */
export const joinLeadPlain =
	"There's no account to make. Type a room name to go there. If no room has that name yet, going there makes one.";

/** The lead when a link decided the destination. The reader did not choose
 * this room, so the card says what it is looking at before asking for
 * anything. */
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

/** On the name field rather than in the lead. A join nickname is the
 * directory-wide identity that rooms and direct messages share; saying so at
 * the choice prevents a later join from looking like a room-local rename. */
export const joinNickLabel = "Display name";
export const joinNickHint = "Your name in this directory, used in rooms and direct messages. It must be available.";

/** The address field's own hint, which is where the two pasted forms belong:
 * this is the moment a reader has one in hand. */
export const joinLocatorLabel = "Address";
export const joinLocatorHint =
	"Leave this alone for the rooms on this server. To reach another server's rooms, paste its OCapN locator. To open one room somebody sent you, paste their link.";
export const joinLocatorHere = "This server";
export const joinLocatorOptional = "Optional";
/** When a link is already in the field there is nothing to choose, so the
 * label states what is there rather than offering the alternatives. */
export const joinLinkLabel = "Room link";

/** The card's title, the lead when the session cannot join, the access
 * control's spoken label, and the one button's many faces. */
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
export const joinHideDirectories = "Hide held directories";
export const joinChooseDirectory = "Choose a held directory";
export const joinNickTakenOnDirectory = "That name is already in use on this directory.";
export const joinNickTakenInRoom = "That name is already in this room.";
export const joinInstead = " instead.";

/** What the join card calls the room field from its resolved access. Open is
 * the ordinary room, so it needs no qualifier; the two departures name
 * themselves whether the reader chose one or an existing room fixed it. */
export function roomFieldLabel(kind: RoomPreset): string {
	return kind === "private" ? "Private room" : kind === "moderated" ? "Moderated room" : "Room";
}
/** The rail has no persistent field label beside its compact input, so its
 * placeholder names all three access choices explicitly. */
export function roomNamePlaceholder(kind: RoomPreset): string {
	return kind === "private" ? "private room name" : kind === "moderated" ? "moderated room name" : "open room name";
}
