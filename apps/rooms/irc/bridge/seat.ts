// What IRC calls the people in a bridged room: the ones holding a seat, and the
// ones who exist only over on IRC.
//
// A seat is a native Rooms member who also holds an IRC identity; a foreign
// member is somebody who has no Rooms membership at all. The room carries what
// state each is in. The words for both are IRC's own and live here, because a
// room server does not know what its bridge is, and a browser that spelled them
// itself would have to be rebuilt before a second bridge could say anything of
// its own.

import type { SeatPhase } from "../../lib/protocol_irc.ts";

export interface IrcSeatView {
	readonly network: string;
	readonly phase: SeatPhase;
	readonly nick: string;
}

/** What IRC calls one of its seats, and what it says about it.
 *
 * The badge stays short and upper-case because it rides in a chip beside a name
 * in a narrow rail. The sentence names the network and the nick over there,
 * because that is the pair a reader cannot get from the row itself. */
export function ircSeatWords(view: IrcSeatView): { badge: string; said: string } {
	switch (view.phase) {
		case "rooms":
			return { badge: "ROOMS", said: "Rooms only" };
		case "connecting":
			return { badge: "LINKING", said: `Linking ${view.network} as ${view.nick}` };
		case "linked":
			return { badge: "LINKED", said: `Rooms + ${view.network} as ${view.nick}` };
		case "failed":
			return { badge: "FAILED", said: `${view.network} link failed as ${view.nick}` };
	}
}

/** The attribution prefix an IRC-only member's roster name carries, and what
 * IRC calls one.
 *
 * A roster key of `irc/bo` is a name in the *room's* namespace and `bo` is a
 * name in IRC's; the prefix is what keeps the two apart, so a member on IRC
 * cannot take a Rooms member's name by picking it. The bridge refuses `irc/`
 * as a Rooms nick for the same reason.
 *
 * These three are said once per room rather than once per member, because they
 * are true of the bridge: every IRC-only member is IRC-only in the same way. */
export const IRC_PREFIX = "irc/";
export const IRC_FOREIGN_BADGE = "IRC";
export const IRC_FOREIGN_SAID = "IRC only";
