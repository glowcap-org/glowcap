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

/** Which transport a session holds to the room server, named for the UI so it
 * can label a direct-message path ("encrypted iroh QUIC" vs "a direct TCP
 * connection"). */
export type Transport = "tcp" | "iroh";

/** A presence change carried on a room line: the full roster, or one member
 * coming or going. */
export type Presence =
	| { kind: "roster"; names: string[] }
	| { kind: "join" | "leave"; name: string };
