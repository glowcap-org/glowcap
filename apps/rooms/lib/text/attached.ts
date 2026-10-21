// What the shared-session code answers when a press cannot go through, and
// what it says in the log on its own: a room that closed under a control, a
// file that outlived its connection, a stream that skipped, a save the
// browser refused.
//
// A refusal here does the three jobs `failure.ts` names: what happened, what
// to do next, and the exact cause when one arrived.

export const conversationNoLongerOpen = "That conversation is no longer open.";
export const alreadyInRoom = "You are already in this room.";

export const archivedBytesUnavailable = "These archived file bytes are not available in this view.";
export const earlierConnectionBytesUnavailable =
	"This file belonged to an earlier connection and is no longer available.";

/** Which archive is holding the earlier messages a conversation shows.  status-allow: event or source ordering */
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

export function ignoredButYou(name: string): string {
	return `${name} is on your ignore list. Your own messages stay shown.`;
}

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
