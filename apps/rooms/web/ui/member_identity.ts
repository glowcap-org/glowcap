// One reading of who a room member is across the roster, messages, mentions,
// and avatar. IRC-only participants carry the bridge's reserved `irc/`
// attribution in storage; linked participants remain one Rooms member with an
// IRC seat projected onto that membership.

import type { Standing } from "./types.ts";

// A stable per-name avatar tint, so every speaker keeps one colour. The ten
// values live in the rooms stylesheets as `--avatar-1` … `--avatar-10`, beside
// the rest of the palette. This module picks the slot; the stylesheet owns the
// colour.
const AVATAR_SLOTS = 10;

/** The bare nick behind a bridged IRC identity, or null for everyone else.
 *
 * `irc/` is the bridge's reserved attribution prefix (the bridge refuses it
 * as a Rooms name), so the test is exact. One authority for the question:
 * the roster, the message author line, mentions, and the avatar all ask here. */
export function ircName(name: string): string | null {
	return name.startsWith("irc/") && name.length > 4 ? name.slice(4) : null;
}

export function hueOf(name: string): string {
	// IRC origin has its own explicit badge. The avatar still belongs to the
	// person: hashing the bare nick keeps bridged people distinguishable instead
	// of painting an entire network as one person.
	const identity = ircName(name) ?? name;
	let h = 0;
	for (let i = 0; i < identity.length; i++) {
		h = (h * 31 + identity.charCodeAt(i)) >>> 0;
	}
	return `var(--avatar-${(h % AVATAR_SLOTS) + 1})`;
}

export type MemberNetwork = "rooms" | "irc" | "rooms-connecting" | "rooms-linked" | "rooms-failed";

export interface MemberIdentity {
	/** The name the row leads with. IRC-only roster keys carry an attribution
	 * prefix that is never part of the person's nick. */
	name: string;
	/** A compact origin mark, or null in an ordinary non-bridged room. */
	mark: "IRC" | "ROOMS" | "LINKING" | "LINKED" | "FAILED" | null;
	/** The network relationship said on the stable second line. Empty leaves
	 * that line to ordinary presence or an away reason. */
	said: string;
	network: MemberNetwork;
}

/** One network-identity reading for every roster surface. */
export function memberIdentity(name: string, standing: Standing): MemberIdentity {
	const bareIrc = ircName(name);
	if (bareIrc !== null) {
		return { name: bareIrc, mark: "IRC", said: "IRC only", network: "irc" };
	}
	const seat = standing.irc;
	if (seat === undefined) return { name, mark: null, said: "", network: "rooms" };
	switch (seat.state) {
		case "rooms":
			return { name, mark: "ROOMS", said: "Rooms only", network: "rooms" };
		case "connecting":
			return {
				name,
				mark: "LINKING",
				said: `Linking IRC as ${seat.nick}`,
				network: "rooms-connecting",
			};
		case "linked":
			return {
				name,
				mark: "LINKED",
				said: `Rooms + IRC as ${seat.nick}`,
				network: "rooms-linked",
			};
		case "failed":
			return {
				name,
				mark: "FAILED",
				said: `IRC link failed as ${seat.nick}`,
				network: "rooms-failed",
			};
	}
}

/** The stable second roster line. An ordinary room gives it to the actual
 * away reason; a bridged room says both the network relationship and reason. */
export function memberDetail(identity: MemberIdentity, standing: Standing): string {
	const away = standing.online && standing.away !== "";
	if (identity.said === "") return away ? standing.away : standing.online ? "online" : "offline";
	return away ? `${identity.said} · ${standing.away}` : identity.said;
}

export function initials(name: string): string {
	const identity = ircName(name) ?? name;
	const parts = identity.replace(/[^\p{L}\p{N} _-]/gu, "").split(/[ _-]+/).filter(Boolean);
	if (parts.length === 0) return "?";
	// By code point, not code unit: the nick rule admits letters of every
	// script, and `parts[0][0]` on an astral-plane letter is half a surrogate.
	const first = [...parts[0]][0];
	const second = parts[1] ? [...parts[1]][0] : "";
	return (first + second).toUpperCase();
}
