// The attribution prefixes one room server has handed out, and who holds each.
//
// A bridged member's roster name is `irc/bo`: `bo` is a name in IRC's namespace
// and `irc/bo` is a name in the room's, and the prefix is the seam between them.
// That seam only holds while exactly one party decides who may claim what, and
// that party is the room server rather than any bridge. A namespace policed by
// its own members is not policed: a second bridge asking for a prefix that
// shadows the first one's members has to be refused by somebody who holds both.
//
// The reservation is doing all of the work here, because a nick may contain a
// slash. `nickRefusal` admits `irc/bo` as a perfectly ordinary Rooms name, so
// nothing about the shape of a name says whether it is one. Only a claim does.

import { MAX_SEAT_PREFIX } from "../limits.ts";

/** A prefix must end with its separator.
 *
 * Without one, a claim on `irc` would swallow a member called `ircfan` and show
 * them as somebody called `fan`. Requiring the separator makes a claim end at a
 * character no name can end a word on by accident, so what a prefix captures is
 * exactly what a bridge meant it to. */
const SEPARATOR = "/";

/** Prefixes fold the way names do, so a claim cannot be evaded by spelling. */
function fold(value: string): string {
	return value.toLowerCase();
}

export class BridgePrefixes {
	readonly #byPrefix = new Map<string, string>();

	/** Take a prefix for one holder, or say why not.
	 *
	 * Overlap in either direction is refused, not just an exact repeat: `irc/`
	 * and `irc/net/` would each capture names the other means to, and there is no
	 * reading of a roster where that is anything but two bridges claiming one
	 * person. A holder re-claiming what it already holds is not a collision. */
	claim(prefix: string, holder: string): string | null {
		if (prefix.length === 0) return "a bridge prefix may not be empty";
		if (prefix.length > MAX_SEAT_PREFIX) {
			return `a bridge prefix may be at most ${MAX_SEAT_PREFIX} characters`;
		}
		if (!prefix.endsWith(SEPARATOR)) return `a bridge prefix must end with "${SEPARATOR}"`;
		if (prefix.slice(0, -1).includes(SEPARATOR)) {
			return `a bridge prefix may only use "${SEPARATOR}" to end itself`;
		}
		const folded = fold(prefix);
		for (const [held, by] of this.#byPrefix) {
			if (by === holder) continue;
			if (folded.startsWith(held) || held.startsWith(folded)) {
				return `the prefix "${prefix}" overlaps one this server already granted`;
			}
		}
		for (const [held, by] of [...this.#byPrefix]) if (by === holder) this.#byPrefix.delete(held);
		this.#byPrefix.set(folded, holder);
		return null;
	}

	/** Give up whatever this holder took, so a bridge that goes away does not
	 * keep a namespace nobody can use. */
	release(holder: string): void {
		for (const [held, by] of [...this.#byPrefix]) if (by === holder) this.#byPrefix.delete(held);
	}

	/** Who has claimed the namespace this name sits in, or null when it is an
	 * ordinary name. Asked of every name a room is about to grant. */
	holderOf(name: string): string | null {
		const folded = fold(name);
		for (const [held, by] of this.#byPrefix) if (folded.startsWith(held)) return by;
		return null;
	}

	/** Why this name cannot be granted to a member, or null when it can.
	 *
	 * The one question a room asks before handing out a name. It is phrased for
	 * the person who typed it rather than for the operator: what they need to
	 * know is that the name is spoken for, not which bridge holds it. */
	nickRefusal(nick: string): string | null {
		const holder = this.holderOf(nick);
		return holder === null
			? null
			: `names beginning with "${this.prefixHeldBy(holder)}" are reserved for members bridged from elsewhere`;
	}

	/** The prefix one holder took, or the empty string when it took none. */
	prefixHeldBy(holder: string): string {
		for (const [held, by] of this.#byPrefix) if (by === holder) return held;
		return "";
	}

	get size(): number {
		return this.#byPrefix.size;
	}
}
