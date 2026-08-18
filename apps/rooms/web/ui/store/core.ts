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

import type { Act, Edits, Remembered } from "../intent.ts";
import {
	type AttachmentView,
	type Banner,
	type Conv,
	type DiagnosticRow,
	type DirId,
	type DirView,
	type Invitation,
	type ListenerRow,
	type OpsCap,
	type SettingsTab,
	type ToastNotice,
	type VizPublishState,
} from "../types.ts";
// Small, swallow-errors localStorage wrapper (private-mode / disabled storage).
// What this page remembers between visits, and under what names. One table
// because a get and a set that disagree by a character fail silently and look
// like a preference that will not stick. `rooms.theme` is read a second time by
// the small script in page.html, which stamps the palette before the first paint
// and so cannot wait for this module; renaming it here means renaming it there.
// Direct-message transport and the ocapnviz WebSocket live in prefs.ts
// (`rooms.dm`, `rooms.viz`): they reload the peer, so they are not store fields.
export const KEY = {
	nick: "rooms.nick",
	room: "rooms.room",
	locator: "rooms.locator",
	theme: "rooms.theme",
	notify: "rooms.notify",
	ignored: "rooms.ignored",
	settingsTab: "rooms.settings-tab",
	opsTab: "rooms.ops-tab",
} as const;

// Persistence lives beside the verbs that own each fact, so nothing outside this
// file reaches for storage.
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
	remove(k: string): void {
		try {
			localStorage.removeItem(k);
		} catch { /* storage disabled (private mode); ignore */ }
	},
};

/** The persisted ignore list, whatever shape this browser last wrote.
 *
 * JSON, because the list holds whatever names foreign directories grant and a
 * delimiter is a character a name may contain: stored as comma-joined, a name
 * with a comma in it re-split on the next visit into fragments — silently
 * un-ignoring the member and ignoring two innocents, the exact vanishing this
 * list's own fix just paid for. The comma fallback reads what older visits
 * wrote, so nobody's list is lost to the encoding change. */
export function readPersistedIgnored(): Set<string> {
	return readIgnored(LS.get(KEY.ignored));
}

export function readIgnored(raw: string | null): Set<string> {
	if (raw === null || raw === "") return new Set();
	try {
		const parsed: unknown = JSON.parse(raw);
		if (Array.isArray(parsed)) {
			return new Set(parsed.filter((name): name is string => typeof name === "string"));
		}
	} catch {
		// Not JSON: an older visit's comma-joined list.
	}
	return new Set(raw.split(",").filter(Boolean));
}

// Must match the `@media (max-width: 820px)` block in the rooms stylesheets:
// the grid into the list/conversation stack, and this decides which layout's
// field a control writes. They are two files that have to agree.
export const mobileQuery = matchMedia("(max-width: 820px)");

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
	/** The files of the line being changed that the reader is keeping, when the
	 * change is to a file line rather than a plain one. Present only while
	 * changing a line with files: it is what turns the composer into a view of
	 * that line's files, with the new ones in `files` added after them. A × on a
	 * chip drops it from here; sending refiles the line to exactly this set. */
	keeping?: readonly AttachmentView[];
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
	/** Ephemeral notices above the page, newest first. Not the conversation
	 * banner: that is session status and stays until the session says otherwise. */
	toasts: readonly ToastNotice[];
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
	/** Names this window does not show lines from, folded. See `ignore`. */
	ignored: ReadonlySet<string>;
	/** Last composer text successfully submitted in each conversation, including
	 * slash commands that never appear as chat. Forgotten with the conversation. */
	lastSent: ReadonlyMap<string, string>;
	/** Rooms somebody has offered this tab and it has not answered yet, oldest
	 * first. Empty for almost every reader almost always.
	 *
	 * Rows survive a directory reconnect. For a link offer that is simply true —
	 * a link is data. A handed offer's reference may have died with the wire
	 * that carried it, and the row stays anyway: taking it up then fails with a
	 * sentence saying the offer is spent, which beats silently deleting a row
	 * whose reference may in fact have survived on its own session. */
	invites: readonly Invitation[];
	/** The act the join card is answering: how the reader got in front of it,
	 * and what that act named. See `intent.ts` for why this is recorded instead
	 * of the fields it decides. */
	reaching: Act;
	/** What the reader has changed by hand, and which act they were answering.
	 * An override made under an older act is not read, so going somewhere else
	 * drops it without anybody clearing anything. */
	edits: Edits;
	/** What this browser did last, offered only where no act has an answer.
	 * Written when a join succeeds, never while one is being typed. */
	remembered: Remembered;
	theme: "light" | "dark";
	notifyOn: boolean;
	/** Where this reader stands everywhere: empty for here, otherwise why they
	 * stepped out. The outermost of the three levels `standingFor` reads.
	 *
	 * Not remembered between visits, deliberately. A reload is a fresh membership
	 * in every room, and coming back to a page that quietly tells everyone you are
	 * away is worse than saying it again. */
	standing: string;
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
	/** Which Settings panel to show when the dialog mounts. */
	settingsTab: SettingsTab;
	/** The glossary modal, which Settings closes beneath. */
	helpOpen: boolean;
	/** The Operations modal, which Settings closes beneath the same way. */
	opsOpen: boolean;
	/** Which operations pane is selected while more than one is held. */
	opsTab: OpsCap;
	/** Which capability's take modal is up, opened by flipping its Advanced
	 * toggle on. The toggle itself lands on only when the take succeeds:
	 * possession is derived from the row fields below, never stored beside
	 * them. */
	opsTake: OpsCap | null;
	/** What the inspect capability last said, or null while this tab holds none.
	 * Holding the live reference is net.ts's job; this is only what to draw. */
	diagnostics: readonly DiagnosticRow[] | null;
	/** The live listeners the admin capability last reported, or null while
	 * this tab holds none. Same split as `diagnostics`: net.ts holds the
	 * reference, this is only what to draw. */
	listeners: readonly ListenerRow[] | null;
	/** Where this tab publishes its own trace while it holds the viz
	 * capability, or null while it holds none. Same split again: net.ts owns
	 * the publisher and the swiss, this is only what to draw. */
	viz: VizPublishState | null;
	/** The directory whose card is open, or null. */
	aboutDir: DirId | null;
	/** The posted file being viewed full-screen, named by the line that carries
	 * it rather than copied out of it. The viewer draws from the line, so
	 * bytes that arrive while it is open reach it without a second copy of the
	 * same fact going stale behind them. */
	viewing: { key: string; id: number } | null;
}

export const initial: State = {
	activeKey: null,
	standing: "",
	invites: [],
	convs: new Map(),
	dirs: new Map(),
	homeDir: null,
	banner: null,
	toasts: [],
	visible: true,
	returns: 0,
	mobile: mobileQuery.matches,
	drafts: new Map(),
	lastSent: new Map(),
	ignored: readIgnored(LS.get(KEY.ignored)),
	// The page opening is this browser reopening what it had, and it names
	// nothing: every field falls through to what was remembered, which is the
	// cold open a returning reader expects. The first act a reader files
	// supersedes it.
	reaching: { source: "restore", seq: 0 },
	edits: { seq: 0 },
	remembered: {
		room: LS.get(KEY.room) ?? "",
		locator: LS.get(KEY.locator) ?? "",
		nick: LS.get(KEY.nick) ?? "",
	},
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
	// The panel selections survive a reload: a reader working the Advanced
	// toggles or one operations pane lands back where they were.
	settingsTab: (LS.get(KEY.settingsTab) === "settings" ? "settings" : "overview") as State["settingsTab"],
	helpOpen: false,
	opsOpen: false,
	opsTab:
		(["listeners", "diagnostics", "viz"].includes(LS.get(KEY.opsTab) ?? "")
			? LS.get(KEY.opsTab)
			: "listeners") as State["opsTab"],
	opsTake: null,
	diagnostics: null,
	listeners: null,
	viz: null,
	aboutDir: null,
	viewing: null,
};

/** The live state. Read it; only `set` writes it, which is what keeps the one
 * authority claim above true across the modules that share this. */
export let state: State = initial;
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
export function set(patch: Partial<State>): void {
	state = { ...state, ...patch };
	for (const listener of listeners) listener();
}
