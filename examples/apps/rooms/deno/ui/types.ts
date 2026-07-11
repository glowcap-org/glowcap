// ── Domain types ───────────────────────────────────────────────────────────
// The app's own model. The wire-protocol types — Transport, Presence, and the
// message shapes — live in lib/wire.ts, sourced from the zod schemas.
//
// One line in a conversation's history. The log is painted from these records, so
// switching conversations re-renders rather than losing history.
export type Item =
	| { kind: "chat"; from: string; text: string; mine: boolean; at: number }
	| { kind: "sys"; text: string; at: number }
	| { kind: "action"; from: string; text: string; at: number }
	| { kind: "note"; head: string; body: string; at: number };
export type ChatItem = Extract<Item, { kind: "chat" }>;
export type SysItem = Extract<Item, { kind: "sys" }>;
export type NoteItem = Extract<Item, { kind: "note" }>;
export type ActionItem = Extract<Item, { kind: "action" }>;
export interface Conv {
	type: "room" | "dm";
	id: string;
	key: string;
	history: Item[];
	members: Map<string, boolean>; // rooms only: name -> online
	unread: number;
	noted: boolean; // dm only: whether the provenance note has been shown
	ready: boolean; // dm only: introduction confirmed live
}
