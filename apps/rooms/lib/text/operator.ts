// The Rooms operator page: the lists an operator can change, the diagnostics
// beside them, and what each act on them leaves standing.
//
// Operator copy, so precision beats plainness here as it does in `ops.ts`. A
// reader is deciding whether to retire a session, a name, a room, or every
// one of a kind, and the sentence under the act says what goes and what
// stays.

import { managerLinkPower, moderatorLinkPower } from "./room_authority.ts";

/** One reset scope: what it is about, the act, its full name, and its effect. */
export interface OperatorReset {
	readonly subject: string;
	/** The act, offered with an ellipsis and committed in full. */
	readonly act: string;
	readonly label: string;
	readonly effect: string;
}

export const operatorResetLinks: OperatorReset = {
	subject: "Room entry links",
	act: "Revoke all",
	label: "Revoke all room entry links",
	effect: "Every current durable room entry link is permanently revoked.",
};
export const operatorResetRegistrations: OperatorReset = {
	subject: "Nickname claims",
	act: "Reset",
	label: "Reset nickname claims",
	effect: "Every current nickname registration, voucher, inbox offer, and signaling route is retired.",
};
export const operatorResetSessions: OperatorReset = {
	subject: "Other peer sessions",
	act: "Disconnect",
	label: "Disconnect other peer sessions",
	effect: "Every peer session except this operator connection is disconnected.",
};
export const operatorResetRooms: OperatorReset = {
	subject: "Rooms",
	act: "Remove all",
	label: "Remove all rooms",
	effect: "Every current room and every live reference it holds are removed.",
};
export const operatorResetRuntime: OperatorReset = {
	subject: "Directory runtime",
	act: "Reset",
	label: "Reset directory runtime",
	effect:
		"All rooms, other peer sessions, their nickname claims, and current trouble are retired. Durable room entry links, server identity, and the operator's own connection and nickname remain.",
};
export const operatorResetAll: OperatorReset = {
	subject: "Rooms authority",
	act: "Factory reset",
	label: "Factory reset Rooms authority",
	effect:
		"The secret behind every room link is rotated. Active links, records of revoked links, and moderator and manager links are cleared. Then all rooms, other peer sessions, their nickname claims, and current trouble are retired. Server identity, retained message history, and the operator's own connection and nickname remain. Revoked links stay revoked, and room names can mint unrelated new links.",
};

/** The two chips on a room row: what kind of room it is, and how its origin
 * was proved. */
export const operatorRoomKind: Readonly<Record<string, string>> = {
	local: "local",
	private: "private",
	peered: "peered",
	"pending-peered": "pending",
	irc: "IRC",
};
export const operatorProofAuthenticated = "identity proved";
export const operatorProofSession = "session only";
export const operatorProofBridge = "through the bridge";

export const operatorLoadMore = "Load more";
export const operatorLead = "What this server holds that you can change, and how it is running.";

/** Room access: the durable entry links. */
export const operatorLinksTitle = "Room access";
export const operatorLinksLead =
	"Anyone with one of these links can enter the room. Removing a link stops every copy of it.";
export const operatorLinksEmpty = "No durable room entry links are active.";
export const operatorPrivateRoom = "Private room";
export const operatorRemoveAsk = "Remove…";
export const operatorLinkRemoveEffect =
	"Copied links and references already in use stop opening this room. A later link for the same room will be new.";
export const operatorLinkRemove = "Remove room entry link";
export const operatorLinksSweepSubject = "room entry links";
export const operatorLinksSweepEffect =
	"Copied links and references already in use stop opening those rooms. Later links for the same rooms will be new.";
export const operatorSweepRevoke = "Revoke";
export const operatorSweepRevoked = "Revoked";
export const operatorSweepRemove = "Remove";
export const operatorSweepRemoved = "Removed";
export const operatorSweepDisconnect = "Disconnect";
export const operatorSweepDisconnected = "Disconnected";
export const operatorSweepRelease = "Release";
export const operatorSweepReleased = "Released";

/** Nickname registrations. */
export const operatorNamesTitle = "Nicknames";
export const operatorNamesLead =
	"A registered nickname holds direct-message inboxes and signaling routes on one exact session.";
export const operatorNamesEmpty = "No nicknames are registered.";
export const operatorYours = "yours";
export const operatorNickRemoveEffect =
	"The holder loses this name, its vouchers, inbox offers, and directory-routed reachability.";
export const operatorNickRemove = "Remove nickname claim";
export const operatorNamesSweepSubject = "nickname claims";
export const operatorNamesSweepEffect =
	"Each holder loses that name, its vouchers, inbox offers, and directory-routed reachability.";

/** Peer sessions. */
export const operatorSessionsTitle = "Peer sessions";
export const operatorSessionsLead = "Disconnecting someone ends their memberships and names here.";
export const operatorSessionsEmpty = "No peer sessions are connected.";
export const operatorUnnamedPeer = "Unnamed peer";
export const operatorDisconnectAsk = "Disconnect…";
export const operatorSessionDisconnectEffect =
	"The connection closes with every membership, publication, import, and export it owns.";
export const operatorSessionDisconnect = "Disconnect session";
export const operatorSessionsSweepSubject = "peer sessions";
export const operatorSessionsSweepEffect =
	"Those connections close with every membership, publication, import, and export they own.";

/** Rooms and object capabilities: the application owners. */
export const operatorRoomsTitle = "Rooms and their connections";
export const operatorRoomsLead =
	"Each row is a room or connection the directory can close. Local rooms release their membership links, peered rooms their room link, and IRC rooms disconnect through their bridge.";
export const operatorRoomsEmpty = "No room owners are live.";
export const operatorUnnamedPrivateRoom = "Unnamed private room";
/** The act and its effect for one room owner, by kind of owner. */
export function operatorRoomRemoveAct(kind: string): { action: string; effect: string } {
	switch (kind) {
		case "peered":
			return {
				action: "Remove peered publication",
				effect:
					"The directory releases its retained room link and removes this exact publication. References already handed to members stay with those sessions.",
			};
		case "pending-peered":
			return {
				action: "Cancel pending publication",
				effect:
					"The unfinished connection to the other directory is cancelled and its room link is released. Anyone waiting on it is told it was refused.",
			};
		case "irc":
			return {
				action: "Part IRC bridge",
				effect:
					"The gateway retires every IRC seat, closes the bridge connection, and removes its room publication.",
			};
		default:
			return {
				action: "Close this room",
				effect:
					"Every membership and live reference held by this room is released. The peer sessions and any separately issued durable link remain.",
			};
	}
}
export function operatorRoomFrom(origin: string): string {
	return `from ${origin}`;
}
export function operatorRoomRetains(count: number): string {
	return `holds ${count} live reference${count === 1 ? "" : "s"}`;
}
export function operatorRoomWith(members: readonly { nick: string; state: string }[]): string {
	return `with ${
		members.map((member) => member.state === "" ? member.nick : `${member.nick} (${member.state})`).join(", ")
	}`;
}
export const operatorRoomsSweepSubject = "room owners";
export const operatorRoomsSweepEffect = "Each room closes, releasing its memberships and the live references it holds.";

/** Room authority: every room the server owns with its manager and moderator links. */
export const operatorModerationTitle = "Rooms and their links";
export const operatorModerationLead =
	"Every room this server owns, including empty ones, with the links that stand for it. A room an IRC bridge runs has no manager link. Peered rooms stay with their remote source.";
export const operatorModerationEmpty = "This server owns no rooms.";
/** The row's tags: which links stand for the room. */
export const operatorManagerPart = "Manager";
export const operatorModeratorPart = "Moderator";
export const operatorNoLinks = "No links";
/** The tag on a room an IRC bridge runs. */
export const operatorBridgedPart = "IRC";
export const operatorRoomLinksOpen = "Links…";
/** The card over the list for one room's two links. */
export function operatorRoomLinksCardTitle(title: string): string {
	return `Links for ${title}`;
}
export const operatorRoomLinksLead =
	"Each link gives its power to whoever holds it. Copy one for a handoff or a recovery, and revoke it to stop every copy. The room stays listed here while anyone is in it, any link stands for it, or this server keeps its name and settings.";
export const operatorManagerLinkTitle = "Manager link";
export const operatorManagerHeldHint = managerLinkPower;
export const operatorManagerNoneHint = "No manager link stands for this room. Issue one to copy it.";
/** Said in place of the manager link on a room an IRC bridge runs. */
export const operatorBridgedManagerHint = "An IRC bridge runs this room, so it has no manager link.";
export const operatorModeratorLinkTitle = "Moderator link";
export const operatorModeratorHeldHint = moderatorLinkPower;
export const operatorModeratorNoneHint = "No moderator link stands for this room. Issue one to copy it.";
export const operatorRevokeAsk = "Revoke…";
/** The one act that removes a room from this server entirely. */
export const operatorForgetRoomTitle = "Forget the room";
export const operatorForgetRoomHint =
	"Forgetting the room removes anyone in it, stops every link to it, drops its subject and kept messages, and frees its name.";
export const operatorForgetRoomAsk = "Forget room…";
export const operatorForgetRoom = "Forget room";
export const operatorForgetRoomEffect =
	"Anyone in the room is removed and every copy of its links stops working at once. Its subject and kept messages are gone. Its name is free to use again. A later link for a room of the same name will be new.";
export const operatorIssuing = "Issuing…";
export const operatorIssueManager = "Issue manager link";
export const operatorIssueModerator = "Issue moderator link";
export function operatorCopyManager(title: string): string {
	return `Copy ${title}'s room manager link`;
}
export function operatorCopyModerator(title: string): string {
	return `Copy ${title}'s room moderator link`;
}
export const operatorManagerRevoke = "Revoke manager link";
export const operatorManagerRevokeEffect =
	"Every copy of this room's manager link stops working at once, including the one its maker holds. The room keeps its name, members, and moderator link. A new manager link can be issued here.";
export const operatorModeratorRevoke = "Revoke moderator link";
export const operatorModeratorRevokeEffect =
	"Every copy of this room's moderator link stops working at once, including references already in use. The room keeps its name, members, and manager link. A new moderator link can be issued here.";

/** Directory trouble: the failures diagnostics reports. */
export const operatorTroubleTitle = "Directory trouble";
export const operatorTroubleLead =
	"Recent failures that diagnostics reports. Clearing them changes no room, session, or saved history.";
export const operatorTroubleEmpty = "The directory has reported no trouble.";
export const operatorTroubleClearAsk = "Clear the list…";
export const operatorTroubleClearEffect =
	"Every current diagnostic row is acknowledged and removed. New failures will still be recorded.";
export const operatorTroubleClear = "Clear directory trouble";

/** Reset and recovery. */
export const operatorResetTitle = "Reset and recovery";
export const operatorResetLead = "This operator connection and its nickname remain through every reset.";
export function operatorReferenceMember(member: string): string {
	return `member ${member}`;
}
