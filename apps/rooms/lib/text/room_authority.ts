// Who can manage or moderate a room, and what each act leaves standing.
//
// These are destructive acts with different reach, and the sentences say
// which. Discarding a capability this session holds is not the same as
// revoking one everybody holds, and a reader about to press one needs to know
// which they are pressing.

export const roomCapabilitiesTitle = "Room links";

/** A bridged room has no manager capability to take, because the channel is not
 * this server's to manage. The sentence comes in three parts so the middle one
 * can be a link to the place to go. The component supplies the address. */
export const bridgeHasNoManagerLead = "The IRC bridge owns entry and moderator authority. Administer the channel in";
export const bridgeHasNoManagerLink = "IRC operations";
export const bridgeHasNoManagerAfter = ".";
export const roomManagerTake = "Take a shared room manager link";
export const roomManagerCopy = "Copy the room manager link";
export const roomManagerDiscard = "Discard room manager link";
export const roomLinkCopy = "Copy this room link";
export const roomLinkRevoke = "Revoke this room link";
export const roomModeratorTake = "Take a shared room moderator link";
export const roomModeratorCopy = "Copy the room moderator link";
export const roomModeratorDiscard = "Discard room moderator link";
export const roomModerationRevokeAll = "Revoke room moderation for everyone";
export const roomManagerDiscardSay = "This session gives up its manager link. Other copies still work.";
export const roomNameReleaseSay =
	"The public name is released, and so is the way in that goes with it. The room, the people in it, and the links you hold all stay. You can register the room again by changing its access.";
export const roomLinkRevokeSay =
	"This link and the current moderator link stop working for everyone right away. People already in the room stay in, and you can make new ones afterwards.";
export const roomModeratorDiscardSay =
	"This session gives up its moderator link. Other copies still work, and you can take a current one again later.";
export const roomModerationRevokeAllSay =
	"Every copy stops moderating this room right away, including ones already in use. The room link and the people in the room stay.";
export const roomKeepManagement = "Keep management";
export const roomKeepRegistration = "Keep registration";
export const roomKeepLink = "Keep link";
export const roomKeepCapability = "Keep link";
export const roomDiscardCapability = "Discard link";
export const roomReleaseName = "Release registered name";
export const roomRevokeAuthority = "Revoke room authority";
export const roomRevokeModerator = "Revoke moderator link";
export const roomModerationTitle = "Room moderation";
export const roomUnbridgeSay = "Unbridge this room? Every connection closes and the room leaves this server.";
export const roomKeepHere = "Keep here";
export const roomKeepBridge = "Keep bridge";

/** The room card's three sections: management, the room link, and
 * moderation. */
export function roomAccessNow(preset: string): string {
	return `Room access is now ${preset}.`;
}
export const roomCapabilityWait = "Wait for the room link operation to finish.";
export const roomManagementTitle = "Room management";
export const roomManagerTakeHint =
	"This manages this room link and moderator link. It doesn't grant entry or moderation by itself.";
export const roomManagerTakeCommit = "Take manager link";
export const roomManagerRecoverHint =
	"This session also holds the directory operator link, which can recover management for this exact room.";
export const roomManagerRecover = "Recover manager link";
export const roomManagerSourceOwned =
	"This room's source owns its management link. This directory's operator can't create it.";
export const roomManagerHeldHint =
	"Manages the room link and moderator. It doesn't grant entry or moderation. Sharing it delegates management. The directory operator can recover a lost copy.";
export const roomManagerDiscarded = "This session discarded its room manager link.";
export function roomNameReleaseLabel(room: string): string {
	return `Release the registered name #${room}`;
}
export function roomNameReleased(room: string): string {
	return `Released the registered room name #${room}.`;
}
export const roomManagerDiscardAsk = "Discard manager…";
export const roomNameReleaseAsk = "Release registered name…";
export const roomLinkTitle = "Room link";
export const roomLinkCreateHint =
	"Create a link that lets anyone who holds it enter this exact room, and keeps working across server restarts until revoked. Anyone with the room link can enter and pass it on. It grants neither moderation nor message history.";
export const roomLinkSaveHint = "Save the IRC bridge's room link to return to this exact publication.";
export const roomLinkNoneHint =
	"This session holds no room link. A room manager can create one and share it with this session.";
export const roomLinkSaving = "Saving room link…";
export const roomLinkCreating = "Creating room link…";
export const roomLinkSave = "Save room link";
export const roomLinkCreate = "Create room link";
export const roomLinkHeldHint =
	"This room link reaches this exact room across restarts of the room server, until revoked. Anyone who has it can enter and pass it on. It doesn't grant moderation or keep message history.";
export const roomLinkRevoked = "Revoked the room link and its moderator link.";
export const roomLinkRevokeAsk = "Revoke link…";
export const roomAuthorityTitle = "Room authority";
export const roomAuthoritySubject = "Set the subject";
export const roomAuthoritySubjectHeld = "Held by this membership";
export const roomAuthoritySubjectNotOffered = "Not offered by this room";
export const roomAuthorityModerate = "Moderate membership";
export const roomAuthorityModerateHeld = "Held by this session";
export const roomAuthorityModerateRetained = "Retained, but not held on this connection";
export const roomAuthorityModerateViaManager = "Available through the held room manager";
export const roomAuthorityModerateNotHeld = "Not held by this session";
export const roomModeratorIssuing = "Issuing moderator link…";
export const roomModeratorTakingRetained = "Taking retained link…";
export const roomModeratorIssue = "Issue moderator link";
export const roomModeratorTakeRetained = "Take retained link";
export const roomModeratorTakeHint = "Paste the room moderator link somebody handed you.";
export const roomModeratorTaking = "Taking link…";
export const roomModeratorTakeCommit = "Take link";
export const roomModeratorKind = "Room moderator link";
export const roomModeratorHeldHint =
	"Anyone who holds this link can moderate this room. Share it only with somebody you want to moderate the room.";
export const roomModeratorDiscarded = "This session discarded its room moderator link.";
export const roomModeratorRevokedAll = "Revoked the room moderator link for everyone.";
export const roomModeratorDiscardAsk = "Discard moderator…";
export const roomModeratorRevokeAllAsk = "Revoke for everyone…";

/** Room moderation: asking somebody to leave, and unbridging. */
export const moderationKickHint =
	"Asking somebody to leave doesn't ban them. A room link or public room name still lets them return.";
export const moderationNobodyElse = "Nobody else is here right now.";
export const moderationKickAsk = "Ask to leave…";
export function moderationKickLabel(name: string): string {
	return `Ask ${name} to leave`;
}
export function moderationKickSay(name: string): string {
	return `Ask ${name} to leave the room? They can come back by its name or link.`;
}
export const moderationKicking = "Asking to leave…";
export const moderationKick = "Ask to leave";
export function moderationUnbridgeHint(badge: string): string {
	return `Unbridging closes every ${badge} seat and removes this room from the directory. The linked conversation itself stays as it is.`;
}
export function moderationUnbridgeLabel(badge: string): string {
	return `Unbridge this room from ${badge}`;
}
export const moderationUnbridging = "Unbridging…";
export const moderationUnbridge = "Unbridge room";
export const moderationMembers = "Members";
export const moderationBridgeLink = "Link";
export const moderationBridgeAuthority = "Authority";
export function moderationBridgeTitle(badge: string): string {
	return `${badge} bridge`;
}
export const roomBridgeDefault = "Bridge";
export const roomAboutTab = "About";
export const roomCapabilitiesTab = "Links";
export const roomModerationTab = "Moderation";
export function moderationBridgeAuthorityHeld(badge: string): string {
	return `${badge} gateway link held by this session`;
}
export function moderationUnbridgeFrom(badge: string): string {
	return `Unbridge from ${badge}…`;
}
