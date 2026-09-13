// The rail: the lists of rooms and direct messages, the field that names a
// new one, the filter over them, and the foot with the reader's own name.
//
// Most of these are what a control says aloud rather than what it shows,
// because the rail is dense and a screen reader gets no punctuation to tell
// two halves of a name apart. Moved here verbatim from the rail's components
// so the product's voice can be read in one place.

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

/** The filter over the rail. */
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
	return `${title}. Change what the rail shows. ${count}`;
}
export function filterChooseSaid(title: string): string {
	return `${title}. Choose what the rail shows. Nothing is hidden`;
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
/** The names are already a comma list, so the turn to where you are needs
 * the one separator a comma cannot be. */
export function footStandingLabel(who: string, said: string): string {
	return `${who} — where you are: ${said}`;
}
