// A directory in words: how its connection reads, what it is called when it
// is the one this page came with, and what a surface says while the reader's
// access is paused. `web/ui/text.ts` composes these into the rows, captions,
// and foot lines; the words themselves live here so the product's voice can
// be read in one place.

/** What a surface says while this browser's access to the session is paused
 * and there is consequently nothing in it to show. Not that there is nothing
 * here: the session has stopped telling this browser what it holds. */
export const nothingWhilePaused = "Not shown while your access is paused.";

/** The one wording of each connection phase. Everything that says one in a
 * sentence lowercases this, so a row cannot read out the raw token while the
 * card about the same directory reads out the written phrase. */
export const phaseConnected = "Connected";
export const phaseConnecting = "Connecting…";
export const phaseReconnecting = "Reconnecting…";
export const phaseDisconnected = "Not connected";

/** Why direct messages cannot run on a directory that is not live, in the
 * same words the rail and the connection row already use. */
export function dmBlockedWhile(phaseWord: string): string {
	return `Not while this directory is ${phaseWord}`;
}

/** The directory this page came with, which a reader never chose, and the
 * fallback word for a transport-less designator too long to say. */
export const thisDirectoryName = "this directory";
export const peerFallback = "peer";

/** The foot's one word once a directory has granted a name. */
export const footHere = "here";

/** The heading the log puts above a day's first message. */
export const dayToday = "Today";
export const dayYesterday = "Yesterday";

/** How this page tells someone what they typed will not fit. One phrasing,
 * because it is one thing to say. */
export function tooLongSaid(noun: string, max: number, unit: string): string {
	return `${noun} too long (max ${max} ${unit})`;
}

/** Why a line from somebody else cannot be shown. Refused rather than cut,
 * because a sentence cut in half can say the opposite of what it said. */
export const lineFromNameTooLong = "A line arrived under a name longer than any this app grants, so it is not here.";
export function lineTooLong(from: string): string {
	return `${from} sent a line longer than this app will show, so it is not here.`;
}

/** The composer's counter, once a line is within a fifth of its cap. */
export function bytesOver(over: number, roomCap: boolean): string {
	return `${over} bytes too long${roomCap ? " for this room" : ""}`;
}
export function bytesLeft(left: number): string {
	return `${left} bytes left`;
}
