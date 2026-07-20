import type { Conv, Item } from "./types.ts";
import type { Transport } from "../../lib/limits.ts";

// ── State ────────────────────────────────────────────────────────────────
// Conversations, keyed "room:<name>" or "dm:<peer>". Each holds its own message
// history, so switching between a room and a direct message never loses either.
export const convs = new Map<string, Conv>();
// The scalars read and written across modules. ES module bindings can't be
// reassigned from another module, so the cross-module mutable state lives on one
// shared object every module reads and writes through.
export const state = {
	activeKey: null as string | null, // conversation shown, or null
	joinedRoom: "", // the room the server has us in (may not be active)
	nick: "", // our display name
	transport: "tcp" as Transport, // learned from the bridge
	membersHidden: false, // member-pane preference across room switches
};

export const liveRooms = new Map<string, number>(); // name -> member count (the directory)
export const dmablePeers = new Set<string>(); // nicks (lowercased) reachable for direct messages

// Small, swallow-errors localStorage wrapper (private-mode / disabled storage).
export const LS = {
	get(k: string): string | null {
		try {
			return localStorage.getItem(k);
		} catch {
			return null;
		}
	},
	set(k: string, v: string): void {
		try {
			localStorage.setItem(k, v);
		} catch { /* storage disabled (private mode); ignore */ }
	},
};

// ── Conversations ─────────────────────────────────────────────────────────
export function convKey(type: string, id: string): string {
	return type + ":" + id.toLowerCase();
}
export function getConv(key: string): Conv | null {
	return convs.get(key) || null;
}
export function activeConv(): Conv | null {
	if (!state.activeKey) return null;
	return convs.get(state.activeKey) ?? null;
}

export function makeConv(type: "room" | "dm", id: string): Conv {
	const key = convKey(type, id);
	const conv: Conv = {
		type,
		id,
		key,
		history: [],
		members: new Map(), // rooms only: name -> online
		typers: new Map(), // rooms only: nick -> auto-clear timer handle
		unread: 0,
		noted: false, // dm only: whether the provenance note has been shown
		ready: false, // dm only: introduction confirmed live
	};
	convs.set(key, conv);
	return conv;
}
export function ensureRoom(name: string): Conv {
	return getConv(convKey("room", name)) || makeConv("room", name);
}
export function ensureDm(peer: string): Conv {
	const existing = getConv(convKey("dm", peer));
	if (existing) return existing;
	const conv = makeConv("dm", peer);
	conv.id = peer; // keep the casing the peer arrived with
	return conv;
}

// ── Message items ─────────────────────────────────────────────────────────
// Each conversation stores plain item records; the log is painted from them, so
// switching conversations re-renders rather than losing history.
export function chatItem(from: string, text: string, mine: boolean): Item {
	return { kind: "chat", from, text, mine, at: Date.now() };
}
export function sysItem(text: string): Item {
	return { kind: "sys", text, at: Date.now() };
}
export function noteItem(head: string, body: string): Item {
	return { kind: "note", head, body, at: Date.now() };
}
