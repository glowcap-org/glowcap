// The Rooms operator page: the lists a directory operator can change, and what
// each act on them leaves standing.
//
// Operator copy, so precision beats plainness here as it does in `ops.ts`. A
// reader is deciding whether to retire a session, a name, a room, or a whole
// authority class, and the sentence under the act says what goes and what
// stays.

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
		"All rooms, nickname claims, other peer sessions, and current trouble are retired. Durable room entry links and server identity remain.",
};
export const operatorResetAll: OperatorReset = {
	subject: "Rooms authority",
	act: "Factory reset",
	label: "Factory reset Rooms authority",
	effect:
		"The room-authority secret is rotated. Active links, tombstones, and moderator grants are cleared, and then all rooms, nickname claims, other peer sessions, and current trouble are retired. This operator connection, server identity, and retained message history remain. Old authorities stay revoked, and room names can mint unrelated new links.",
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
export const operatorLead =
	"This tab holds the Rooms operator capability. Its lists show what it can change, not roles inferred from a nickname or room membership.";

/** Room access: the durable entry links. */
export const operatorLinksTitle = "Room access";
export const operatorLinksLead =
	"Durable room entry links admit future holders and already-live copies. Removing one invalidates both.";
export const operatorLinksEmpty = "No durable room entry links are active.";
export const operatorPrivateRoom = "Private room";
export const operatorRemoveAsk = "Remove…";
export const operatorLinkRemoveEffect =
	"Copied links and references already in use stop opening this room. A later link for the same room will be a fresh capability.";
export const operatorLinkRemove = "Remove room entry link";
export const operatorLinksSweepSubject = "room entry links";
export const operatorLinksSweepEffect =
	"Copied links and references already in use stop opening those rooms. Later links for the same rooms will be fresh capabilities.";
export const operatorSweepRevoke = "Revoke";
export const operatorSweepRevoked = "Revoked";
export const operatorSweepRemove = "Remove";
export const operatorSweepRemoved = "Removed";
export const operatorSweepDisconnect = "Disconnect";
export const operatorSweepDisconnected = "Disconnected";
export const operatorSweepRelease = "Release";
export const operatorSweepReleased = "Released";

/** Names and reachability: nickname registrations. */
export const operatorNamesTitle = "Names and reachability";
export const operatorNamesLead =
	"A registered nickname holds direct-message inboxes and signaling routes on one exact session.";
export const operatorNamesEmpty = "No nicknames are registered.";
export const operatorYours = "yours";
export const operatorNickRemoveEffect =
	"The holder loses this name, its vouchers, inbox offers, and directory-routed DM reachability.";
export const operatorNickRemove = "Remove nickname claim";
export const operatorNamesSweepSubject = "nickname claims";
export const operatorNamesSweepEffect =
	"Each holder loses that name, its vouchers, inbox offers, and directory-routed reachability.";

/** Connections and live references: peer sessions. */
export const operatorSessionsTitle = "Connections and live references";
export const operatorSessionsLead =
	"Disconnecting retires the session's memberships, registrations, imports, exports, and object references together.";
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
export const operatorRoomsTitle = "Rooms and object capabilities";
export const operatorRoomsLead =
	"Each row is an application owner the directory can retire as one transaction. Local rooms release membership capabilities, peered rooms release their retained room reference, and IRC rooms part through the bridge that owns their sockets.";
export const operatorRoomsEmpty = "No room owners are live.";
export const operatorUnnamedPrivateRoom = "Unnamed private room";
/** The act and its effect for one room owner, by kind of owner. */
export function operatorRoomRemoveAct(kind: string): { action: string; effect: string } {
	switch (kind) {
		case "peered":
			return {
				action: "Remove peered publication",
				effect:
					"The directory releases its retained room capability and removes this exact publication. References already handed to members stay with those sessions.",
			};
		case "pending-peered":
			return {
				action: "Cancel pending publication",
				effect:
					"The pending handoff is cancelled through its peering owner, its retained room reference is released, and its readiness promise is refused.",
			};
		case "irc":
			return {
				action: "Part IRC bridge",
				effect:
					"The gateway retires every IRC seat, closes the bridge connection, and removes its room publication.",
			};
		default:
			return {
				action: "Close room generation",
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
export const operatorRoomsSweepEffect =
	"Each room closes as one transaction, releasing its memberships and the live references it holds.";

/** Room moderator authority. */
export const operatorModerationTitle = "Room moderator authority";
export const operatorModerationLead =
	"Grant a room moderator capability for recovery or handoff. Rotating it stops copied and already-live old holders. Active IRC bridges appear through their own source authority, and peered rooms remain with their remote source.";
export const operatorModerationEmpty = "This server owns no rooms right now.";
export const operatorRotateAsk = "Rotate…";
export const operatorGranting = "Granting…";
export const operatorGrantModerator = "Grant moderator capability";
export function operatorCopyModerator(title: string): string {
	return `Copy ${title}'s room moderator capability`;
}
export const operatorModeratorRevokeEffect =
	"Every old copy stops moderating this room immediately, including references already in use.";
export const operatorModeratorRevoke = "Revoke old moderator capability";

/** Directory trouble: the failures diagnostics reports. */
export const operatorTroubleTitle = "Directory trouble";
export const operatorTroubleLead =
	"The recent failures that diagnostics reports. Clearing removes these rows. It changes no room, session, or saved history.";
export const operatorTroubleEmpty = "The directory has reported no trouble.";
export const operatorTroubleClearAsk = "Clear the list…";
export const operatorTroubleClearEffect =
	"Every current diagnostic row is acknowledged and removed. New failures will still be recorded.";
export const operatorTroubleClear = "Clear directory trouble";

/** Reset and recovery. */
export const operatorResetTitle = "Reset and recovery";
export const operatorResetLead =
	"Reset one authority class at a time. This operator connection remains so the action can answer.";
