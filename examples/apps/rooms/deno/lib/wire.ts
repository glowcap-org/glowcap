// The browser ↔ bridge WebSocket protocol, as zod schemas.
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

/** A presence change carried on a room line: the full roster, or one member coming
 * or going. */
export const Presence = z.union([
	z.object({ kind: z.literal("roster"), names: z.array(z.string()) }),
	z.object({ kind: z.enum(["join", "leave"]), name: z.string() }),
]);
export type Presence = z.infer<typeof Presence>;

/** Browser → bridge. Join (or switch) a room, say a line in the current room, open a
 * direct-message thread with a member, or say a line in one of those threads. */
export const Inbound = z.union([
	z.object({ join: z.object({ room: z.string(), nick: z.string() }) }),
	z.object({ say: z.string() }),
	z.object({ dmOpen: z.object({ to: z.string() }) }),
	z.object({ dmSay: z.object({ to: z.string(), text: z.string() }) }),
]);
export type Inbound = z.infer<typeof Inbound>;

/** Bridge → browser. The live room list and DM-able set, the tab's own DM identity,
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
	z.object({ from: z.string(), text: z.string(), presence: Presence.nullable() }),
]);
export type Outbound = z.infer<typeof Outbound>;
