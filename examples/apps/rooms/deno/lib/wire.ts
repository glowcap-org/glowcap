// The browser-to-bridge WebSocket protocol, as zod schemas.
//
// This is the one place the JSON contract between the browser and web.ts is written
// down. Both ends validate against it and both ends take their types from it, so the
// wire shape and the TypeScript types can never drift apart: web.ts parses `Inbound`
// (untrusted input from the browser) and only ever sends `Outbound`; the browser
// parses `Outbound` and only ever sends `Inbound`. `z.infer` turns each schema into
// the type the code uses.
//
// It is deliberately small — a handful of tagged messages, no RPC framework. The
// capability protocol lives on the OCapN wire (`protocol.ts`); this is just the
// browser's transport into the bridge.

import { z } from "zod";

/** Which transport the bridge holds to the room server, echoed to the browser so it
 * can name the direct-message path ("encrypted iroh QUIC" vs "a direct TCP
 * connection"). */
export const Transport = z.enum(["tcp", "iroh"]);
export type Transport = z.infer<typeof Transport>;

/** Hard length caps for the browser-to-bridge JSON. Owned here so the schema rejects
 * oversize input instead of the bridge silently truncating (a lying path that
 * delivered half a line as if it were whole). */
export const MAX_NICK = 32;
export const MAX_ROOM = 32;
export const MAX_LINE = 8192;

/** Honest refuse reason for an inbound CapTP `dm` arg pair, or null if valid.
 * Callers must surface this (notice / error) — never silently drop. */
export function dmArgsRefuseNotice(from: string, text: string): string | null {
	if (from.length < 1 || from.length > MAX_NICK) {
		return `dm peer name too long (max ${MAX_NICK} characters)`;
	}
	if (text.length < 1 || text.length > MAX_LINE) {
		return `dm message too long (max ${MAX_LINE} characters)`;
	}
	return null;
}

const Nick = z.string().min(1).max(MAX_NICK);
const Room = z.string().min(1).max(MAX_ROOM);
const Line = z.string().min(1).max(MAX_LINE);

/** A presence change carried on a room line: the full roster, or one member coming
 * or going. */
export const Presence = z.union([
	z.object({ kind: z.literal("roster"), names: z.array(z.string()) }),
	z.object({ kind: z.enum(["join", "leave"]), name: z.string() }),
]);
export type Presence = z.infer<typeof Presence>;

/** Messages from the browser to the bridge. Join (or switch) a room, say a line in the current room, flag
 * whether we are typing in it, open a direct-message thread with a member, or say a
 * line in one of those threads. */
export const Inbound = z.union([
	z.object({ join: z.object({ room: Room, nick: Nick }) }),
	z.object({ say: Line }),
	z.object({ typing: z.boolean() }),
	z.object({ ping: z.literal(true) }), // liveness only; the bridge drops a silent tab
	z.object({ dmOpen: z.object({ to: Nick }) }),
	z.object({ dmSay: z.object({ to: Nick, text: Line }) }),
]);
export type Inbound = z.infer<typeof Inbound>;

/** Messages from the bridge to the browser. The live room list and DM-able set, the tab's own DM identity,
 * a join outcome, direct-message lifecycle events, a plain notice, or a room line
 * (`from`/`text`, with an optional presence change). */
export const Outbound = z.union([
	z.object({ rooms: z.array(z.tuple([z.string(), z.number()])) }),
	z.object({ dmable: z.array(z.string()) }),
	z.object({ dmSelf: z.object({ nick: z.string(), transport: Transport }) }),
	z.object({ nameTaken: z.string() }),
	z.object({ joined: z.string() }),
	z.object({ dmReady: z.object({ peer: z.string(), transport: Transport }) }),
	z.object({ dmFrom: z.object({ peer: z.string(), text: z.string() }) }),
	z.object({
		dmFailed: z.object({
			peer: z.string(),
			text: z.string().optional(),
			offline: z.boolean(), // the peer isn't registered (a typed signal, not a message)
		}),
	}),
	z.object({ notice: z.string() }),
	z.object({ typing: z.object({ from: z.string(), on: z.boolean() }) }),
	z.object({ from: z.string(), text: z.string(), presence: Presence.nullable() }),
]);
export type Outbound = z.infer<typeof Outbound>;
