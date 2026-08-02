// Transport-neutral wire shapes the rooms app shares: the length caps a room
// enforces on names and lines, and the presence-change shape a room line
// carries. These belong to the room vocabulary, not to any one carrier, so the
// rendering layer (ui/) and the CapTP client (lib/room_client.ts) read them
// directly. (The JSON bridge and its schema were retired with the
// browser-peer page.)

/** Hard length caps a room enforces, so an oversize name or line is refused at
 * the edge instead of silently truncated (a lying path that delivered half a
 * line as if it were whole). */
export const MAX_NICK = 32;
export const MAX_ROOM = 32;
export const MAX_LINE = 8192;

/** How many direct-message inboxes one member will hold. Nothing withdraws a
 * host giftable, so each inbox a member offers costs a bootstrap row and an
 * export on every session it ever opens, for the life of the process. The peer
 * asking is the one who chose the name, so the count needs a ceiling that peer
 * cannot argue with. `max_dm_inboxes` in `cli/app/rooms_peer/common.zig` is the
 * same bound for the Zig peer. */
export const MAX_DM_INBOXES = 256;

/** How many WebRTC signaling exchanges the directory holds at once. An
 * exchange is transient scratch for one channel bring-up; the oldest is
 * evicted when the cap is hit, so a flood of offers cannot pin unbounded
 * routing rows. A candidate for an evicted exchange is dropped, which a
 * caller experiences as a failed dial, not a wedged directory. */
export const MAX_SIGNAL_EXCHANGES = 64;

/** How long a member may pause mid-draft before we stop telling the room they
 * are typing. */
export const TYPING_IDLE_MS = 4_000;

/** How long another member's typing flag stands, unrefreshed, before a reader
 * clears it themselves — the guard against a dropped "stopped" leaving an
 * indicator up for good.
 *
 * Derived rather than chosen, because the two are one decision. A reader has to
 * wait longer than a sender pauses: shorter, and the indicator would clear while
 * the sender still believes it is showing, then flick back on their next
 * keystroke. Written as a sum, raising the pause raises the wait with it, which
 * is the only relationship between them that has to hold. */
export const TYPING_CLEAR_MS = TYPING_IDLE_MS + 2_000;

/** Which transport a session holds to the room server, named for the UI so it
 * can label a direct-message path ("encrypted iroh QUIC" vs "a direct TCP
 * connection"). */
export type Transport = "tcp" | "iroh";

/** A presence change carried on a room line: the full roster, or one member
 * coming or going. */
export type Presence =
	| { kind: "roster"; names: string[] }
	| { kind: "join" | "leave"; name: string };
