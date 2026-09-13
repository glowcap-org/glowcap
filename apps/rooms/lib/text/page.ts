// What the page says about itself: a part that broke, a copy that was
// refused, a file being chosen or loaded, a change about to be lost, and the
// small notices a shared session raises. Moved here verbatim from the
// components so the product's voice can be read in one place.

/** A part of the page failed, and the rest did not. */
export const crashTitle = "The page ran into a problem";
export const crashSessionKept = "Your session is not lost. The peer keeps running under this screen.";
export const crashReload = "Reload";
export const partSessionKept = "Your session is still open, so nothing has been lost.";
export const partTryAgain = "Try again";
export const partWentWrong = "Something in this part of the page went wrong.";
export function crashPartTitle(part: string): string {
	return `The ${part} ran into a problem`;
}

/** Product names as they appear in the lockup and browser title. */
export const brandName = "glowcap";
export const brandRooms = "rooms";
export const brandRoomsTitle = "glowcap rooms";

export const copyRefused = "Your browser would not let the page copy that.";
export const chooseAFile = "Choose a file";
export function loadingWhat(what: string): string {
	return `Loading ${what}`;
}
export const anotherAddress = "Another address…";
export const secretPromise = "Sent once, cleared here immediately, and never remembered.";
export const hostedSelectionRefused = "This browser could not save the shared session selection.";

/** Leaving a form with unsaved changes. */
export const unsavedLead = "Your unsaved changes will be lost. Keep editing, or discard them to continue.";
export const unsavedKeep = "Keep editing";
export const unsavedDiscard = "Discard changes";

/** The two notices a shared session can raise over the page. */
export const sessionEffectOne = "A session operation needs your decision.";
export function sessionEffectMany(count: number): string {
	return `${count} session operations need your decision.`;
}
export const sessionPausedSaid = "Your access to this shared session is paused.";
export function sessionPausedNote(note: string): string {
	return `Your access to this shared session is paused: ${note}`;
}

/** The file viewer and an attachment on a line. */
export function viewerFit(name: string): string {
	return `Fit ${name} to the window`;
}
export function viewerActualSize(name: string): string {
	return `Show ${name} at actual size`;
}
export function fileDownload(name: string): string {
	return `Download ${name}`;
}
export function fileRetry(name: string): string {
	return `Retry ${name}`;
}
export function filePlay(name: string): string {
	return `Play ${name}`;
}
export function viewerTryAgain(name: string): string {
	return `Try ${name} again`;
}
export function fileLoading(name: string): string {
	return `Loading ${name}`;
}
export function fileUploading(name: string): string {
	return `Uploading ${name}`;
}
export function fileDownloading(name: string): string {
	return `Downloading ${name}`;
}
export const attachmentRetry = "Retry";
export const attachmentPlay = "Play";
export const attachmentShow = "Show";
export function richTextImageLabel(alt: string, destination: string | null): string {
	return `Image: ${alt || destination || "attachment"}`;
}

/** The message stream. A dropped file joins the message being written, the
 * same as the clip button's act; nothing is sent until the reader sends. */
export const dropToAttach = "Drop to attach";
export const latestMessages = "Latest messages";

/** Who is typing. */
export function typingOne(first: string): string {
	return `${first} is typing…`;
}
export function typingTwo(first: string, second: string): string {
	return `${first} and ${second} are typing…`;
}
export function typingMore(first: string, second: string, more: number): string {
	return `${first}, ${second}, and ${more} more are typing…`;
}
