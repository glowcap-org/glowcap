// ── Domain types ───────────────────────────────────────────────────────────
// The app's own model. The wire-protocol types — Transport, Presence, and the
// room limits — live in lib/limits.ts.
//
// Everything here is a value. The store replaces records rather than mutating
// them, so React can tell one version from the next by identity, and so a piece
// of the page that did not change does not repaint.

// A chat line carries an optional send state for our own optimistic sends. A room
// line paints as "sending" and clears when the room echoes it back; a DM line clears
// when its direct send settles. A rejected send becomes "failed" (tinted, tap to
// retry). Absent means confirmed — every line we did not send ourselves, and every
// one of ours the wire has acknowledged.
export type SendState = "sending" | "failed";

/** One line in a conversation's history.
 *
 * `id` is minted by the store and is unique for the life of the tab. It is what
 * the log keys its rows on, and what the data layer holds to reach a line it
 * sent: `net.ts` names a message by id, never by a DOM node. */
export type Item =
	| {
		kind: "chat";
		id: number;
		from: string;
		text: string;
		mine: boolean;
		at: number;
		state?: SendState;
	}
	| { kind: "sys"; id: number; text: string; at: number }
	| { kind: "action"; id: number; from: string; text: string; at: number };
export type ChatItem = Extract<Item, { kind: "chat" }>;

/** Where a conversation stands with its reader.
 *
 * A count and the line the rule hangs on are one fact, not two, so they are one
 * value. Spelled as a number beside a nullable id, two of the four combinations
 * mean nothing — a count with nowhere to draw the rule, and a rule with no run
 * behind it — and both were reachable. Here neither is spellable. */
export type Unread =
	| { kind: "caught-up" }
	/** Read, but the rule is still up: you have just arrived and it says where
	 * you left off for a moment longer. */
	| { kind: "rule-only"; from: number }
	| { kind: "unread"; count: number; from: number };

export interface ConvBase {
	/** What to call this conversation. A room's name is also its key, because two
	 * clients naming the same room mean the same room. A member's nick is only a
	 * label: see `key`. */
	id: string;
	/** What this conversation *is*. A room is its name. A direct conversation is
	 * the introduction that opened it, and nothing else — two introductions to
	 * the same nick are two conversations, because a nick is a claim the room
	 * hands out and hands back, not a person. */
	key: string;
	/** Read-only to every holder: the store replaces this array rather than
	 * appending to it, which is how React tells one version from the next. */
	history: readonly Item[];
	unread: Unread;
}
// A conversation is either a public room or a direct message, and the two carry
// different state: a room has members, a DM has an introduction that is or is
// not yet live; both carry typing indicators. Modelling them as a discriminated
// union keeps each kind's fields off the other — a DM can't hold a member map,
// a room can't be "ready" — so the compiler enforces at every use what a mode
// flag would only ask a reader to remember.
export type Conv =
	| (ConvBase & {
		type: "room";
		members: ReadonlyMap<string, boolean>; // name -> online
		typers: ReadonlySet<string>; // nicks currently typing (auto-cleared by net.ts)
	})
	| (ConvBase & {
		type: "dm";
		line: DmLine;
		typers: ReadonlySet<string>; // the peer, while typing (auto-cleared by net.ts)
	});

/** Where a direct line stands.
 *
 * Closed is terminal, and that is the point of naming these three rather than
 * carrying two booleans: the room takes a member's nick back when they leave, so
 * a closed conversation can never become live again — a later holder of the name
 * is a different person. As two flags, "closed and live" was spellable, and an
 * arriving line on a conversation the directory had already closed could set it. */
export type DmLine = "introducing" | "live" | "closed";
export type RoomConv = Extract<Conv, { type: "room" }>;
export type DmConv = Extract<Conv, { type: "dm" }>;

/** How the foot of the sidebar reads the connection.
 *
 * This is the session and nothing else. What the application is doing — entering
 * a room, picking one, refusing a name — is a sentence beside it, not a phase:
 * carried in one field, "connecting" was being written over a healthy session
 * and the dot went amber while everything worked. */
export type SessionPhase = "connecting" | "connected" | "disconnected" | "reconnecting";
