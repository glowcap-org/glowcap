// Current room membership as reduced from structured presence events.

import { MAX_AWAY, MAX_NICK, MAX_ROSTER_SEEN } from "./limits.ts";
import type { IrcSeatPhase } from "./protocol.ts";
import { boundedText, nonemptyText } from "./schema.ts";
import * as z from "zod/mini";

const IRC_SEAT_PHASES = ["rooms", "connecting", "linked", "failed"] as const satisfies readonly IrcSeatPhase[];

export const PresenceSchema = z.union([
	z.strictObject({ kind: z.literal("typing"), name: nonemptyText(MAX_NICK), on: z.boolean() }),
	z.strictObject({
		kind: z.literal("roster"),
		names: z.array(nonemptyText(MAX_NICK)).check(z.maxLength(MAX_ROSTER_SEEN)),
	}),
	z.strictObject({ kind: z.enum(["join", "leave"]), name: nonemptyText(MAX_NICK) }),
	z.strictObject({ kind: z.literal("away"), name: nonemptyText(MAX_NICK), reason: boundedText(MAX_AWAY) }),
	z.strictObject({
		kind: z.literal("irc-seat"),
		name: nonemptyText(MAX_NICK),
		state: z.enum(IRC_SEAT_PHASES),
		nick: nonemptyText(MAX_NICK),
	}),
]);

export type Presence = z.infer<typeof PresenceSchema>;

export const RoomMemberStateSchema = z.strictObject({
	online: z.boolean(),
	away: boundedText(MAX_AWAY),
	irc: z.optional(z.strictObject({
		state: z.enum(IRC_SEAT_PHASES),
		nick: nonemptyText(MAX_NICK),
	})),
});

export type RoomMemberState = z.infer<typeof RoomMemberStateSchema>;

export function applyRoomPresence(
	current: ReadonlyMap<string, RoomMemberState>,
	event: Presence,
): Map<string, RoomMemberState> {
	if (event.kind === "typing") return new Map(current);
	if (event.kind === "irc-seat" && !current.has(event.name)) return new Map(current);
	const members = new Map(current);
	const standing = (name: string): RoomMemberState => members.get(name) ?? { online: false, away: "" };
	if (event.kind === "roster") {
		for (const [name, was] of members) members.set(name, { online: false, away: was.away });
		for (const name of event.names) members.set(name, { ...standing(name), online: true });
	} else if (event.kind === "irc-seat") {
		members.set(event.name, { ...standing(event.name), irc: { state: event.state, nick: event.nick } });
	} else if (event.kind === "away") {
		if (!members.has(event.name)) return members;
		members.set(event.name, { ...standing(event.name), away: event.reason });
	} else {
		members.set(event.name, { online: event.kind === "join", away: "" });
	}
	if (members.size > MAX_ROSTER_SEEN) {
		for (const [name, row] of members) {
			if (members.size <= MAX_ROSTER_SEEN) break;
			if (!row.online) members.delete(name);
		}
	}
	return members;
}
