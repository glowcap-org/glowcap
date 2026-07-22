import type { ChatItem, Conv, DmConv, Item, RoomConv, SendState } from "./types.ts";

// ── State ────────────────────────────────────────────────────────────────
// Conversations, keyed "room:<name>" or "dm:<peer>". Each holds its own message
// history, so switching between a room and a direct message never loses either.
export const convs = new Map<string, Conv>();
// The scalars read and written across modules. ES module bindings can't be
// reassigned from another module, so the cross-module mutable state lives on one
// shared object every module reads and writes through.
export const state = {
	activeKey: null as string | null, // conversation shown, or null
	joinedRoom: null as string | null, // the room the server has us in (may not be active)
	nick: "", // our display name
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

export function makeConv(type: "room", id: string): RoomConv;
export function makeConv(type: "dm", id: string): DmConv;
export function makeConv(type: "room" | "dm", id: string): Conv {
	const key = convKey(type, id);
	const base = { id, key, history: [] as Item[], unread: 0 };
	// Build only the fields the kind owns, so the union stays honest: a room gets
	// its member/typing maps, a DM gets its introduction flags, neither the other's.
	const conv: Conv = type === "room"
		? { ...base, type, members: new Map(), typers: new Map() }
		: { ...base, type, ready: false };
	convs.set(key, conv);
	return conv;
}
export function ensureRoom(name: string): RoomConv {
	const existing = getConv(convKey("room", name));
	if (existing && existing.type === "room") return existing;
	return makeConv("room", name);
}
export function ensureDm(peer: string): DmConv {
	const existing = getConv(convKey("dm", peer));
	if (existing && existing.type === "dm") return existing;
	const conv = makeConv("dm", peer);
	conv.id = peer; // keep the casing the peer arrived with
	return conv;
}

// ── Message items ─────────────────────────────────────────────────────────
// Each conversation stores plain item records; the log is painted from them, so
// switching conversations re-renders rather than losing history.
export function chatItem(
	from: string,
	text: string,
	mine: boolean,
	sendState?: SendState,
): ChatItem {
	const item: ChatItem = { kind: "chat", from, text, mine, at: Date.now() };
	if (sendState) item.state = sendState;
	return item;
}
export function sysItem(text: string): Item {
	return { kind: "sys", text, at: Date.now() };
}
