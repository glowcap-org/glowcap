// The screen a person meets after something went wrong mid-change.
//
// The reader has just had a crash and has a decision to make. The decision is
// small: something you started may or may not have gone through, Rooms cannot
// check, so either say it did or drop it. The sentences here say that.

export function recoveryTitle(count: number): string {
	return count === 1 ? "Unfinished change" : "Unfinished changes";
}

export function recoveryLead(count: number): string {
	if (count === 0) return "There are no unfinished changes to review.";
	return count === 1
		? "Something you started didn't finish, and Rooms can't tell whether it went through."
		: "Some things you started didn't finish, and Rooms can't tell whether they went through.";
}

export const recoveryKeep = "Go back";

/** Where an unfinished operation stands, as a chip. */
export const recoveryStatus: Record<"pending" | "committed" | "unknown" | "unsent" | "saving" | "working", string> = {
	pending: "Waiting for a reply",
	committed: "Went through",
	unknown: "Outcome unknown",
	unsent: "Not sent",
	saving: "Went through",
	working: "In progress",
};
/** What the act on a row does, said under its name. */
export const recoveryRowHint: Record<"pending" | "committed" | "unknown" | "unsent" | "saving" | "working", string> = {
	pending: "The other side has not answered yet. Pick it back up to keep waiting for it.",
	committed: "It went through. Finish to keep what it returned in this session.",
	unknown: "Rooms can't tell whether it went through. Pick it back up to resume waiting for the original reply.",
	unsent: "It never left this session.",
	saving: "It went through, and what it returned still needs saving here.",
	working: "Rooms is still working on this one. It waits here in case it stops.",
};
export const recoveryPickUp = "Pick back up";
export const recoveryLetGoAsk = "Let go…";
export const recoveryLetGo = "Let go";
export const recoveryLetGoLabel = "Let this go?";
/** What letting a row go costs, by where it stands. Nothing here is undone. */
export const recoveryLetGoSay: Record<"committed" | "unknown" | "unsent" | "saving", string> = {
	unknown:
		"Rooms stops asking and won't send it again. If it already went through, it stays done, and Rooms won't find out.",
	committed:
		"It went through, but what it returned won't be kept in this session. A room, link, or access it made won't be held here.",
	saving: "It went through, but this session won't save what it returned.",
	unsent: "It never went out. Rooms forgets it.",
};
/** Added for a send: where its words still are. */
export const recoveryLetGoSend = "Its words stay in the conversation, marked not confirmed.";
export const recoveryFinish = "Finish";
export const recoveryRetryUpdates = "Retry updates";
export const recoveryUpdatesStopped = (why: string): string =>
	`This list may be out of date because updates from the session stopped: ${why}`;

/** One retained operation in the reader's terms, from its original request. */
export function recoverySubject(
	name: string,
	args: readonly string[],
	conversation: (id: string) => string | null,
): string {
	const where = (id: string | undefined) => (id == null ? null : conversation(id));
	const quote = (text: string) => (text.length > 40 ? `“${text.slice(0, 39).trimEnd()}…”` : `“${text}”`);
	const inPlace = (text: string, id: string | undefined) => {
		const place = where(id);
		return place == null ? text : `${text} in ${place}`;
	};
	switch (name) {
		case "say":
			return inPlace(`Sending ${quote(args[1] ?? "")}`, args[0]);
		case "upload":
		case "sendFiles":
			return inPlace("Sending files", args[0]);
		case "editLine":
		case "refileLine":
			return inPlace("Changing a message", args[0]);
		case "withdrawLine":
			return inPlace("Taking back a message", args[0]);
		case "openManagedRoom":
			return `Creating ${args[1] ?? "a room"}`;
		case "startDirect":
			return `Starting a conversation with ${args[1] ?? "someone"}`;
		case "acceptInvitation":
			return "Accepting an invitation";
		case "ensureRoomLink":
			return inPlace("Making a room link", args[0]);
		case "issueRoomModerator":
			return inPlace("Making a moderator link", args[0]);
		case "publishPeeredRoom":
			return `Listing ${args[1] ?? "a room"}`;
		default:
			return "An earlier change";
	}
}

export const recoveryOperationDetails = "Operation details";

/** The full list could not be read, so the list below is only what this tab
 * still holds and the count in the lead would be a guess. */
export function recoveryListUnread(failure: string): string {
	return `Rooms couldn't read the rest of this session's unfinished changes. ${failure}`;
}
