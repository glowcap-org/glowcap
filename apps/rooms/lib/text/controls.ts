// The things you press, and what a screen reader calls them.
//
// Labels rather than prose, so there is little voice to get wrong. They are
// here for the other half of the catalog's job: one place to read the
// product's words, and one place a translator works from.

export const topicChange = "Change the topic";
export const topicClear = "Take the topic down";
export const jumpToLatest = "Jump to latest messages";
export const composerStopEditing = "Stop editing this message";
export const composerFilesOnLine = "Files on this line";
export const composerAttachedFiles = "Attached files";
export const composerAttach = "Attach a file";
export const composerEmoji = "Insert emoji";
export const showHiddenText = "Show hidden text";
export const taskStatus = "Task status";
export const themeToggle = "Toggle light or dark theme";
export const railToggleLabel = "Rooms and direct messages";
export const frontPage = "The front page";
export const yourRooms = "Your rooms";
export const dmMarkTitle = "Direct message";
export const dmRemove = "Remove this direct message";
export const dmSectionTitle = "Direct messages";
export const railFilterLabel = "What the rail shows";
export const messageStopFiles = "Stop sending these files";
export const messageRetry = "Retry failed message";
export const discardChangesTitle = "Discard unsaved changes?";
export const archiveShareCopy = "Copy the durable archive share";
export const archiveShareWith = "Share with";
export const archiveHistoryTitle = "Archive history";
export const avatarLabel = "Your avatar. You can't choose one yet.";
export const toastShow = "Show";
export const toastDismiss = "Dismiss";
export const noticesLabel = "Notices";
export const emojiLabel = "Emoji";
export const completionsLabel = "Completions";
export const messagesLabel = "Messages";
export const viewerLoading = "Loading";
export const modalClose = "Close";
export const standingHere = "Here";
export const standingAway = "Away";
export const standingReasonPlaceholder = "back in ten";
export const standingSay = "Say it";
export function standingFollow(what: string): string {
	return `Follow ${what}`;
}
/** The one act on a form whose saving reloads the window. */
export const saveAndReload = "Save and reload";
/** What a pasted capability looks like, shown in an empty field. */
export const sturdyrefPlaceholder = "ocapn://…/s/…";

/** The composer: whom the field addresses, the bar over an edit, and the
 * one button that sends, joins, or takes a message back. */
export function composerMessageDirectly(nick: string): string {
	return `Message ${nick} directly`;
}
export function composerMessageRoom(room: string): string {
	return `Message ${room}`;
}
export const composerCommandLike = "A command, like /help";
export const composerMessage = "Message";
export const composerCommand = "Command";
export const composerMessageUnavailable = "Message unavailable";
export const composerEmptiesLine = "Nothing left on this message: sending takes it back";
export const composerEditingFiles = "Editing this line's files";
export const composerEditingMessage = "Editing a message";
export const composerJoining = "Joining…";
export const composerRestoreAccess = "Restore access…";
export const composerJoin = "Join";
export const composerRetryJoining = "Retry joining";
export const composerTakeBack = "Take this message back";
export const composerSend = "Send";
export const commandKeyApple = "⌘";
export const commandKeyControl = "Ctrl";
/** The bar over a field on a directory that is not connected: the phase
 * word, then what became of the message. */
export function composerNotConnected(phase: string): string {
	return `${phase}. Your message was not sent.`;
}
