// ── Domain types ───────────────────────────────────────────────────────────
// The app's own model. The wire-protocol types — Transport, Presence, and the
// room limits — live in lib/limits.ts.
//
// One line in a conversation's history. The log is painted from these records, so
// switching conversations re-renders rather than losing history.
// A chat line carries an optional send state for our own optimistic sends. A room
// line paints as "sending" and clears when the room echoes it back; a DM line clears
// when its direct send settles. A rejected send becomes "failed" (tinted, tap to
// retry). Absent means confirmed — every line we did not send ourselves, and every
// one of ours the wire has acknowledged.
export type SendState = "sending" | "failed";
export type Item =
	| { kind: "chat"; from: string; text: string; mine: boolean; at: number; state?: SendState }
	| { kind: "sys"; text: string; at: number }
	| { kind: "action"; from: string; text: string; at: number };
export type ChatItem = Extract<Item, { kind: "chat" }>;
export type SysItem = Extract<Item, { kind: "sys" }>;
export type ActionItem = Extract<Item, { kind: "action" }>;

// A conversation is either a public room or a direct message, and the two carry
// different state: a room has members and typing indicators, a DM has an
// introduction that is or is not yet live. Modelling them as a discriminated
// union keeps each kind's fields off the other — a DM can't hold a member map,
// a room can't be "ready" — so the compiler enforces at every use what a mode
// flag would only ask a reader to remember.
interface ConvBase {
	/** What to call this conversation. A room's name is also its key, because two
	 * clients naming the same room mean the same room. A member's nick is only a
	 * label: see `key`. */
	id: string;
	/** What this conversation *is*. A room is its name. A direct conversation is
	 * the introduction that opened it, and nothing else — two introductions to
	 * the same nick are two conversations, because a nick is a claim the room
	 * hands out and hands back, not a person. */
	key: string;
	history: Item[];
	unread: number;
}
export type Conv =
	| (ConvBase & {
		type: "room";
		members: Map<string, boolean>; // name -> online
		typers: Map<string, ReturnType<typeof setTimeout>>; // nick -> auto-clear timer handle
	})
	| (ConvBase & {
		type: "dm";
		ready: boolean; // the introduction has been redeemed into a live direct line
		// The member this conversation was introduced to has gone. The name may
		// since have been taken by someone else and this side cannot tell, so the
		// conversation is closed rather than re-resolved: see `liveDmWith`.
		gone: boolean;
	});
export type RoomConv = Extract<Conv, { type: "room" }>;
export type DmConv = Extract<Conv, { type: "dm" }>;
