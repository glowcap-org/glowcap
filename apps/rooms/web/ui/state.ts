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
	roomsHidden: false, // rooms-rail preference; the phone layout has its own
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
// Introductions this tab has opened, counted. A direct conversation is keyed on
// the introduction rather than on the member's nick, which is the whole of the
// fix for a thread that used to change hands: the nick is a claim the room
// grants and reclaims, so keying a conversation on it meant that when the claim
// moved, the next message in a thread — same title, same history — was redeemed
// to whoever held the name now.
let introductions = 0;
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
	introductions += type === "dm" ? 1 : 0;
	const key = type === "room" ? convKey("room", id) : "dm:" + introductions;
	const base = { id, key, history: [] as Item[], unread: 0 };
	// Build only the fields the kind owns, so the union stays honest: a room gets
	// its member/typing maps, a DM gets its introduction flags, neither the other's.
	const conv: Conv = type === "room"
		? { ...base, type, members: new Map(), typers: new Map() }
		: { ...base, type, ready: false, gone: false };
	convs.set(key, conv);
	return conv;
}
export function ensureRoom(name: string): RoomConv {
	const existing = getConv(convKey("room", name));
	if (existing && existing.type === "room") return existing;
	return makeConv("room", name);
}
/** The open conversation with `peer`, if there is one.
 *
 * A conversation whose member has gone is not open. The room frees a nick when
 * its holder leaves and will grant it to the next person who asks, and this side
 * has no way to tell one holder from the next — so a fresh introduction opens a
 * fresh conversation rather than continuing one that would now reach someone
 * else. Two conversations may therefore carry the same name, which is honest:
 * they are with two different people. */
export function liveDmWith(peer: string): DmConv | null {
	const want = peer.toLowerCase();
	for (const conv of convs.values()) {
		if (conv.type === "dm" && !conv.gone && conv.id.toLowerCase() === want) return conv;
	}
	return null;
}
export function ensureDm(peer: string): DmConv {
	return liveDmWith(peer) ?? makeConv("dm", peer);
}
/** Close every open conversation with `peer` — the member has left, so the name
 * is back in the room's hands. Returns the keys closed, for the caller to drop
 * whatever it was holding for them. */
export function closeDmsWith(peer: string): string[] {
	const closed: string[] = [];
	for (const conv of convs.values()) {
		if (conv.type === "dm" && !conv.gone && conv.id.toLowerCase() === peer.toLowerCase()) {
			conv.gone = true;
			conv.ready = false;
			closed.push(conv.key);
		}
	}
	return closed;
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
