// Current room membership as reduced from structured presence events.

import {
	MAX_AWAY,
	MAX_NICK,
	MAX_ROOM,
	MAX_ROOM_OFFLINE,
	MAX_ROSTER_SEEN,
	MAX_SEAT_BADGE,
	MAX_SEAT_SAID,
} from "../limits.ts";
import type { SeatPhase } from "../protocol_irc.ts";
import { boundedText, nonemptyText } from "../schema.ts";
import * as z from "zod/mini";

export const SEAT_PHASES = ["rooms", "connecting", "linked", "failed"] as const satisfies readonly SeatPhase[];

export const PresenceSchema = z.union([
	z.strictObject({ kind: z.literal("typing"), name: nonemptyText(MAX_NICK), on: z.boolean() }),
	z.strictObject({
		kind: z.literal("roster"),
		names: z.array(nonemptyText(MAX_NICK)).check(z.maxLength(MAX_ROSTER_SEEN)),
	}),
	z.strictObject({ kind: z.enum(["join", "leave"]), name: nonemptyText(MAX_NICK) }),
	z.strictObject({
		kind: z.literal("offline"),
		names: z.array(nonemptyText(MAX_NICK)).check(z.maxLength(MAX_ROOM_OFFLINE)),
	}),
	z.strictObject({ kind: z.literal("away"), name: nonemptyText(MAX_NICK), reason: boundedText(MAX_AWAY) }),
	z.strictObject({
		kind: z.literal("seat"),
		name: nonemptyText(MAX_NICK),
		state: z.enum(SEAT_PHASES),
		nick: nonemptyText(MAX_NICK),
		network: nonemptyText(MAX_ROOM),
		/** What the bridge calls this seat, and what it says about it. The
		 * bridge writes both: a room server does not know what its bridge is,
		 * and the words belong to whoever does. */
		badge: nonemptyText(MAX_SEAT_BADGE),
		said: nonemptyText(MAX_SEAT_SAID),
	}),
]);

export type Presence = z.infer<typeof PresenceSchema>;

export const RoomMemberStateSchema = z.strictObject({
	online: z.boolean(),
	away: boundedText(MAX_AWAY),
	/** The foreign seat this member holds, when a bridge has said they hold one.
	 *
	 * `badge` and `said` are the bridge's words for it, carried and not
	 * derived, so a second bridge reads as itself and not as IRC under another
	 * name. `network`, `state`, and `nick` are the room's facts about the seat
	 * and are not the bridge's to word. */
	seat: z.optional(z.strictObject({
		network: nonemptyText(MAX_ROOM),
		state: z.enum(SEAT_PHASES),
		nick: nonemptyText(MAX_NICK),
		badge: nonemptyText(MAX_SEAT_BADGE),
		said: nonemptyText(MAX_SEAT_SAID),
	})),
});

export type RoomMemberState = z.infer<typeof RoomMemberStateSchema>;

export function applyRoomPresence(
	current: ReadonlyMap<string, RoomMemberState>,
	event: Presence,
): Map<string, RoomMemberState> {
	if (event.kind === "typing") return current as Map<string, RoomMemberState>;
	if (event.kind === "seat" && !current.get(event.name)?.online) return new Map(current);
	const members = new Map(current);
	const standing = (name: string): RoomMemberState => members.get(name) ?? { online: false, away: "" };
	if (event.kind === "roster") {
		const present = new Set(event.names);
		for (const [name, was] of members) {
			if (present.has(name)) members.set(name, { online: true, away: was.away });
			else members.delete(name);
		}
		for (const name of event.names) members.set(name, { ...standing(name), online: true });
	} else if (event.kind === "seat") {
		members.set(event.name, {
			...standing(event.name),
			seat: {
				network: event.network,
				state: event.state,
				nick: event.nick,
				badge: event.badge,
				said: event.said,
			},
		});
	} else if (event.kind === "away") {
		if (!members.get(event.name)?.online) return members;
		members.set(event.name, { ...standing(event.name), away: event.reason });
	} else if (event.kind === "leave") {
		members.delete(event.name);
	} else if (event.kind === "offline") {
		for (const name of event.names) members.set(name, { online: false, away: "" });
	} else {
		members.set(event.name, { online: true, away: "" });
	}
	if (members.size > MAX_ROSTER_SEEN) {
		for (const [name, row] of members) {
			if (members.size <= MAX_ROSTER_SEEN) break;
			if (!row.online) members.delete(name);
		}
	}
	return members;
}
