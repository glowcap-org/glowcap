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

/** Which transport a session holds to the room server, named for the UI so it
 * can label a direct-message path ("encrypted iroh QUIC" vs "a direct TCP
 * connection"). */
export type Transport = "tcp" | "iroh";

/** A presence change carried on a room line: the full roster, or one member
 * coming or going. */
export type Presence =
	| { kind: "roster"; names: string[] }
	| { kind: "join" | "leave"; name: string };
