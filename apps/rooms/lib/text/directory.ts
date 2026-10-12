// A directory in words: how its connection reads, what it is called when it
// is the one this page came with, and what a surface says while the reader's
// access is paused. `web/ui/text.ts` composes these into the rows, captions,
// and foot lines.

/** What a surface says while this browser's access to the session is paused.
 * The session has stopped telling this browser what it holds, so the surface
 * has nothing to show. */
export const nothingWhilePaused = "Not shown while your access is paused.";

/** The wording of each connection phase. A sentence that names a phase
 * lowercases these, so a row and the card for the same directory agree. */
export const phaseConnected = "Connected";
export const phaseConnecting = "Connecting…";
export const phaseReconnecting = "Reconnecting…";
export const phaseDisconnected = "Not connected";

/** Why direct messages cannot run on a directory that is not live. */
export function dmBlockedWhile(phaseWord: string): string {
	return `Not while this directory is ${phaseWord}`;
}

/** The directory this page came with, which a reader never chose, and the
 * fallback word for a transport-less designator too long to say. */
export const thisDirectoryName = "this directory";
export const peerFallback = "peer";

/** The foot's word once a directory has granted a name. */
export const footHere = "here";

/** The heading the log puts above a day's first message. */
export const dayToday = "Today";
export const dayYesterday = "Yesterday";

/** How this page tells someone what they typed will not fit. */
export function tooLongSaid(noun: string, max: number, unit: string): string {
	return `${noun} too long (max ${max} ${unit})`;
}

/** Why a line from somebody else cannot be shown. The page refuses it instead
 * of cutting it, since half a sentence can say the opposite. */
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
