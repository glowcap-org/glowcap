// Who can manage or moderate a room, and what each act leaves standing.
//
// These are destructive acts with different reach, and the sentences say
// which. Discarding a capability this session holds is not the same as
// revoking one everybody holds, and a reader about to press one needs to know
// which they are pressing.

import { managedAccessText } from "./managed_access.ts";

/** What each of a room's three links does. Every place that describes a link
 * (the room card, its lead, the operator's card) draws these and adds only
 * what is particular to where it stands. */
const roomLinkPower =
	"The room link lets anyone who holds it enter this room and pass it on. It gives no moderation and no message history.";
export const managerLinkPower =
	"The manager link runs the room. Whoever holds it creates and revokes the room link and moderator link, and sets who may enter and speak.";
export const moderatorLinkPower = "The moderator link lets whoever holds it ask a member to leave.";

/** Why a link well, or `/link`, shows no link text: the page was opened under
 * an access that may not share links. Names the permission by its label. */
export const linksNotShownHere =
	`This page is not allowed to show links. Open it with the ${managedAccessText.shareCustody} permission to copy them.`;

/** Why the operator could not recover a room's manager link from here: the
 * detail of a refusal, so it carries no closing period, like its siblings. */
export const recoverManagerJoinFirst = "Join the room before recovering its manager link";

export const roomCapabilitiesTitle = "Room links";
/** The lead over the three sections. A reader who has just been handed a link
 * learns which power it carries and that it is taken here, in the room, with
 * no need to leave and come back in by link. */
export const roomCapabilitiesLead =
	`${roomLinkPower} ${managerLinkPower} ${moderatorLinkPower} To take a link someone shared with you, paste it below while you are in the room.`;

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
export const roomRevokeAuthority = "Revoke room link";
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
export const roomManagerTakeHint = managerLinkPower;
export const roomManagerTakeCommit = "Take manager link";
export const roomManagerRecoverHint =
	"This session also holds the directory operator link, which can recover management for this exact room.";
export const roomManagerRecover = "Recover manager link";
export const roomManagerSourceOwned =
	"This room's source owns its management link. This directory's operator can't create it.";
export const roomManagerHeldHint = `${managerLinkPower} This server's operator can recover a lost copy.`;
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
export const roomLinkCreateHint = `${roomLinkPower} It keeps working across server restarts until it is revoked.`;
export const roomLinkSaveHint = "Save the IRC bridge's room link to return to this exact publication.";
export const roomLinkNoneHint = "You don't hold this room's link. A room manager can create one and hand it to you.";
export const roomLinkHandedHint =
	"Someone handed you this room without its link, so you hold it only while this page stays open, and /invite hands it on the same way. A room manager can create a link that anyone can hold and keep.";
export const roomLinkSaving = "Saving room link…";
export const roomLinkCreating = "Creating room link…";
export const roomLinkSave = "Save room link";
export const roomLinkCreate = "Create room link";
export const roomLinkHeldHint = `${roomLinkPower} It keeps working across server restarts until it is revoked.`;
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
export const roomModeratorHeldHint = `${moderatorLinkPower} Share it only with somebody you want to moderate the room.`;
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
export const roomLinksTab = "Links";
export const roomModerationTab = "Moderation";
export function moderationBridgeAuthorityHeld(badge: string): string {
	return `${badge} gateway link held by this session`;
}
export function moderationUnbridgeFrom(badge: string): string {
	return `Unbridge from ${badge}…`;
}
