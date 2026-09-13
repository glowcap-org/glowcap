// Presentation classification for structured room events.

/** Whether a room line is state and nothing to read: a bridge's seat update,
 * or a standing fact the room states on a line with no words of its own,
 * such as what it carries. The facts still fold into the conversation; only
 * the log is spared a blank system line. A line with words, files, presence
 * a reader should see, or one that names a line already posted (a withdrawal
 * is empty too) is a line. */
export function isStateOnlyRoomEvent(
	text: string,
	presence: { readonly kind: string } | null | undefined,
	attachments: readonly unknown[],
	change: string | null | undefined,
): boolean {
	if (text !== "" || attachments.length !== 0 || change != null) return false;
	return presence == null || presence.kind === "seat";
}
