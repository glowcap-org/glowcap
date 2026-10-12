// One reading of who a room member is across the roster, messages, mentions,
// and avatar.
//
// A member bridged from elsewhere carries their bridge's attribution prefix in
// the roster key. One who is linked stays a single Rooms member with a seat
// projected onto that membership. Which prefix, and what to call either of
// them, is the room's to say and this module's to read.

import type { BridgeFacts, Standing } from "./types.ts";

// A stable per-name avatar tint, so every speaker keeps one colour. The ten
// values live in the rooms stylesheets as `--avatar-1` … `--avatar-10`, beside
// the rest of the palette. This module picks the slot. The stylesheet owns the
// colour.
const AVATAR_SLOTS = 10;

/** The name behind an attribution prefix, or null when this row carries none.
 *
 * The prefix is the room's own, declared on its bridge facts, so this module no
 * longer knows that `irc/` was ever one. A room that declared nothing has no
 * foreign members to find, which is the ordinary case and answers null without
 * looking at the name at all.
 *
 * One authority for the question: the roster, the message author line, mentions,
 * and completion all ask here. */
export function foreignName(name: string, bridge: BridgeFacts | undefined): string | null {
	if (bridge === undefined) return null;
	const { prefix } = bridge;
	return name.startsWith(prefix) && name.length > prefix.length ? name.slice(prefix.length) : null;
}

export function hueOf(name: string): string {
	// The name as a reader sees it, which for a bridged member is the one they go
	// by over there rather than the row's key. Callers hand in the shown name for
	// that reason: hashing a key would paint an entire network as one person, and
	// this has no way to tell a key from a name any more.
	let h = 0;
	for (let i = 0; i < name.length; i++) {
		h = (h * 31 + name.charCodeAt(i)) >>> 0;
	}
	return `var(--avatar-${(h % AVATAR_SLOTS) + 1})`;
}

/** How a member's relationship to a bridge is drawn. `foreign` is somebody who
 * exists only over there. The rest are a native member's link states. These are
 * the page's own classes rather than a bridge's words. */
export type MemberNetwork = "rooms" | "foreign" | "rooms-connecting" | "rooms-linked" | "rooms-failed";

export interface MemberIdentity {
	/** The name the row leads with. A bridged member's roster key carries an
	 * attribution prefix that is never part of the name they go by. */
	name: string;
	/** The badge beside the name, or null in an ordinary non-bridged room.
	 *
	 * A bridge writes its own, so this is not a closed set: `IRC` is what the
	 * IRC bridge happens to call itself, not a value this module knows. It is
	 * bounded on the wire (`MAX_SEAT_BADGE`) and drawn as text. */
	mark: string | null;
	/** The network relationship said on the stable second line. Empty leaves
	 * that line to ordinary presence or an away reason. */
	said: string;
	network: MemberNetwork;
}

/** How each link state is drawn. The state is the room's fact and the styling
 * is the page's, so this pairing stays here. Only the words came from the
 * bridge. */
const SEAT_NETWORKS = {
	rooms: "rooms",
	connecting: "rooms-connecting",
	linked: "rooms-linked",
	failed: "rooms-failed",
} as const satisfies Record<NonNullable<Standing["seat"]>["state"], MemberNetwork>;

/** One network-identity reading for every roster surface. */
export function memberIdentity(
	name: string,
	standing: Standing,
	/** The room's bridge facts, or undefined in a room with no bridge. Required
	 * rather than optional: a caller that forgot it would draw a foreign member
	 * under their row's key with no badge, and that compiles. */
	bridge: BridgeFacts | undefined,
): MemberIdentity {
	const foreign = bridge === undefined ? null : foreignName(name, bridge);
	if (foreign !== null && bridge !== undefined) {
		// Somebody who exists only over there. Their badge and sentence are the
		// bridge's, said once for the room rather than once for each of them,
		// because every foreign member of one bridge is foreign the same way.
		return { name: foreign, mark: bridge.badge, said: bridge.said, network: "foreign" };
	}
	const seat = standing.seat;
	if (seat === undefined) return { name, mark: null, said: "", network: "rooms" };
	// The badge and the sentence are the bridge's, carried on the seat rather
	// than written here. What stays is the link state, because that is what the
	// page styles on and what a reader's eye reads as a state rather than as a
	// word: connecting, linked, and failed look different from each other on
	// every bridge, and a bridge does not get to choose that.
	return { name, mark: seat.badge, said: seat.said, network: SEAT_NETWORKS[seat.state] };
}

/** The line under a name, where there is one to draw.
 *
 * The pip on the member's own chip already says they are here, so a plain
 * member who is gets nothing: a column of rows each repeating "online" under a
 * filled dot is a word-column standing where the names are, and the names are
 * what a reader came to scan. What earns the line is what the pip cannot say (
 * the reason somebody stepped away, the network they are reachable on) and
 * being gone, which the pip says only by not being filled and the row says
 * only by fading, both quiet enough that the word still carries its weight.
 *
 * Nothing is lost by leaving it out: the pip is an `img` labelled with the
 * state, so it is announced either way. And the row keeps its height, so a
 * roster does not reflow when somebody steps away. A name with nothing under
 * it stands in the middle of the space instead. */
export function memberDetail(identity: MemberIdentity, standing: Standing): string {
	const away = standing.online && standing.away !== "";
	if (identity.said === "") {
		if (away) return standing.away;
		return standing.online ? "" : "offline";
	}
	return away ? `${identity.said} · ${standing.away}` : identity.said;
}

export function initials(name: string): string {
	const parts = name.replace(/[^\p{L}\p{N} _-]/gu, "").split(/[ _-]+/).filter(Boolean);
	if (parts.length === 0) return "?";
	// By code point, not code unit: the nick rule admits letters of every
	// script, and `parts[0][0]` on an astral-plane letter is half a surrogate.
	const first = [...parts[0]][0];
	const second = parts[1] ? [...parts[1]][0] : "";
	return (first + second).toUpperCase();
}
