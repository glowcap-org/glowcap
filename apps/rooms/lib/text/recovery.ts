// The screen a person meets after something went wrong mid-change.
//
// It was written entirely about the session's own knowledge: "This durable
// change stopped before the session knew its final outcome", "Tell the session
// whether the outside action completed. It cannot tell from here", "Resume the
// recorded recovery path, or abandon it before it produces a result." Somebody
// reading that has just had a crash and now has to decide something, and none
// of it tells them what they are deciding.
//
// The decision is small once it is said plainly: something you started may or
// may not have gone through, Rooms cannot check, so either say it did or drop
// it. That is what these say.

export function recoveryTitle(count: number): string {
	return count === 1 ? "Unfinished change" : "Unfinished changes";
}

export function recoveryLead(count: number): string {
	return count === 1
		? "Something you started didn't finish, and Rooms can't tell whether it went through."
		: "Some things you started didn't finish, and Rooms can't tell whether they went through.";
}

/** Per row, what this one needs from the reader. `external` is the one Rooms
 * genuinely cannot check for itself, which is the whole reason this screen
 * exists rather than a retry. */
export const recoveryExternalHint =
	"Rooms can't check this one. If you know it went through, say so. Otherwise drop it.";
export const recoveryPreparedHint = "Pick this back up, or drop it before it does anything.";
export const recoveryResumeHint = "Pick this back up to finish it.";

export const recoveryConfirmLabel = "Resolve unfinished change";
export const recoveryConfirmAllLabel = "Resolve unfinished changes";
export const recoveryKeep = "Go back";

export const recoveryCommittedSay = "Only do this if you know it already went through. Rooms won't do it again.";
export const recoveryAbandonedSay = "Rooms will drop this. Anything that already happened stays as it is.";
export const recoveryCommittedAllSay = "Only do this if you know they already went through. Rooms won't do them again.";
export const recoveryAbandonedAllSay = "Rooms will drop these. Anything that already happened stays as it is.";

export const recoveryAbandonAllAsk = "Abandon all…";
export const recoveryMarkAllCompletedAsk = "Mark all completed…";
export const recoveryMarkCompletedAsk = "Mark completed…";
export const recoveryMarkDone = "It went through";
export const recoveryMarkAllDone = "They went through";
export const recoveryDrop = "Drop it";
export const recoveryDropAll = "Drop them";

/** What state a row is in, said as a state rather than as a phase name. */
export const recoveryPhaseUnresolved = "Needs an answer";
export const recoveryPhasePrepared = "Ready to resume";
export const recoveryPhaseCompleted = "Result recorded";
export const recoveryPhaseDefault = "Ready to finish";
