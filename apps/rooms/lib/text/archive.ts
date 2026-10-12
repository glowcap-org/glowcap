// Archive history on a conversation card: handing somebody a read-only copy
// of what your archive kept, and the accounts others have handed you.
//
// A share is a capability that travels over a direct message. It goes to one
// person, reaches nothing else of yours, and either lasts for the conversation
// or is a link they keep.

export const archiveDoorWhat = "What you kept";
export function archiveDoorOffered(waiting: number): string {
	return waiting === 1 ? "1 offered" : `${waiting} offered`;
}
export const archiveDoorHintOffered = "Somebody has offered you a read-only account, and you can hand one over too.";
export const archiveDoorHint = "Hand one member a read-only copy of what your archive kept.";
export const archiveDoorOpen = "Archive history…";

/** What an incoming share is, from how long it lasts and what it holds. */
export function archiveOfferedSaid(custody: string, kind: string, scope: string | null): string {
	const room = scope ?? "a room";
	if (custody === "durable") {
		return kind === "standing"
			? "offered a durable standing"
			: kind === "room"
			? `offered a durable account of ${room}`
			: "offered a durable account";
	}
	return kind === "standing"
		? "offered a read-only standing"
		: kind === "room"
		? `offered a read-only account of ${room}`
		: "offered a read-only account";
}
export function archiveDiscardLabel(from: string): string {
	return `Discard the account ${from} offered`;
}
export function archiveDiscardSay(from: string): string {
	return `This lets go of what ${from} handed over. Offering it again is theirs to do.`;
}
export const archiveDiscardKeep = "Keep it";
export const archiveDiscardCommit = "Discard";
export const archiveDiscardAsk = "Discard…";
export const archiveReading = "Reading…";
export const archiveRead = "Read shared history";
export const archiveReadFull = "Finish another archive action before reading this share";
export const archiveDropFull = "Finish another archive action before discarding this share";

/** Handing one over. */
export function archiveDmLead(nick: string): string {
	return `Hand ${nick} a read-only copy of what your archive kept of this conversation. It reaches nothing else you have.`;
}
export const archiveRoomLead =
	"A room keeps no past of its own. What you have of this one is yours, and you can hand a read-only copy of it to one member over a direct line. It does not put them in the room.";
export const archivePeerHintNobody =
	"Nobody in this room can receive one yet. It travels over a direct message, and that needs a member who has registered for them here.";
export const archivePeerHint =
	"A member's nickname. It travels over a direct message, so it goes to one person and reaches nothing else of yours.";
export const archiveWhatTitle = "What to hand over";
export const archiveWhatLine = "What was said here";
export const archiveWhatLineSaid = "The messages from this room that your archive kept.";
export const archiveWhatStanding = "Where you stood";
export const archiveWhatStandingSaid = "When you were here and when you were away, and nothing that was said.";
export const archiveLastingTitle = "How long they have it";
export const archiveLastingOnce = "This once";
export const archiveLastingOnceDm = "They read it over this conversation, and it goes when that closes.";
export const archiveLastingOnceRoom = "They read it over the line you hand it on, and it goes when that closes.";
export const archiveLastingKept = "A link they keep";
export const archiveLastingKeptSaid = "They can come back to it later, and you can take it back at any time.";
export const archiveHanding = "Handing over…";
export const archiveHand = "Hand it over";
export function archiveSharedWith(nick: string): string {
	return `Shared with ${nick}.`;
}
