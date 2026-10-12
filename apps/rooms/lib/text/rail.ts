// The sidebar: the lists of rooms and direct messages, the field that names a
// new one, the filter over them, and the foot with the reader's own name.
//
// Most of these are what a control says aloud rather than what it shows. The
// sidebar is dense, and a screen reader gets no punctuation to tell two halves
// of a name apart.

/** The field that names a room, and the control beside it. */
export function railCreateOrOpenIn(where: string): string {
	return `Create or open a room in ${where}`;
}
export const railRoomNameNoun = "room name";
export const railRoomNamePlaceholder = "room name";
export function railChangeDirectory(noun: string, where: string): string {
	return `Change directory. This ${noun} is going in ${where}`;
}
export const railReachingDirectory = "Reaching a directory…";
export const railRoomsAppearHere = "Rooms you join appear here.";
export const railIn = "in";
export const railFrom = "from";
export const railChange = "Change";
export const railLeave = "Leave";
export const railNoRoomsYet = "no rooms yet";
export const railClosed = "closed";

/** Direct messages. */
export function dmOpenClosed(nick: string): string {
	return `Open the closed conversation with ${nick}`;
}
export function dmOpen(nick: string): string {
	return `Open direct message with ${nick}`;
}
export function dmOnDirectory(name: string): string {
	return ` on ${name}`;
}
export function dmRemoveSaid(nick: string): string {
	return `Remove the direct message with ${nick}`;
}
export const dmMessageAMember = "Message a member to start one.";
export const dmJoinARoomFirst = "Join a room to message someone from the roster.";
export const dmStart = "Start a direct message";
export const dmMemberNamePlaceholder = "member name";

/** The filter over the sidebar. */
export const filterNameLabel = "Name";
export const filterNamePlaceholder = "part of a name";
export const filterDirectoryLabel = "Directory";
export const filterAccessLabel = "Access";
export const filterPublic = "Public";
export const filterPrivate = "Private";
export const filterUnread = "Unread";
export const filterCaughtUp = "Caught up";
export const filterNothingToChoose = "Nothing to choose from yet";
export function filterChangeSaid(title: string, count: string): string {
	return `${title}. Change what the sidebar shows. ${count}`;
}
export function filterChooseSaid(title: string): string {
	return `${title}. Choose what the sidebar shows. Nothing is hidden`;
}
/** How much of the sidebar is on screen, as the two numbers alone. The heading
 * has room for these and not for a sentence. */
export function filterCount(shown: number, total: number): string {
	return `${shown} of ${total}`;
}
/** The same fact written out, for a reader who hears the name rather than
 * sees the badge. Both come from `filterCount`, so what is seen and what is
 * said match. */
export function filterCountSaid(shown: number, total: number): string {
	return `${filterCount(shown, total)} shown`;
}
export const filterShowEverything = "Show everything";

/** The foot. */
export const footAboutYou = "About you…";
export function footOtherNames(count: number): string {
	return `${count} ${count === 1 ? "name" : "names"}`;
}
export function footReleaseName(nick: string, where: string): string {
	return `Release ${nick} on ${where}`;
}
export function footReleasedName(nick: string, where: string): string {
	return `Released ${nick} on ${where}.`;
}
/** The names are already a comma list, so where you are starts a new
 * sentence, which a screen reader pauses on. */
export function footStandingLabel(who: string, said: string): string {
	return `${who}. Where you are: ${said}`;
}
