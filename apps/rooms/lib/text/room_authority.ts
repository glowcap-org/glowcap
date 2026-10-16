// Who can manage or moderate a room, and what each act leaves standing.
//
// These are destructive acts with different reach, and the sentences say
// which. Discarding a capability this session holds is not the same as
// revoking one everybody holds, and a reader about to press one needs to know
// which they are pressing.

export const roomCapabilitiesTitle = "Room capabilities";

/** A bridged room has no manager capability to take, because the channel is not
 * this server's to manage. The sentence comes in three parts so the middle one
 * can be a link to the place to go. The component supplies the address. */
export const bridgeHasNoManagerLead = "The IRC bridge owns entry and moderator authority. Administer the channel in";
export const bridgeHasNoManagerLink = "IRC operations";
export const bridgeHasNoManagerAfter = ".";
export const roomManagerTake = "Take a shared room manager capability";
export const roomManagerCopy = "Copy the room manager capability";
export const roomManagerDiscard = "Discard room manager capability";
export const roomLinkCopy = "Copy this room's durable link";
export const roomLinkRevoke = "Revoke this room entry link";
export const roomModeratorTake = "Take a shared room moderator capability";
export const roomModeratorCopy = "Copy the room moderator capability";
export const roomModeratorDiscard = "Discard room moderator capability";
export const roomModerationRevokeAll = "Revoke room moderation for everyone";
export const roomManagerDiscardSay = "This session gives up its manager capability. Other copies still work.";
export const roomNameReleaseSay =
	"The public name is released, and so is the way in that goes with it. The room, the people in it, and the capabilities you hold all stay. You can register the room again by changing its access.";
export const roomLinkRevokeSay =
	"This link and the current moderator capability stop working for everyone right away. People already in the room stay in, and you can make new ones afterwards.";
export const roomModeratorDiscardSay =
	"This session gives up its moderator capability. Other copies still work, and you can take a current one again later.";
export const roomModerationRevokeAllSay =
	"Every copy stops moderating this room right away, including ones already in use. The room link and the people in the room stay.";
export const roomKeepManagement = "Keep management";
export const roomKeepRegistration = "Keep registration";
export const roomKeepLink = "Keep link";
export const roomKeepCapability = "Keep capability";
export const roomDiscardCapability = "Discard capability";
export const roomReleaseName = "Release registered name";
export const roomRevokeAuthority = "Revoke room authority";
export const roomRevokeModerator = "Revoke moderator capability";
export const roomModerationTitle = "Room moderation";
export const roomUnbridgeSay = "Unbridge this room? Every connection closes and the room leaves this server.";
export const roomKeepHere = "Keep here";
export const roomKeepBridge = "Keep bridge";

/** The room card's three sections: management, the entry link, and
 * moderation. */
export function roomAccessNow(preset: string): string {
	return `Room access is now ${preset}.`;
}
export const roomCapabilityWait = "Wait for the room capability operation to finish.";
export const roomManagementTitle = "Room management";
export const roomManagerTakeHint =
	"This manages this room's durable link and moderator capability. It does not grant entry or moderation by itself.";
export const roomManagerTakeCommit = "Take manager capability";
export const roomManagerRecoverHint =
	"This session also holds the directory operator capability, which can recover management for this exact room.";
export const roomManagerRecover = "Recover manager capability";
export const roomManagerSourceOwned =
	"This room's source owns its management capability. This directory's operator cannot create it.";
export const roomManagerHeldHint =
	"Manages the entry link and moderator. It does not grant entry or moderation. Sharing it delegates management. The directory operator can recover a lost copy.";
export const roomManagerDiscarded = "This session discarded its room manager capability.";
export function roomNameReleaseLabel(room: string): string {
	return `Release the registered name #${room}`;
}
export function roomNameReleased(room: string): string {
	return `Released the registered room name #${room}.`;
}
export const roomManagerDiscardAsk = "Discard manager…";
export const roomNameReleaseAsk = "Release registered name…";
export const roomLinkTitle = "Room entry link";
export const roomLinkCreateHint =
	"Create durable bearer authority to enter this exact room across server restarts. Anyone with the entry link can enter and pass it on. It grants neither moderation nor history.";
export const roomLinkSaveHint = "Save the IRC bridge's source-owned entry link to return to this exact publication.";
export const roomLinkNoneHint =
	"This session holds no room entry link. A room manager can create one and share it with this session.";
export const roomLinkSaving = "Saving entry link…";
export const roomLinkCreating = "Creating entry link…";
export const roomLinkSave = "Save entry link";
export const roomLinkCreate = "Create entry link";
export const roomLinkHeldHint =
	"This durable bearer link reaches this exact room across restarts of the room server. Anyone who has it can enter and pass it on. It does not grant moderation or keep message history.";
export const roomLinkRevoked = "Revoked the room entry link and its moderator capability.";
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
export const roomModeratorIssuing = "Issuing moderator capability…";
export const roomModeratorTakingRetained = "Taking retained capability…";
export const roomModeratorIssue = "Issue moderator capability";
export const roomModeratorTakeRetained = "Take retained capability";
export const roomModeratorTakeHint = "Paste the room moderator sturdyref somebody handed you.";
export const roomModeratorTaking = "Taking capability…";
export const roomModeratorTakeCommit = "Take capability";
export const roomModeratorKind = "Room moderator capability";
export const roomModeratorHeldHint =
	"This is bearer authority to moderate this room. Share it only with somebody you want to moderate the room.";
export const roomModeratorDiscarded = "This session discarded its room moderator capability.";
export const roomModeratorRevokedAll = "Revoked the room moderator capability for everyone.";
export const roomModeratorDiscardAsk = "Discard moderator…";
export const roomModeratorRevokeAllAsk = "Revoke for everyone…";

/** Room moderation: asking somebody to leave, and unbridging. */
export const moderationKickHint =
	"Asking somebody to leave does not ban them. A room entry link or public room name still lets them return.";
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
export const roomCapabilitiesTab = "Capabilities";
export const roomModerationTab = "Moderation";
export function moderationBridgeAuthorityHeld(badge: string): string {
	return `${badge} gateway capability held by this session`;
}
export function moderationUnbridgeFrom(badge: string): string {
	return `Unbridge from ${badge}…`;
}
