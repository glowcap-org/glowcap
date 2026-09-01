// The names present on the IRC side of a bridged room.
//
// Two rosters meet in a bridged room and only one of them is this: the Rooms
// members are the bridge's own table, and these are the people on the channel
// who have no Rooms membership at all. Keeping them apart matters because they
// have different lifetimes — an IRC roster is scoped to one IRC connection and
// is dropped whole when that connection ends, while a Rooms member outlives it.
//
// This owns the table, its bound, and the folding that decides whether two
// spellings are one person. What it does not own is what anybody is told: every
// change answers with what happened and the room says it, because a line about
// somebody joining is the room's voice rather than a table's.

import { ircFold } from "../protocol.ts";
import { MAX_NICK, nickRefusal } from "../../lib/limits.ts";
import { IRC_PREFIX } from "./seat.ts";

/** How many IRC names one bridged room will carry.
 *
 * A channel larger than this is not refused; its roster is, because a room's
 * roster crosses the wire whole and an unbounded one is a channel choosing how
 * much memory every reader of the bridge spends. */
export const IRC_ROSTER_LIMIT = 256;

/** How an IRC nick is written as a name in the room's own namespace.
 *
 * The prefix is what keeps the two namespaces apart, and it is carried here
 * rather than spelled, so the name a roster shows and the name a bridge
 * reserves cannot drift into disagreeing.
 *
 * A name that will not fit is refused rather than shortened, because shortening
 * merges identities: two long IRC nicks would become one Rooms name, and the
 * room would show two people as one. */
export function displayIrcNick(nick: string): string {
	const display = `${IRC_PREFIX}${nick}`;
	if (display.length > MAX_NICK || nickRefusal(display) !== null) {
		throw new Error(`IRC nickname cannot be represented safely in Rooms: ${JSON.stringify(nick)}`);
	}
	return display;
}

export class IrcRoster {
	readonly #nicks = new Map<string, string>();

	get size(): number {
		return this.#nicks.size;
	}

	/** Every name, as written. */
	names(): string[] {
		return [...this.#nicks.values()];
	}

	/** Take one name. Answers the name as shown when it was not already here,
	 * and null when it was, so a caller announces an arrival exactly once. */
	add(nick: string): string | null {
		const display = displayIrcNick(nick);
		const folded = ircFold(display);
		if (this.#nicks.has(folded)) return null;
		if (this.#nicks.size >= IRC_ROSTER_LIMIT) throw new Error(`IRC roster exceeds ${IRC_ROSTER_LIMIT} names`);
		this.#nicks.set(folded, display);
		return display;
	}

	/** Drop one name, answering the name as it was shown, or null when this
	 * roster never had it. */
	remove(nick: string): string | null {
		const folded = ircFold(displayIrcNick(nick));
		const present = this.#nicks.get(folded);
		if (present === undefined) return null;
		this.#nicks.delete(folded);
		return present;
	}

	/** One name becoming another, answering both halves so the room can say a
	 * rename as the departure and arrival every client already draws. Null when
	 * this roster does not hold the old name. */
	rename(from: string, to: string): { was: string; now: string } | null {
		const was = this.#nicks.get(ircFold(displayIrcNick(from)));
		if (was === undefined) return null;
		this.#nicks.delete(ircFold(was));
		const now = displayIrcNick(to);
		this.#nicks.set(ircFold(now), now);
		return { was, now };
	}

	/** Take a whole roster in place of this one, which is what a channel's own
	 * NAMES reply is: a statement of everybody, not a change to anybody. */
	replace(next: ReadonlyMap<string, string>): void {
		this.#nicks.clear();
		for (const [folded, nick] of next) this.#nicks.set(folded, nick);
	}

	/** Forget everybody. Answers whether there was anybody, so a connection
	 * ending twice does not announce an empty roster twice. */
	clear(): boolean {
		if (this.#nicks.size === 0) return false;
		this.#nicks.clear();
		return true;
	}
}
