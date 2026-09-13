// What the log draws for a line that is not plain words: an action somebody
// did, a notice somebody sent quietly, and the reports the slash commands say
// back into the conversation they ran in.

/** A `/me` line, drawn as something happening rather than something said. */
export function logActionLine(from: string, text: string): string {
	return `✻ ${from} ${text}`;
}

/** A `/notice` line, drawn the way every IRC client has drawn one: the author
 * kept, the notification given up. */
export function logNoticeLine(from: string, text: string): string {
	return `-${from}- ${text}`;
}

/** The opening line of `/help`, above the commands this conversation holds. */
export const helpYouCanUse = "You can use:";

/** One row of the `/directories` report. */
export function directoryReportLine(
	name: string,
	connected: boolean,
	nick: string,
	standing: string,
	rooms: number,
	joined: readonly string[],
	locator: string,
): string {
	const you = nick === "" ? "no name yet" : `you: ${nick}`;
	const where = standing === "" ? "here" : `away: ${standing}`;
	const inRooms = joined.length === 0 ? "in none of them" : `in ${joined.join(" ")}`;
	const advertised = `${rooms} ${rooms === 1 ? "room" : "rooms"} advertised`;
	return `${name}${connected ? "" : " (not connected)"}: ${you}, ${where}, ${advertised}, ${inRooms}\n  ${locator}`;
}

/** One row of the `/list` report. */
export function roomListLine(name: string, count: number | null): string {
	if (count === null) return `#${name}: occupancy unknown`;
	return `#${name}: ${count} ${count === 1 ? "person" : "people"}`;
}

/** The `/whois` answer: where they are, and whether a direct message reaches
 * them. */
export function whoisLine(name: string, here: string, reachable: boolean): string {
	return `${name}: ${here}, ${reachable ? "reachable for a direct message" : "not reachable directly"}`;
}

/** What a desktop notice says for a direct message that carried only a file. */
export const notifySentAFile = "sent a file";
