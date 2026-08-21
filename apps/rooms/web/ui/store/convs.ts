// Conversations this tab holds: rooms, direct lines, and the keys that name them.
//
// A room's identity is its directory and its name; a direct line's is the
// introduction that opened it. The page reaches these through `store.ts`.

import type { Conv, ConvBase, DirId, DirView, DmConv, DmLine, RoomConv, Unread } from "../types.ts";
import { letLinesGo, set, type State, state } from "./core.ts";
import { isSelf } from "./dirs.ts";

// ── Conversations ─────────────────────────────────────────────────────────
/** A room's key is its directory and its name together, because a room name only
 * means anything inside the directory that granted it. Two clients naming one
 * room on one directory mean one room; the same name on another directory is
 * somewhere else entirely.
 *
 * A direct line's key is minted per introduction and never derived from a name,
 * which is why only rooms have a key function. It carries its directory in a
 * field instead, for the same reason: the nickname it reaches is that
 * directory's to grant.
 *
 * The two halves are joined by a NUL, and it is written as an escape and never
 * as a raw byte. A locator may hold any character a URI may and a room name may
 * hold a space, so a separator drawn from that alphabet lets one pair spell
 * another pair's key; the typing timers join their two halves the same way and
 * for the same reason. A raw NUL in the source would make the file binary, and
 * every text tool then skips it without saying so. */
export function roomKey(dir: DirId, name: string): string {
	return "room:" + dir + "\u0000" + name.toLowerCase();
}

// Introductions this tab has opened, counted. A direct conversation is keyed on
// the introduction rather than on the member's nick, which is the whole of the
// fix for a thread that used to change hands: the nick is a claim the room
// grants and reclaims, so keying a conversation on it meant that when the claim
// moved, the next message in a thread — same title, same history — was redeemed
// to whoever held the name now.
let introductions = 0;

export function getConv(key: string | null, s: Readonly<State> = state): Conv | null {
	return key === null ? null : s.convs.get(key) ?? null;
}
export function activeConv(): Conv | null {
	return getConv(state.activeKey);
}

/** The directory a reader means by "here": the one the open conversation is on,
 * or the first this tab holds while the join card is up. */
export function actingDir(s: Readonly<State> = state): DirView | null {
	const conv = s.activeKey === null ? null : s.convs.get(s.activeKey) ?? null;
	if (conv !== null) {
		const held = s.dirs.get(conv.dir);
		if (held !== undefined) return held;
	}
	for (const held of s.dirs.values()) return held;
	return null;
}

/** Whether any directory has answered at all, which is what the opening screen
 * waits for: it covers the wait, not one directory's health. */
export function anyDirSettled(s: Readonly<State> = state): boolean {
	for (const held of s.dirs.values()) {
		if (held.session !== "connecting") return true;
	}
	return false;
}

/** Replace the fields both kinds of conversation share, keeping the kind's own.
 *
 * The generic is what keeps a room's patch off a direct line, which is the whole
 * reason `Conv` is a union: spreading it directly loses the discriminant, and the
 * four call sites below each used to cast that enforcement away. */
export function patch<C extends Conv>(conv: C, fields: Partial<ConvBase>): C {
	return Object.assign({}, conv, fields);
}

/** Put a conversation into the map, replacing whatever was there. */
export function put(conv: Conv): void {
	const convs = new Map(state.convs);
	convs.set(conv.key, conv);
	set({ convs });
}

function makeConv(type: "room", dir: DirId, id: string, held?: string): RoomConv;
function makeConv(type: "dm", dir: DirId, id: string): DmConv;
function makeConv(type: "room" | "dm", dir: DirId, id: string, held?: string): Conv {
	introductions += type === "dm" ? 1 : 0;
	const key = type === "room" ? held ?? roomKey(dir, id) : "dm:" + introductions;
	const base = { id, key, dir, history: [], unread: { kind: "caught-up" } as Unread };
	// Build only the fields the kind owns, so the union stays honest: a room gets
	// its member set, a direct line gets its standing, and both get typing.
	const conv: Conv = type === "room"
		? {
			...base,
			type,
			members: new Map(),
			typers: new Set(),
			grants: new Set(),
			standing: null,
			held: held !== undefined,
		}
		: { ...base, type, line: "introducing", typers: new Set() };
	put(conv);
	return conv;
}

/** The conversation for a room, made if this tab has none.
 *
 * `key` is given for a room reached by a reference rather than by name: a
 * private room's label is not unique, so `heldRoomKey` mints its identity the
 * way an introduction mints a direct line's. */
export function ensureRoom(dir: DirId, name: string, key?: string): RoomConv {
	const existing = getConv(key ?? roomKey(dir, name));
	if (existing && existing.type === "room") return existing;
	return makeConv("room", dir, name, key);
}

// Rooms this tab holds a reference to, counted. A private room is not named by
// anything anybody could look up, so — exactly like an introduced direct line —
// its conversation is keyed by the holding rather than by what it is called.
let heldRooms = 0;

/** Mint the identity for a room this tab holds a reference to. */
export function heldRoomKey(): string {
	heldRooms += 1;
	return "held:" + heldRooms;
}

/** Every room this tab is in, in the order it entered them, across every
 * directory or on one of them.
 *
 * A `Map` preserves insertion order, so this needs no timestamp on a
 * conversation to answer "the room I joined first" — which is what a reconnect
 * replays and what the foot names when there is only one. */
export function joinedRooms(dir?: DirId): RoomConv[] {
	return [...state.convs.values()].filter((conv): conv is RoomConv =>
		conv.type === "room" && (dir === undefined || conv.dir === dir)
	);
}

/** Every conversation of either kind on one directory, which is what that
 * directory's teardown has to account for. */
/** The directories this tab holds with nothing open on them.
 *
 * Holding one is a live session and a name registered on it, so a directory with
 * no rooms and no direct lines is not nothing: it is a connection the reader is
 * paying for and a name somebody else cannot take, with no row anywhere saying
 * so. That state is easy to reach — leave the last room on a server — and used
 * to be invisible, which also made every *other* row wear a directory caption to
 * tell it apart from rooms on a directory that was not on screen at all.
 *
 * Never this page's own. It has no rooms before the first join either, and a row
 * saying so at the moment the join card is asking for one is noise. */
export function emptyDirs(s: Readonly<State> = state): DirView[] {
	const busy = new Set<DirId>();
	for (const conv of s.convs.values()) busy.add(conv.dir);
	return [...s.dirs.values()].filter((dir) => dir.id !== s.homeDir && !busy.has(dir.id));
}

export function convsOn(dir: DirId): Conv[] {
	return [...state.convs.values()].filter((conv) => conv.dir === dir);
}

/** Whether this tab is in the room called `name` on `dir`, comparing the way the
 * directory does: a room's name is its identity there, and case is not part of
 * it. */
export function isJoinedRoom(dir: DirId, name: string): boolean {
	return getConv(roomKey(dir, name))?.type === "room";
}

/** The open conversation with `peer`, if there is one.
 *
 * A conversation whose member has gone is not open. The room frees a nick when
 * its holder leaves and will grant it to the next person who asks, and this side
 * has no way to tell one holder from the next — so a fresh introduction opens a
 * fresh conversation rather than continuing one that would now reach someone
 * else. Two conversations may therefore carry the same name, which is honest:
 * they are with two different people. */
export function liveDmWith(dir: DirId, peer: string): DmConv | null {
	const want = peer.toLowerCase();
	for (const conv of state.convs.values()) {
		if (
			conv.type === "dm" && conv.dir === dir && conv.line !== "closed" &&
			conv.id.toLowerCase() === want
		) {
			return conv;
		}
	}
	return null;
}
/** The conversation with `peer`, made if this tab has none — or `null` when
 * `peer` is this tab. A line to yourself is not a conversation, so the mint
 * refuses rather than leaving every caller to remember. */
export function ensureDm(dir: DirId, peer: string): DmConv | null {
	if (isSelf(dir, peer)) return null;
	return liveDmWith(dir, peer) ?? makeConv("dm", dir, peer);
}

/** Close every open conversation with `peer` — the member has left, so the name
 * is back in the room's hands. Returns the keys closed, for the caller to drop
 * whatever it was holding for them. */
export function closeDmsWith(dir: DirId, peer: string): string[] {
	const closed: string[] = [];
	const convs = new Map(state.convs);
	for (const conv of convs.values()) {
		if (
			conv.type === "dm" && conv.dir === dir && conv.line !== "closed" &&
			conv.id.toLowerCase() === peer.toLowerCase()
		) {
			convs.set(conv.key, { ...conv, line: "closed" });
			closed.push(conv.key);
		}
	}
	if (closed.length > 0) set({ convs });
	return closed;
}

/** Drop a conversation. If it was the one on screen, nothing is on screen now:
 * the caller chooses where to go next, but it cannot leave `activeKey` naming a
 * conversation that no longer exists.
 *
 * Its lines go the way every other line goes, through the release seam, and
 * they go before the row does: the seam finds the session by asking this store
 * which directory the conversation was on, so a conversation deleted first is
 * one whose lines can no longer be given back. Both callers used to hand their
 * history over themselves, immediately before calling this. That worked and
 * was one caller away from not working, which is the same shape as any
 * invariant kept by everybody remembering rather than by the seam that owns
 * it. */
export function forgetConv(key: string): void {
	letLinesGo(key, state.convs.get(key)?.history ?? []);
	const convs = new Map(state.convs);
	convs.delete(key);
	// The draft goes with it. What was half-written to a room is addressed to
	// that room, so it cannot outlive it — and its attachments are open file
	// handles this tab would otherwise hold for a conversation that is gone.
	const drafts = new Map(state.drafts);
	drafts.delete(key);
	const lastSent = new Map(state.lastSent);
	lastSent.delete(key);
	if (state.activeKey === key) set({ convs, drafts, lastSent, activeKey: null });
	else set({ convs, drafts, lastSent });
}

/** Mark every direct conversation as no longer live, which is what a dropped
 * directory session means for all of them at once. */
export function unreadyDms(): void {
	const convs = new Map(state.convs);
	for (const conv of convs.values()) {
		if (conv.type === "dm" && conv.line === "live") {
			convs.set(conv.key, { ...conv, line: "introducing" });
		}
	}
	set({ convs });
}

/** Move a direct line between introducing and live. A closed one stays closed:
 * the room has the nick back, so nothing arriving under it belongs to this
 * conversation. */
export function setDmLine(key: string, line: Exclude<DmLine, "closed">): void {
	const conv = getConv(key);
	if (conv?.type !== "dm" || conv.line === "closed" || conv.line === line) return;
	put({ ...conv, line });
}
