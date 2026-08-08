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

import type {
	Conv,
	ConvBase,
	DmConv,
	DmLine,
	Item,
	RoomConv,
	SendState,
	SessionPhase,
	Unread,
} from "./types.ts";
import type { Presence } from "../../lib/limits.ts";

// Small, swallow-errors localStorage wrapper (private-mode / disabled storage).
// What this page remembers between visits, and under what names. One table
// because a get and a set that disagree by a character fail silently and look
// like a preference that will not stick. `rooms.theme` is read a second time by
// the small script in page.html, which stamps the palette before the first paint
// and so cannot wait for this module; renaming it here means renaming it there.
const KEY = {
	nick: "rooms.nick",
	room: "rooms.room",
	theme: "rooms.theme",
	notify: "rooms.notify",
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

export interface State {
	/** Our display name, once a room has granted it. */
	nick: string;
	/** The room the server has us in, which may not be the conversation on screen. */
	joinedRoom: string | null;
	/** The conversation on screen, or null while the join card is up. */
	activeKey: string | null;
	/** Every conversation this tab has open, keyed as `makeConv` describes. */
	convs: ReadonlyMap<string, Conv>;
	/** The directory: room name to member count. */
	liveRooms: ReadonlyMap<string, number>;
	/** Nicks (lowercased) the directory says are reachable for direct messages. */
	dmablePeers: ReadonlySet<string>;
	/** The session, which is what the dot in the foot reports. */
	session: SessionPhase;
	/** What the application is doing, which is the sentence beside the dot. */
	statusText: string;
	banner: string;
	/** Whether the tab is being looked at, and a count that rises each time it is
	 * returned to. One subscriber writes both; everything that asks reads here,
	 * so `document.hidden` is read in exactly one place in the tree. */
	visible: boolean;
	returns: number;
	/** Whether the narrow layout is in force. It is state, not a hook's answer,
	 * because the verbs below have to know which layout a control belongs to. */
	mobile: boolean;
	/** What is typed into the composer but not yet sent. It lives here rather than
	 * in the composer because the "@" on a message writes to it, and that control
	 * is in the log. */
	draft: string;
	/** The join card's two fields. */
	draftRoom: string;
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
}

const initial: State = {
	nick: "",
	joinedRoom: null,
	activeKey: null,
	convs: new Map(),
	liveRooms: new Map(),
	dmablePeers: new Set(),
	session: "connecting",
	statusText: "connecting…",
	banner: "",
	visible: true,
	returns: 0,
	mobile: mobileQuery.matches,
	draft: "",
	draftRoom: LS.get(KEY.room) ?? "general",
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
/** A room's key is its name, because two clients naming one room mean one room.
 * A direct line's key is minted per introduction and never derived from a name,
 * which is why only rooms have a key function. */
export function roomKey(name: string): string {
	return "room:" + name.toLowerCase();
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

function makeConv(type: "room", id: string): RoomConv;
function makeConv(type: "dm", id: string): DmConv;
function makeConv(type: "room" | "dm", id: string): Conv {
	introductions += type === "dm" ? 1 : 0;
	const key = type === "room" ? roomKey(id) : "dm:" + introductions;
	const base = { id, key, history: [], unread: { kind: "caught-up" } as Unread };
	// Build only the fields the kind owns, so the union stays honest: a room gets
	// its member set, a direct line gets its standing, and both get typing.
	const conv: Conv = type === "room"
		? { ...base, type, members: new Map(), typers: new Set() }
		: { ...base, type, line: "introducing", typers: new Set() };
	put(conv);
	return conv;
}

export function ensureRoom(name: string): RoomConv {
	const existing = getConv(roomKey(name));
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
function liveDmWith(peer: string): DmConv | null {
	const want = peer.toLowerCase();
	for (const conv of state.convs.values()) {
		if (conv.type === "dm" && conv.line !== "closed" && conv.id.toLowerCase() === want) {
			return conv;
		}
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
	const convs = new Map(state.convs);
	for (const conv of convs.values()) {
		if (
			conv.type === "dm" && conv.line !== "closed" &&
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
	if (state.activeKey === key) set({ convs, activeKey: null });
	else set({ convs });
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
): Extract<Item, { kind: "chat" }> {
	return { kind: "chat", id: nextItemId++, from, text, mine, at: Date.now(), state: sendState };
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
	if (event.kind === "roster") {
		for (const name of members.keys()) members.set(name, false);
		for (const name of event.names) members.set(name, true);
	} else {
		members.set(event.name, event.kind === "join");
	}
	put({ ...conv, members });
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
export function setLiveRoom(name: string, count: number): void {
	const liveRooms = new Map(state.liveRooms);
	liveRooms.set(name, count);
	set({ liveRooms });
}
export function dropLiveRoom(name: string): void {
	const liveRooms = new Map(state.liveRooms);
	liveRooms.delete(name);
	set({ liveRooms });
}
export function resetLiveRooms(rooms: Iterable<readonly [string, number]>): void {
	set({ liveRooms: new Map(rooms) });
}
export function setDmable(name: string, reachable: boolean): void {
	const dmablePeers = new Set(state.dmablePeers);
	if (reachable) dmablePeers.add(name.toLowerCase());
	else dmablePeers.delete(name.toLowerCase());
	set({ dmablePeers });
}
export function clearDmable(): void {
	set({ dmablePeers: new Set() });
}

// ── Session, join card, chrome ────────────────────────────────────────────
/** The session changed. Only the two paths that open and lose one call this. */
export function setSession(session: SessionPhase): void {
	set({ session });
}
/** What the application is doing. Says nothing about the session's health, which
 * is why it cannot paint the dot. */
export function setStatus(statusText: string): void {
	set({ statusText });
}
export function setBanner(banner: string): void {
	set({ banner });
}
export function setDraft(draft: string): void {
	set({ draft });
}
export function setNick(nick: string): void {
	LS.set(KEY.nick, nick);
	set({ nick, draftNick: nick });
}
export function setJoinedRoom(joinedRoom: string | null): void {
	if (joinedRoom !== null) LS.set(KEY.room, joinedRoom);
	set({ joinedRoom });
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
export function setDrafts(patch: { draftRoom?: string; draftNick?: string }): void {
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

/** Collapse or restore the wide layout's rooms column. */
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
