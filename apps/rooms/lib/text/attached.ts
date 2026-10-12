// What the shared-session code answers when a press cannot go through, and
// what it says in the log on its own: a room that closed under a control, a
// file that outlived its connection, a stream that skipped, a save the
// browser refused.
//
// A refusal here does the three jobs `failure.ts` names: what happened, what
// to do next, and the exact cause when one arrived.

/** A control pressed on a conversation that is no longer there. */
export const roomNoLongerOpen = "That room is no longer open.";
export const roomNoLongerInSession = "That room is no longer in this shared session.";
export const roomRecoveryInProgress = "You're already recovering this room.";
export const roomRecoveryNeedsLink = "Paste a current link for this private room.";
export const roomRecoveryFailed = "That room could not be recovered. It still needs an explicit rejoin.";
export const roomStillUnavailable = "That room is still unavailable.";
export const roomNoLongerAvailable = "That room is no longer available.";
export const conversationNoLongerOpen = "That conversation is no longer open.";
export const alreadyInRoom = "You are already in this room.";
export function offeredRoom(name: string): string {
	return `${name} has been offered this room.`;
}
export function roomLinkSaid(room: string, link: string): string {
	return `Anybody who holds this link can be in ${room}:\n  ${link}`;
}
export const notInRoomNow =
	"Not in this room at the moment. It is re-entered when the connection returns. Otherwise, open the room controls and restore access.";
export const lineAuthorityLost = "This shared session no longer holds authority over that line.";
export const joinDirectoryFirst = "Join a directory before starting a direct conversation.";

/** The archive. */
export const archiveOwnDurable = "The shared session is using its own durable archive.";
export const archiveNothingToShare = "This view has no archive to share.";
export const archiveNameReceiver = "Name the member who should receive this archive account.";
export const archiveSessionClosedReading = "The Rooms session closed while reading the shared archive.";
export const archiveShareConversationGone = "That shared archive's conversation is no longer open.";
export function archiveOfferNotDismissed(reason: string): string {
	return `History was added, but the shared-history offer could not be dismissed: ${reason}`;
}
export const archivedBytesUnavailable = "These archived file bytes are not available in this view.";
export const earlierConnectionBytesUnavailable =
	"This file belonged to an earlier connection and is no longer available.";
export const sharedArchivePeerLabel = "Shared session archive peer";

/** Which archive is holding the earlier messages a conversation shows. */
export const keeperPeerAndDevice = "Earlier messages kept by the shared Rooms session archive peer and on this device";
export const keeperPeerAndSession =
	"Earlier messages kept by the shared Rooms session archive peer and the shared Rooms session archive";
export const keeperPeer = "Earlier messages kept by the shared Rooms session archive peer";
export const keeperDevice = "Earlier messages, kept on this device";
export const keeperSession = "Earlier messages kept by the shared Rooms session archive";
export function sharedArchiveStanding(standings: string): string {
	return ` Standing recorded: ${standings}.`;
}
export function sharedArchiveDivider(from: string, source: string, generation: string, standing: string): string {
	return `Earlier messages shared by ${from}, recorded by archive source ${source}, conversation ${generation}. This is ${from}'s archive account, not live traffic.${standing}`;
}
export function sharedHistoryOffered(from: string): string {
	return `${from} shared read-only history. Open the conversation details to read it.`;
}

export const directoryListTruncated = "Its live room and peer list reached the shared snapshot limit.";
export const memberListTruncated = "Its member list reached the shared snapshot limit.";
export function ignoredButYou(name: string): string {
	return `${name} is on your ignore list. Your own messages stay shown.`;
}

/** Saving what this browser holds. */
export const bundleIncomplete = "That file is not a complete Rooms state bundle.";
export const bundleAndChoiceIncomplete = "That file and session choice do not form a complete Rooms state bundle.";
export const bundleSaveRefused =
	"The imported Rooms state wasn't saved, because your browser refused. Try the import again.";
export const noLongerInSharedSession = "You're no longer in a shared Rooms session in this browser.";
export function sessionChangedBut(why: string): string {
	return `The shared session changed, but ${why[0].toLowerCase()}${why.slice(1)}`;
}
export const capabilitySetSaveRefused =
	"The capability set changed, but your browser wouldn't save it. Press Save again before you reload.";
export const connectionChoiceSaveRefused =
	"The connection choice changed, but your browser wouldn't save it. Press Save again before you reload.";
export const nothingToShare = "You have no session of your own in this browser to share.";
export const localCopySaveRefused =
	"You're still in the shared session: your browser wouldn't save the switch to one of your own. Try again.";
export const leaveSessionRefused =
	"You're still in this Rooms session: your browser wouldn't save leaving it. Try again.";
export const forgetWorkspaceRefused = "Your saved workspace is still here: your browser wouldn't erase it. Try again.";
export const clearWorkspaceRefused =
	"Browser history was erased, but your saved Rooms workspace is still here. Press Delete browser data again.";

/** Files on a line. */
export function tooManyFiles(max: number): string {
	return `This message already carries ${max} files, which is as many as one can.`;
}
export function filesLeftOut(max: number, over: number): string {
	return `A message may carry at most ${max} files, so ${
		over === 1 ? "one file was" : `${over} files were`
	} left out. Send this one and the rest can follow.`;
}
/** A file pasted or dropped into a conversation that cannot carry one. The
 * log says it at that moment, because the attach control is absent there and
 * absence explains nothing. The bridge's badge names the reason when there is
 * one: "IRC" says why better than "this room" can. */
export function filesNotCarried(badge: string | null): string {
	return badge === null
		? "Files can't be sent to this room."
		: `Files can't be sent here. This room is on ${badge}, which carries text only.`;
}

/** Desktop notifications. */
export const notificationsUnsupported = "This browser can't show desktop notifications";
export const notificationsBlocked = "Notifications are blocked in your browser settings";
