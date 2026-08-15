// The one place the page's state lives.
//
// Everything the interface shows is a field here, and everything that changes it
// is a verb here. That is the whole rule, and it is worth stating because the
// alternative is what a browser makes easy: keeping half the truth in the DOM
// (is that class on the container? is that button disabled?) and the other half
// in module variables, then writing a third body of code whose only job is to
// keep the two agreeing. Reading a class back to decide what a control should
// announce is that code, and there is none of it here.
//
// The store knows nothing about React and nothing about the wire. `hooks.ts`
// subscribes the components to it, and `net.ts` drives it from the CapTP side
// without importing a single view.

import {
	type AttachmentView,
	type Banner,
	type Conv,
	type ConvBase,
	type DirId,
	type DirView,
	type DmConv,
	type DmLine,
	type Item,
	type RoomConv,
	type SendState,
	type SessionPhase,
	type Standing,
	type Unread,
	type ViewerDirection,
} from "./types.ts";
import type { Presence } from "../../lib/limits.ts";
import { kindOf } from "./media.ts";

// Small, swallow-errors localStorage wrapper (private-mode / disabled storage).
// What this page remembers between visits, and under what names. One table
// because a get and a set that disagree by a character fail silently and look
// like a preference that will not stick. `rooms.theme` is read a second time by
// the small script in page.html, which stamps the palette before the first paint
// and so cannot wait for this module; renaming it here means renaming it there.
// Direct-message transport and the ocapnviz WebSocket live in prefs.ts
// (`rooms.dm`, `rooms.viz`): they reload the peer, so they are not store fields.
const KEY = {
	nick: "rooms.nick",
	room: "rooms.room",
	locator: "rooms.locator",
	theme: "rooms.theme",
	notify: "rooms.notify",
	ignored: "rooms.ignored",
} as const;

// Persistence lives beside the verbs that own each fact, so nothing outside this
// file reaches for storage.
const LS = {
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

// Must match the `@media (max-width: 820px)` block in page.css: that rule turns
// the grid into the list/conversation stack, and this decides which layout's
// field a control writes. They are two files that have to agree.
const mobileQuery = matchMedia("(max-width: 820px)");

/** A conversation's unsent composer: what is typed, and what is attached.
 *
 * One shape rather than two parallel maps, because they are one thing — what a
 * reader has ready to send here — and two maps would have to be kept in step by
 * every caller that clears one. */
export interface Draft {
	text: string;
	files: readonly File[];
	/** The line this draft will change rather than post, when a reader has
	 * pressed the pencil on one of their own.
	 *
	 * Held here rather than left to `/edit`, which changes the most recent line:
	 * pressing the pencil on an older message names *that* one, and a composer
	 * that quietly rewrote a different message would be the worst kind of wrong.
	 * It is a local item id, the same one the withdraw button carries. */
	changing?: number;
}

/** The draft for a conversation, or an empty one. A conversation with nothing
 * typed in it keeps no row, so this is what the common case reads. */
export const NO_DRAFT: Draft = { text: "", files: [] };

export interface State {
	/** The conversation on screen, or null while the join card is up. */
	activeKey: string | null;
	/** Every conversation this tab has open, keyed as `makeConv` describes.
	 *
	 * This is also the answer to which rooms we are in. A room conversation is
	 * made when the room admits us and forgotten when we leave, so membership has
	 * no separate field to disagree with it — and a tab is in as many rooms at
	 * once as it likes, the way it already holds as many direct lines. */
	convs: ReadonlyMap<string, Conv>;
	/** Every directory this tab holds, in the order it opened them.
	 *
	 * Opening a second takes nothing away from the first, so this is a map and not
	 * a field: a room list, a set of reachable peers, and a connection's health
	 * all belong to one directory, and there is no "current" one to read them
	 * from. */
	dirs: ReadonlyMap<DirId, DirView>;
	/** The directory this page came with, once it is known.
	 *
	 * Named rather than addressed: it is the one a reader never chose, so
	 * showing them its locator answers a question they did not ask. Null until the
	 * page has resolved it, which is also the state a page loaded offline stays
	 * in. */
	homeDir: DirId | null;
	banner: Banner | null;
	/** Whether the tab is being looked at, and a count that rises each time it is
	 * returned to. One subscriber writes both; everything that asks reads here,
	 * so `document.hidden` is read in exactly one place in the tree. */
	visible: boolean;
	returns: number;
	/** Whether the narrow layout is in force. It is state, not a hook's answer,
	 * because the verbs below have to know which layout a control belongs to. */
	mobile: boolean;
	/** What is typed but not yet sent, per conversation, keyed the way `convs` is.
	 *
	 * Here rather than in the composer because the "@" on a message writes to it
	 * and that control is in the log. Keyed rather than single because a reader
	 * with two rooms open switches between them constantly, and a draft the whole
	 * page shares does not stay behind when they do: the half-written sentence
	 * arrives in the next room under that room's name, one press from being posted
	 * to it. Attachments make the same mistake expensive rather than annoying,
	 * because files picked for a room could leave in a direct message.
	 *
	 * A conversation with nothing typed in it holds no row, so this is empty for
	 * the common case, and `forgetConv` drops a row with its conversation — a
	 * draft cannot outlive the thing it was addressed to. */
	drafts: ReadonlyMap<string, Draft>;
	/** Names this window does not draw lines from, folded. See `ignore`. */
	ignored: ReadonlySet<string>;
	/** The join card's room target and display name. An empty locator means the
	 * directory serving this page. */
	draftRoom: string;
	draftLocator: string;
	draftNick: string;
	theme: "light" | "dark";
	notifyOn: boolean;
	// ── Chrome ────────────────────────────────────────────────────────────
	// The rail and the roster each mean something different on the two layouts:
	// on a wide screen they are columns you collapse and keep collapsed, on a
	// phone they are a screen and a sheet that any navigation dismisses. Those
	// are two facts with two lifetimes, so they are two fields; each layout reads
	// its own, and each layout's controls write only its own. Nothing has to be
	// re-synced when the window crosses the breakpoint, and crossing it shows the
	// other layout its own last answer rather than a translation of this one's.
	/** Wide layout: is the rooms column shown? */
	railOpen: boolean;
	/** Narrow layout: is the rooms list the screen being shown? */
	listScreen: boolean;
	/** Wide layout: is the member column shown? */
	rosterOpen: boolean;
	/** Narrow layout: is the roster sheet up? */
	rosterSheet: boolean;
	/** Settings dialog: the query-param facts (DM transport, viz URL). */
	settingsOpen: boolean;
	/** The directory whose card is open, or null. Never the page's own: asking
	 * about that one opens Settings, which is already about it. */
	aboutDir: DirId | null;
	/** The posted file being viewed full-screen, named by the line that carries
	 * it rather than copied out of it. The viewer draws from the line, so
	 * bytes that arrive while it is open reach it without a second copy of the
	 * same fact going stale behind them. */
	viewing: { key: string; id: number } | null;
}

const initial: State = {
	activeKey: null,
	convs: new Map(),
	dirs: new Map(),
	homeDir: null,
	banner: null,
	visible: true,
	returns: 0,
	mobile: mobileQuery.matches,
	drafts: new Map(),
	ignored: new Set((LS.get(KEY.ignored) ?? "").split(",").filter(Boolean)),
	draftRoom: LS.get(KEY.room) ?? "general",
	draftLocator: LS.get(KEY.locator) ?? "",
	draftNick: LS.get(KEY.nick) ?? "",
	theme: (LS.get(KEY.theme) ??
		(matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light")) as
			| "light"
			| "dark",
	notifyOn: LS.get(KEY.notify) === "1",
	railOpen: true,
	listScreen: false,
	rosterOpen: true,
	rosterSheet: false,
	settingsOpen: false,
	aboutDir: null,
	viewing: null,
};

let state: State = initial;
const listeners = new Set<() => void>();

// The layout is a query, not a document, and the store's own verbs depend on it:
// which field "show the rooms list" writes is decided here, so a control can ask
// for it without knowing what it means on the layout in force. Whether the tab is
// being *looked at* is a document fact, so `hooks.ts` subscribes to that one and
// reports it through `noteVisibility`.
mobileQuery.addEventListener("change", (e) => set({ mobile: e.matches }));

/** The current state.
 *
 * Read-only all the way down, so "never write through it" is a thing the
 * compiler refuses rather than a rule a reader has to keep. Every write in this
 * file already copies before it mutates; this is what stops the next one from
 * forgetting, and it is the whole of the one-authority claim above. */
export function get(): Readonly<State> {
	return state;
}

export function subscribe(listener: () => void): () => void {
	listeners.add(listener);
	return () => listeners.delete(listener);
}

/** Replace the named fields and tell every reader. The object identity changes
 * on every write, which is how React knows to look again. */
function set(patch: Partial<State>): void {
	state = { ...state, ...patch };
	for (const listener of listeners) listener();
}

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
let nextItemId = 0;

export function getConv(key: string | null): Conv | null {
	return key === null ? null : state.convs.get(key) ?? null;
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
function patch<C extends Conv>(conv: C, fields: Partial<ConvBase>): C {
	return Object.assign({}, conv, fields);
}

/** Put a conversation into the map, replacing whatever was there. */
function put(conv: Conv): void {
	const convs = new Map(state.convs);
	convs.set(conv.key, conv);
	set({ convs });
}

function makeConv(type: "room", dir: DirId, id: string): RoomConv;
function makeConv(type: "dm", dir: DirId, id: string): DmConv;
function makeConv(type: "room" | "dm", dir: DirId, id: string): Conv {
	introductions += type === "dm" ? 1 : 0;
	const key = type === "room" ? roomKey(dir, id) : "dm:" + introductions;
	const base = { id, key, dir, history: [], unread: { kind: "caught-up" } as Unread };
	// Build only the fields the kind owns, so the union stays honest: a room gets
	// its member set, a direct line gets its standing, and both get typing.
	const conv: Conv = type === "room"
		? { ...base, type, members: new Map(), typers: new Set(), grants: new Set() }
		: { ...base, type, line: "introducing", typers: new Set() };
	put(conv);
	return conv;
}

export function ensureRoom(dir: DirId, name: string): RoomConv {
	const existing = getConv(roomKey(dir, name));
	if (existing && existing.type === "room") return existing;
	return makeConv("room", dir, name);
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
function liveDmWith(dir: DirId, peer: string): DmConv | null {
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
export function ensureDm(dir: DirId, peer: string): DmConv {
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
 * conversation that no longer exists. */
export function forgetConv(key: string): void {
	const convs = new Map(state.convs);
	convs.delete(key);
	// The draft goes with it. What was half-written to a room is addressed to
	// that room, so it cannot outlive it — and its attachments are open file
	// handles this tab would otherwise hold for a conversation that is gone.
	const drafts = new Map(state.drafts);
	drafts.delete(key);
	if (state.activeKey === key) set({ convs, drafts, activeKey: null });
	else set({ convs, drafts });
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

// ── Message items ─────────────────────────────────────────────────────────
export function chatItem(
	from: string,
	text: string,
	mine: boolean,
	sendState?: SendState,
	attachments?: readonly AttachmentView[],
): Extract<Item, { kind: "chat" }> {
	return {
		kind: "chat",
		id: nextItemId++,
		from,
		text,
		mine,
		at: Date.now(),
		state: sendState,
		attachments,
	};
}

/** Give a file its own UI identity. Message ids locate bubbles; attachment ids
 * locate independently transferring capabilities inside them. Both come from
 * one tab-local sequence so no data-layer map can confuse the two. */
export function attachmentView(fields: Omit<AttachmentView, "id">): AttachmentView {
	return { id: nextItemId++, ...fields };
}

export type AttachmentFields = Omit<Partial<AttachmentView>, "id">;

/** Change any number of files in one conversation with one history scan, one
 * immutable copy, and one store notification. Parallel transfers arrive as a
 * batch because network chunk cadence is not presentation cadence. */
export function updateAttachments(
	key: string,
	updates: ReadonlyMap<number, AttachmentFields>,
): void {
	if (updates.size === 0) return;
	const conv = getConv(key);
	if (!conv) return;
	let history: Item[] | null = null;
	for (let at = 0; at < conv.history.length; at++) {
		const item = conv.history[at];
		if (item.kind !== "chat" || item.attachments === undefined) continue;
		let changed = false;
		const attachments = item.attachments.map((attachment) => {
			const fields = updates.get(attachment.id);
			if (fields === undefined) return attachment;
			changed = true;
			return { ...attachment, ...fields, id: attachment.id };
		});
		if (!changed) continue;
		if (history === null) history = conv.history.slice();
		history[at] = { ...item, attachments };
	}
	if (history !== null) put(patch(conv, { history }));
}

/** Change one file. Terminal state changes use this focused form; progress
 * callbacks use `updateAttachments` through the frame coalescer in `net.ts`. */
export function updateAttachment(key: string, id: number, fields: AttachmentFields): void {
	updateAttachments(key, new Map([[id, fields]]));
}
export function sysItem(text: string): Item {
	return { kind: "sys", id: nextItemId++, text, at: Date.now() };
}

/** Add one line to a conversation.
 *
 * A conversation nobody is reading counts the line as unread and remembers where
 * the unread run started, which is where the log draws its rule. System lines are
 * not counted: they are this tab talking to itself.
 *
 * The history is replaced rather than appended to, because that is what lets a
 * reader tell one version from the next, and the log's own pass over it is
 * memoised on exactly that identity. Both are linear in the conversation, and
 * nothing caps how long a conversation gets — so a tab left in a busy room all
 * day pays for its own scrollback twice over, growing. That is a real bound
 * nobody has set, and setting it is a question about the product rather than the
 * code: how much of a room a tab should keep, and what a reader should be told
 * when it stops keeping more. Until that is answered it is named here rather
 * than quietly capped. */
export function deliver(key: string, item: Item): void {
	const conv = getConv(key);
	if (!conv) return;
	const read = key === state.activeKey && state.visible;
	const counts = item.kind === "chat" || item.kind === "action";
	put(patch(conv, {
		history: [...conv.history, item],
		unread: read || !counts ? conv.unread : count(conv.unread, item.id),
	}));
}

/** One more unread line. A run that is already going keeps the line it started
 * on; a rule still up from the last visit adopts that same line, so arriving,
 * reading, and being interrupted again does not move the mark up the log. */
function count(unread: Unread, at: number): Unread {
	if (unread.kind === "unread") return { ...unread, count: unread.count + 1 };
	return { kind: "unread", count: 1, from: unread.kind === "rule-only" ? unread.from : at };
}

/** Deliver to the conversation on screen, for a notice about this tab itself. */
export function deliverActive(item: Item): void {
	if (state.activeKey) deliver(state.activeKey, item);
}

/** Change one line in place, by id. This is how the data layer moves a message
 * between sending, failed, and confirmed: it holds the id, never a DOM node. */
export function updateItem(key: string, id: number, fields: Partial<Item>): void {
	const conv = getConv(key);
	if (!conv) return;
	const at = conv.history.findIndex((item) => item.id === id);
	if (at < 0) return;
	const history = conv.history.slice();
	history[at] = { ...history[at], ...fields } as Item;
	put(patch(conv, { history }));
}

/** The reader has caught up with this conversation. The unread count clears at
 * once; the rule in the log stays a moment longer, so arriving at a conversation
 * still shows you where you left off. */
export function markRead(key: string): void {
	const conv = getConv(key);
	if (conv?.unread.kind !== "unread") return;
	put(patch(conv, { unread: { kind: "rule-only", from: conv.unread.from } }));
}

/** Take down the "New messages" rule, leaving the unread count as it is. Called
 * a moment after the reader arrives, so the rule is seen and then retires. */
export function clearUnreadRule(key: string): void {
	const conv = getConv(key);
	// Only a rule that has outlived its run retires. A conversation still taking
	// lines is not caught up, so a timer landing late cannot strip its mark.
	if (conv?.unread.kind !== "rule-only") return;
	put(patch(conv, { unread: { kind: "caught-up" } }));
}

// ── Room membership and typing ────────────────────────────────────────────
export function applyPresence(key: string, event: Presence | null): void {
	const conv = getConv(key);
	if (!event || conv?.type !== "room") return;
	const members = new Map(conv.members);
	// A standing is replaced whole rather than mutated, because the map holds
	// frozen rows that a render may still be reading.
	const standing = (name: string): Standing => members.get(name) ?? { online: false, away: "" };
	if (event.kind === "roster") {
		for (const [name, was] of members) members.set(name, { ...was, online: false });
		for (const name of event.names) members.set(name, { ...standing(name), online: true });
	} else if (event.kind === "away") {
		// Only about somebody already here: a room states this for its members,
		// and a name arriving any other way would be inventing one.
		if (!members.has(event.name)) return;
		members.set(event.name, { ...standing(event.name), away: event.reason });
	} else {
		// Coming back into a room arrives present. Their standing left with the
		// membership that set it, and carrying a stale one over would have them
		// away while they are typing.
		members.set(event.name, { online: event.kind === "join", away: "" });
	}
	put({ ...conv, members });
}

/** What a room says it is about.
 *
 * Cleared and never-set are different states and both are spellable: a room that
 * has had its topic taken down says so with an empty string, and a room that has
 * never had one says nothing. The bar draws neither, so the difference shows
 * only in whether a change is worth announcing — taking one down is news. */
export function setTopic(key: string, topic: string): void {
	const conv = getConv(key);
	if (conv?.type !== "room" || conv.topic === topic) return;
	put({ ...conv, topic });
}

/** What a room will carry in one line, in bytes. See `lineBytes`. */
export function setLineBytes(key: string, lineBytes: number): void {
	const conv = getConv(key);
	if (conv?.type !== "room" || conv.lineBytes === lineBytes) return;
	put({ ...conv, lineBytes });
}

/** Empty this conversation's history in this window.
 *
 * Yours and only yours: the room keeps what was said and hands it back on the
 * way in again, so this is a window being tidied rather than anything being
 * destroyed. That is the whole reason it needs no permission — there is nothing
 * here to ask anybody about. */
export function clearHistory(key: string): void {
	const conv = getConv(key);
	if (conv === null || conv.history.length === 0) return;
	put({ ...conv, history: [] });
}

/** Whose lines this window does not draw.
 *
 * Kept in this window rather than told to the room, which is the honest shape:
 * ignoring somebody is a decision about what you read, and a room that was told
 * would be a room that could be asked. Names are held folded, since a directory
 * grants them case-insensitively.
 *
 * Persisted, because an ignore that forgot itself on reload would have to be
 * made again every morning by exactly the person who least wants to think about
 * whoever it names. */
export function ignore(name: string): void {
	const folded = name.toLowerCase();
	if (state.ignored.has(folded)) return;
	const ignored = new Set(state.ignored);
	ignored.add(folded);
	LS.set(KEY.ignored, [...ignored].join(","));
	set({ ignored });
}

export function unignore(name: string): boolean {
	const folded = name.toLowerCase();
	if (!state.ignored.has(folded)) return false;
	const ignored = new Set(state.ignored);
	ignored.delete(folded);
	LS.set(KEY.ignored, [...ignored].join(","));
	set({ ignored });
	return true;
}

/** Find the line a room names, and change it.
 *
 * By the room's own id rather than ours, because that is the only name both
 * sides share. A line nobody has — one that arrived before this tab did, or was
 * already cleared from this window — is not an error: the room said something
 * about a line we do not hold, and the honest answer is to do nothing. */
export function applyLineChange(
	key: string,
	lineId: number,
	change: { text?: string; edited?: boolean; withdrawn?: boolean },
): void {
	const conv = getConv(key);
	if (conv === null) return;
	const at = conv.history.findIndex((item) => item.kind === "chat" && item.lineId === lineId);
	if (at < 0) return;
	const history = conv.history.slice();
	history[at] = { ...history[at], ...change } as Item;
	put(patch(conv, { history }));
}

/** Record what this room handed this membership, once subscribing has answered.
 *
 * Replaced whole rather than added to, because a fresh subscribe is a fresh set
 * of references: a grant that stopped being answered has stopped being held. */
export function setGrants(key: string, grants: ReadonlySet<string>): void {
	const conv = getConv(key);
	if (conv?.type !== "room") return;
	put({ ...conv, grants });
}

/** Remember what the room calls one of our own lines, once its echo says so. */
export function nameLine(key: string, id: number, lineId: number): void {
	updateItem(key, id, { lineId } as Partial<Item>);
}

/** Record that this tab holds the reference governing one of its own lines,
 * which is what the pencil and the close beside that message act on. */
export function holdLine(key: string, id: number): void {
	updateItem(key, id, { held: true } as Partial<Item>);
}

/** Let go of every line held on `dir`, because the connection those references
 * came over has ended and a reference cannot outlive it. The lines stay: what
 * was said is still what was said, and only what can still be done to it
 * changes. */
export function dropHeldLines(dir: DirId): string[] {
	const stoppedChanging: string[] = [];
	for (const conv of [...state.convs.values()]) {
		if (conv.dir !== dir) continue;
		let history: Item[] | null = null;
		const dropped = new Set<number>();
		for (let at = 0; at < conv.history.length; at++) {
			const item = conv.history[at];
			if (item.kind !== "chat" || item.held !== true) continue;
			history ??= conv.history.slice();
			history[at] = { ...item, held: false };
			dropped.add(item.id);
		}
		if (history !== null) put(patch(conv, { history }));
		// A change the reader is part way through writing is aimed at one of those
		// lines, and it can no longer land. The words stay, because they are still
		// theirs to say; what goes is the aim, so pressing Enter says them as a new
		// message instead of refusing over and over.
		const draft = state.drafts.get(conv.key);
		if (draft?.changing !== undefined && dropped.has(draft.changing)) {
			const drafts = new Map(state.drafts);
			if (draft.text === "" && draft.files.length === 0) drafts.delete(conv.key);
			else drafts.set(conv.key, { ...draft, changing: undefined });
			set({ drafts });
			stoppedChanging.push(conv.key);
		}
	}
	return stoppedChanging;
}

export function clearMembers(key: string): void {
	const conv = getConv(key);
	if (conv?.type !== "room" || conv.members.size === 0) return;
	put({ ...conv, members: new Map() });
}

export function setTyper(key: string, who: string, typing: boolean): void {
	const conv = getConv(key);
	if (conv == null || conv.typers.has(who) === typing) return;
	const typers = new Set(conv.typers);
	if (typing) typers.add(who);
	else typers.delete(who);
	put({ ...conv, typers });
}

// ── Directory ─────────────────────────────────────────────────────────────
// ── Directories ───────────────────────────────────────────────────────────
// Each of these names the directory it acts on. That is the whole of the change
// from one directory to several: a room list, a set of reachable peers, and a
// connection's health all belong to one directory, and reporting them without
// saying which one is what made holding two of them unspellable.

/** Replace one directory's view, leaving every other directory alone. */
function patchDir(dir: DirId, fields: Partial<DirView>): void {
	const held = state.dirs.get(dir);
	if (held === undefined) return;
	const dirs = new Map(state.dirs);
	dirs.set(dir, { ...held, ...fields });
	set({ dirs });
}

/** Start holding `dir`, or leave it as it stands if this tab already does.
 *
 * Idempotent because asking for a directory twice must never be a way to lose
 * what is already on it: the rooms are conversations, but the room list and the
 * reachable peers live here. */
export function openDir(dir: DirId): void {
	if (state.dirs.has(dir)) return;
	// The lowest mark nobody is wearing, so two directories can never share one
	// and one that leaves gives its mark back.
	const taken = new Set([...state.dirs.values()].map((held) => held.slot));
	let slot = 1;
	while (taken.has(slot)) slot += 1;
	const dirs = new Map(state.dirs);
	dirs.set(dir, {
		id: dir,
		slot,
		nick: "",
		reached: false,
		liveRooms: new Map(),
		dmablePeers: new Set(),
		session: "connecting",
		statusText: "connecting…",
		dmUnreachable: "",
	});
	set({ dirs });
}

/** Stop holding `dir`. Its conversations are forgotten by their own verb: this
 * is the directory's own state and nothing else. */
export function forgetDir(dir: DirId): void {
	if (!state.dirs.has(dir)) return;
	const dirs = new Map(state.dirs);
	dirs.delete(dir);
	set({ dirs });
}

export function setDirSession(dir: DirId, session: SessionPhase): void {
	patchDir(dir, { session });
}

/** Record that this directory has answered. One way only: one that has been
 * reached once stays reached for the life of the tab, because what the flag
 * exists to tell apart is "this address may be wrong" from "this directory has
 * gone away", and only the first of those is ever true before the first
 * answer. */
/** Name the directory this page came with. Written once, by the one open that
 * had no locator to start with. */
export function setHomeDir(dir: DirId): void {
	if (state.homeDir === dir) return;
	set({ homeDir: dir });
}

export function markDirReached(dir: DirId): void {
	patchDir(dir, { reached: true });
}

/** Whether this directory has ever answered in this tab. An unknown one reads
 * as not reached, which is the safe answer: it is the arm that gives up. */
export function dirReached(dir: DirId): boolean {
	return state.dirs.get(dir)?.reached ?? false;
}
export function setDirStatus(dir: DirId, statusText: string): void {
	patchDir(dir, { statusText });
}

/** Say whether others can reach this tab for direct messages on `dir`: a reason
 * when they cannot, empty when they can. */
export function setDmUnreachable(dir: DirId, why: string): void {
	if ((state.dirs.get(dir)?.dmUnreachable ?? "") === why) return;
	patchDir(dir, { dmUnreachable: why });
}
export function setLiveRoom(dir: DirId, name: string, count: number): void {
	const held = state.dirs.get(dir);
	if (held === undefined) return;
	const liveRooms = new Map(held.liveRooms);
	liveRooms.set(name, count);
	patchDir(dir, { liveRooms });
}
export function dropLiveRoom(dir: DirId, name: string): void {
	const held = state.dirs.get(dir);
	if (held === undefined) return;
	const liveRooms = new Map(held.liveRooms);
	liveRooms.delete(name);
	patchDir(dir, { liveRooms });
}
export function resetLiveRooms(dir: DirId, rooms: Iterable<readonly [string, number]>): void {
	patchDir(dir, { liveRooms: new Map(rooms) });
}
export function setDmable(dir: DirId, name: string, reachable: boolean): void {
	const held = state.dirs.get(dir);
	if (held === undefined) return;
	const dmablePeers = new Set(held.dmablePeers);
	if (reachable) dmablePeers.add(name.toLowerCase());
	else dmablePeers.delete(name.toLowerCase());
	patchDir(dir, { dmablePeers });
}
export function clearDmable(dir: DirId): void {
	patchDir(dir, { dmablePeers: new Set() });
}

// ── Session, join card, chrome ────────────────────────────────────────────
/** What the application is doing on the directory the reader is on. Says nothing
 * about any session's health, which is why it cannot paint a dot. */
export function setStatus(statusText: string): void {
	const here = actingDir();
	if (here !== null) setDirStatus(here.id, statusText);
}
export function setBanner(banner: Banner | null): void {
	set({ banner });
}
/** What is ready to send in a conversation, or an empty draft.
 *
 * Every reader of a draft goes through here, so "no row yet" and "a row that has
 * been emptied" are one answer rather than two the callers each have to handle. */
export function draftFor(key: string | null): Draft {
	return (key === null ? undefined : state.drafts.get(key)) ?? NO_DRAFT;
}

/** The draft of the conversation on screen. The composer only exists inside one,
 * so this is what it reads and what its verbs below write. */
export function activeDraft(): Draft {
	return draftFor(state.activeKey);
}

/** Write the conversation on screen's draft, dropping the row once there is
 * nothing left in it so an untouched conversation costs nothing and a cleared
 * one stops being remembered.
 *
 * Nothing happens with no conversation on screen: there would be no addressee,
 * and the composer is not drawn there anyway. */
function setActiveDraft(next: Draft): void {
	const key = state.activeKey;
	if (key === null) return;
	const drafts = new Map(state.drafts);
	// An empty draft keeps its row while it is changing a line: emptying the box
	// to retype a message must not lose which message is being retyped.
	if (next.text === "" && next.files.length === 0 && next.changing === undefined) drafts.delete(key);
	else drafts.set(key, next);
	set({ drafts });
}

export function setDraft(text: string): void {
	setActiveDraft({ ...activeDraft(), text });
}

/** Begin changing a line already posted: its words go into the composer, and
 * the composer remembers which line they belong to. */
export function startChange(id: number, text: string): void {
	setActiveDraft({ ...activeDraft(), text, changing: id });
}

/** Stop changing, leaving the line as it was posted and the composer empty. */
export function cancelChange(): void {
	setActiveDraft({ ...activeDraft(), text: "", changing: undefined });
}
export function addDraftFiles(files: readonly File[]): void {
	const draft = activeDraft();
	setActiveDraft({ ...draft, files: [...draft.files, ...files] });
}
export function removeDraftFile(index: number): void {
	const draft = activeDraft();
	setActiveDraft({ ...draft, files: draft.files.filter((_, at) => at !== index) });
}
export function clearDraftFiles(): void {
	setActiveDraft({ ...activeDraft(), files: [] });
}
/** Remember the name this reader asks to be known by, and offer it next time.
 *
 * A preference, not an identity: what a reader typed, kept for the join card to
 * prefill. Whether a directory actually granted it is that directory's own
 * answer, and it lives in `setDirNick`. */
export function setPreferredNick(nick: string): void {
	LS.set(KEY.nick, nick);
	set({ draftNick: nick });
}

/** Record the name `dir` granted.
 *
 * One directory's answer and no other's. A directory may hand back a variant of
 * what was asked for, `alice` is taken so `alice-2`, and that variant is true
 * there and nowhere else. Written once per directory, read wherever the question
 * is "is this line mine", which is always a question about one conversation and
 * therefore about one directory. */
export function setDirNick(dir: DirId, nick: string): void {
	patchDir(dir, { nick });
}

/** The name `dir` granted, or empty when it has granted none. */
export function dirNick(dir: DirId): string {
	return state.dirs.get(dir)?.nick ?? "";
}
/** Remember `name` as the room to offer next time this browser opens the page.
 *
 * Only the join card reads it back, so this is a prefill and not a record of
 * membership: that is `convs`. A tab in several rooms offers the one it entered
 * most recently, which is the one a returning reader is most likely to want. */
/** Open or close the card describing one directory. */
export function showAboutDir(dir: DirId | null): void {
	set({ aboutDir: dir });
}

export function rememberRoom(name: string): void {
	LS.set(KEY.room, name);
}
/** Report whether the tab is being looked at. `hooks.ts` is the one caller.
 *
 * The count rises on the change to visible, not on every report, so telling the
 * store what it already believes is free — which is what lets the seam sync the
 * real value at startup without it reading as a return. */
export function noteVisibility(visible: boolean): void {
	if (state.visible === visible) return;
	set({ visible, returns: visible ? state.returns + 1 : state.returns });
}
export function setDrafts(
	patch: { draftRoom?: string; draftLocator?: string; draftNick?: string },
): void {
	if (patch.draftLocator !== undefined) LS.set(KEY.locator, patch.draftLocator);
	set(patch);
}
export function setTheme(theme: "light" | "dark"): void {
	LS.set(KEY.theme, theme);
	set({ theme });
}
export function setNotify(notifyOn: boolean): void {
	LS.set(KEY.notify, notifyOn ? "1" : "0");
	set({ notifyOn });
}

export function openSettings(): void {
	set({ settingsOpen: true });
}

export function closeSettings(): void {
	if (state.settingsOpen) set({ settingsOpen: false });
}

/** Open one posted file full-screen, over everything. */
export function openViewer(key: string, id: number): void {
	set({ viewing: { key, id } });
}

export function closeViewer(): void {
	if (state.viewing !== null) set({ viewing: null });
}

/** Move to the adjacent picture in this conversation's message order.
 *
 * The conversation owns the order, not the gallery that happened to draw a
 * subset of it. Non-image attachments do not enter that order, and reaching an
 * end is a no-op rather than an implicit jump across the conversation. Returns
 * the newly selected image so the network edge can fetch it when necessary. */
export function stepViewer(direction: ViewerDirection): AttachmentView | null {
	const viewing = state.viewing;
	if (viewing === null) return null;
	const conv = state.convs.get(viewing.key);
	if (conv === undefined) return null;

	let previous: AttachmentView | null = null;
	let found = false;
	for (const item of conv.history) {
		if (item.kind !== "chat" || item.attachments === undefined) continue;
		for (const file of item.attachments) {
			if (kindOf(file.mime) !== "image") continue;
			if (found) {
				set({ viewing: { key: viewing.key, id: file.id } });
				return file;
			}
			if (file.id === viewing.id) {
				if (direction === "previous") {
					if (previous !== null) set({ viewing: { key: viewing.key, id: previous.id } });
					return previous;
				}
				found = true;
			}
			previous = file;
		}
	}
	return null;
}

/** The file the viewer is showing, read live from its line so a fetch landing
 * while it is open reaches it. Null when nothing is open, or when the line it
 * named has gone. */
export function viewedAttachment(snapshot: Readonly<State>): AttachmentView | null {
	if (snapshot.viewing === null) return null;
	const conv = snapshot.convs.get(snapshot.viewing.key);
	for (const item of conv?.history ?? []) {
		if (item.kind !== "chat") continue;
		const attachment = item.attachments?.find((file) => file.id === snapshot.viewing!.id);
		if (attachment !== undefined) return attachment;
	}
	return null;
}

/** Show or hide the rooms list, whichever thing that is on the layout in force.
 *
 * The wide layout collapses a column and keeps it collapsed; the narrow one
 * shows a screen any navigation dismisses. Each writes its own field and reads
 * its own field, so crossing the breakpoint shows the other layout its own last
 * answer rather than a translation of this one's, and nothing has to be
 * repaired at the crossing. */
export function showRail(shown: boolean): void {
	set(state.mobile ? { listScreen: shown } : { railOpen: shown });
}

/** Show or hide the roster, the same way. */
export function showRoster(shown: boolean): void {
	set(state.mobile ? { rosterSheet: shown } : { rosterOpen: shown });
}

/** Dismiss the narrow layout's roster sheet, whatever the layout. Navigation
 * does this; it is not a preference and has no wide-layout meaning. */
export function closeRosterSheet(): void {
	if (state.rosterSheet) set({ rosterSheet: false });
}

/** Put a conversation on screen.
 *
 * Any navigation dismisses the phone's overlays and shows the conversation
 * full-screen; on a wide layout those fields are simply not read. */
export function switchTo(key: string): void {
	if (!state.convs.has(key)) return;
	set({ activeKey: key, listScreen: false, rosterSheet: false });
	markRead(key);
}

/** Back to the state the page opens in: the join card up, with nothing selected
 * behind it. Everything that only means something inside a conversation is
 * derived from `activeKey`, so this one field is the whole of it. */
export function showJoinCard(): void {
	set({ activeKey: null, listScreen: false, rosterSheet: false });
}
