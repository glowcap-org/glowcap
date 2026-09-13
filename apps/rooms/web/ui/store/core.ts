// The one place a page's presentation state lives.
//
// Everything the interface shows is a field here, and everything that changes it
// is a verb here. That is the whole rule, and it is worth stating because the
// alternative is what a browser makes easy: keeping half the truth in the DOM
// (is that class on the container? is that button disabled?) and the other half
// in module variables, then writing a third body of code whose only job is to
// keep the two agreeing. Reading a class back to decide what a control should
// announce is that code, and there is none of it here.
//
// A `RoomsPage` owns one `PageProjection`. Two pages in one isolate do not share
// drafts, conversations, rosters, histories, or unreads. The projection knows
// nothing about React and nothing about the wire. `hooks.ts` subscribes the
// components to the page's instance, and the session projection drives it from the CapTP side
// without importing a single view.

import type { Act, Edits, Remembered } from "../intent.ts";
import type { DraftPreview } from "../link_preview.ts";
import { createStore, type StoreApi } from "zustand/vanilla";
import type { ArchiveShareView, ArchiveTargetView } from "../archive_model.ts";
import type {
	RoomsSessionAccess,
	RoomsSessionGrantView,
	RoomsSessionPendingEffect,
} from "../../../lib/session/client.ts";
import type {
	AttachmentView,
	Conv,
	DiagnosticRow,
	DirId,
	DirView,
	Invitation,
	IrcGatewayState,
	Item,
	ListenerRow,
	MemberRef,
	OpsCap,
	PeeringState,
	RoomsOperatorState,
	SettingsTab,
	Standing,
	ToastNotice,
	TracePublishState,
	TroubleRow,
	Unread,
} from "../types.ts";

// Must match the `@media (max-width: 820px)` block in the rooms stylesheets:
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
	/** Per-link gesture and effect state. URLs come from the shared Markdown
	 * projection; identity survives unrelated typing, while stale outcomes can
	 * settle only the exact attempt that started them. */
	previews: readonly DraftPreview[];
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
export const NO_DRAFT: Draft = { text: "", files: [], previews: [] };

/** Nobody is composing. Shared so a conversation with no row and a missing
 * key compare equal by identity rather than allocating an empty set per read. */
export const NO_TYPERS: ReadonlySet<string> = new Set();

/** Nobody is in the room yet. Shared so a missing roster and an empty one
 * compare equal by identity rather than allocating a map per read. */
export const NO_MEMBERS: ReadonlyMap<string, Standing> = new Map();

/** The tabs of Help: what Rooms is, how to write a message, and the protocol
 * names for what the reader has been using. A control opens Help on one. */
export type HelpTab = "about" | "writing" | "glossary";

export interface State {
	/** The conversation on screen, or null while the join card is up. */
	activeKey: string | null;
	/** Every conversation this tab has open, keyed as `makeConv` describes.
	 *
	 * This is also the answer to which rooms we are in. A room conversation is
	 * made when the room admits us and forgotten when we leave, so membership has
	 * no separate field to disagree with it — and a tab is in as many rooms at
	 * once as it likes, the way it already holds as many direct lines. The rail's
	 * identity rows subscribe here. History, unread, drafts, typing, and rosters
	 * do not: a line, a keystroke, or a join must not rebuild Settings, overlays,
	 * and directory cards. */
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
	/** Ephemeral notices above the page, newest first. Not a directory's own
	 * standing: that belongs to the directory, is drawn on the rows that are on
	 * it, and stays until that directory says otherwise. */
	toasts: readonly ToastNotice[];
	/** Whether the tab is being looked at, and a count that rises each time it is
	 * returned to. One subscriber writes both; everything that asks reads here,
	 * so `document.hidden` is read in exactly one place in the tree (`hooks.ts`). */
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
	/** Who is composing in each conversation, keyed the way `convs` is.
	 *
	 * Not a field on the conversation: a typing flag is not identity, and putting
	 * it there replaces the conversation on every peer keystroke. Only the
	 * composer draws this, so it is its own map, forgotten with the conversation
	 * the way a draft is. */
	typers: ReadonlyMap<string, ReadonlySet<string>>;
	/** Who is in each room, keyed the way `convs` is.
	 *
	 * Not a field on the conversation: a roster is not identity, and putting it
	 * there replaces the conversation on every join, leave, or away word. The
	 * rail, the member column, and a direct line's away chip subscribe here; the
	 * shell does not. Forgotten with the conversation. */
	members: ReadonlyMap<string, ReadonlyMap<string, Standing>>;
	/** What was said in each conversation, keyed the way `convs` is.
	 *
	 * Not a field on the conversation: a line is not identity, and putting it
	 * there replaces the conversation on every arrival. The log and the viewer
	 * subscribe here; the shell keeps the open conversation's identity. Forgotten
	 * with the conversation. A missing row is an empty log. */
	histories: ReadonlyMap<string, readonly Item[]>;
	/** Unread marks for each conversation, keyed the way `convs` is.
	 *
	 * Not a field on the conversation: a badge is not identity, and putting it
	 * there replaces the conversation on every arrival in a room you are not
	 * looking at. The rail badges and the title total subscribe here. Forgotten
	 * with the conversation. A missing row is caught up. */
	unreads: ReadonlyMap<string, Unread>;
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
	 * Written when a join succeeds, never while one is being typed. The stored
	 * nickname remains checkpoint/reconnect history; the join form gets its
	 * current automatic offer from the connected directory instead. */
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
	/** Settings dialog: the query-param facts (DM transport, trace URL). */
	settingsOpen: boolean;
	/** Which Settings panel to show when the dialog mounts. */
	settingsTab: SettingsTab;
	/** The glossary modal, which Settings closes beneath. */
	helpOpen: boolean;
	/** The Help tab on screen, kept across closings the way `settingsTab` is,
	 * and set outright by a control that opens Help on a tab. */
	helpTab: HelpTab;
	/** The bridged channels the IRC gateway last listed, or null while this
	 * tab holds no gateway capability. Same split as its siblings: Rust
	 * holds the reference, this is only what to draw. */
	irc: IrcGatewayState | null;
	/** Room stewardships reported by the held Rooms operator capability. */
	operator: RoomsOperatorState | null;
	/** Durable session operations awaiting explicit recovery. Bearer results stay in the session owner. */
	sessionEffects: readonly RoomsSessionPendingEffect[];
	/** Restart-stable attenuated grants visible only through session administration. */
	sessionGrants: readonly RoomsSessionGrantView[];
	/** What the shared session this browser is attached to lets it do now,
	 * including nothing at all while that access is suspended. Null when this
	 * browser owns its own session. */
	sessionAccess: RoomsSessionAccess | null;
	/** Why this browser's access to a shared session carries nothing, when it
	 * carries nothing. Empty otherwise. A link that has gone quiet has to be able
	 * to account for itself, or the application simply looks broken. */
	sessionSuspendedNote: string;
	/** Whether the selected archive keeps room and direct-message history. The
	 * Rust archive behind the session owns the bytes; this is only what the
	 * switch draws. */
	keepHistory: boolean;
	/** Where new member-owned history is written. Live archive authority stays
	 * below the store; this is only the connection state Settings draws. */
	archiveTarget: ArchiveTargetView;
	/** Read-only history accounts another member handed this tab. The
	 * references and any lasting link stay below the store; these rows only
	 * draw the read and drop choices. */
	archiveShares: readonly ArchiveShareView[];
	/** The page's bounded trouble journal, newest first; `store/trouble.ts`
	 * owns the ring. */
	trouble: readonly TroubleRow[];
	/** Which operations pane is selected while more than one is held. */
	opsPane: OpsCap;
	/** What the inspect capability last said, or null while this tab holds none.
	 * Holding the live reference is the Rust application's job; this is only what to draw. */
	diagnostics: readonly DiagnosticRow[] | null;
	/** The live listeners the admin capability last reported, or null while
	 * this tab holds none. Same split as `diagnostics`: Rust holds the
	 * reference, this is only what to draw. */
	listeners: readonly ListenerRow[] | null;
	/** The durable rooms this tab has published here while it holds the peering
	 * capability, or null while it holds none. Same split again: Rust holds
	 * the authority and each publication's lease, this is only what to draw. */
	peering: PeeringState | null;
	/** Where this session publishes its own trace while it holds the trace
	 * capability, or null while it holds none. A local tab owns the publisher;
	 * a shared session projects the durable one. This is only what to draw. */
	trace: TracePublishState | null;
	/** The directory whose card is open, or null. */
	aboutDir: DirId | null;
	/** Whether that card opened already asking to leave the directory. */
	aboutDirLeave: boolean;
	/** The person whose card is open, or null. */
	aboutMember: MemberRef | null;
	/** The rest of a long refusal, while its card is up. */
	errorDetail: { title: string; text: string } | null;
	/** Whether the card about the conversation on screen is up. */
	aboutConv: boolean;
	/** Whether that card opened already asking to leave the conversation. */
	aboutConvLeave: boolean;
	/** Which room-specific surface asked to open that card. Ordinary title and
	 * /details routes use About; the reader's roster row opens the bridge
	 * identity tab directly. */
	aboutConvPane: "about" | "bridge" | "capabilities";
	/** Changes for every request to open the conversation card, including a
	 * repeated request for the same pane while its retained dialog still exists. */
	aboutConvRequest: number;
	/** The posted file being viewed full-screen, named by the line that carries
	 * it rather than copied out of it. The viewer draws from the line, so
	 * bytes that arrive while it is open reach it without a second copy of the
	 * same fact going stale behind them. */
	viewing: { key: string; id: number } | null;
}

/** A fresh empty projection. Each page starts from its own maps and document
 * facts, so two pages cannot share an empty conversation map by identity. */
export function initialState(): State {
	return {
		activeKey: null,
		standing: "",
		invites: [],
		convs: new Map(),
		dirs: new Map(),
		homeDir: null,
		toasts: [],
		visible: true,
		returns: 0,
		mobile: mobileQuery.matches,
		drafts: new Map(),
		lastSent: new Map(),
		typers: new Map(),
		members: new Map(),
		histories: new Map(),
		unreads: new Map(),
		ignored: new Set(),
		// The page opening is this browser reopening what it had, and it names
		// nothing: every field falls through to what was remembered, which is the
		// cold open a returning reader expects. The first act a reader files
		// supersedes it.
		reaching: { source: "restore", seq: 0 },
		edits: { seq: 0 },
		remembered: { room: "", locator: "", nick: "" },
		// Syrup by default. The dark face is the product's own, not a
		// concession to a desktop setting, so a reader who has never
		// touched the switch gets it and the stylesheet agrees with this
		// line before the bundle has run. Light is one press away and it
		// is remembered.
		theme: "dark",
		notifyOn: false,
		railOpen: true,
		listScreen: false,
		rosterOpen: true,
		rosterSheet: false,
		settingsOpen: false,
		// The panel selections survive a reload: a reader working the
		// Holdings toggles or one operations pane lands back where they were.
		settingsTab: "session",
		helpOpen: false,
		helpTab: "about",
		opsPane: "listeners",
		keepHistory: true,
		archiveTarget: { kind: "owned", owner: "browser" },
		archiveShares: [],
		irc: null,
		operator: null,
		sessionEffects: [],
		sessionGrants: [],
		sessionAccess: null,
		sessionSuspendedNote: "",
		trouble: [],
		diagnostics: null,
		listeners: null,
		peering: null,
		trace: null,
		aboutDir: null,
		aboutDirLeave: false,
		aboutMember: null,
		errorDetail: null,
		aboutConv: false,
		aboutConvLeave: false,
		aboutConvPane: "about",
		aboutConvRequest: 0,
		viewing: null,
	};
}

type LineRecorder = (conv: Conv, item: Item, change?: "withdrawn" | "edited") => void;

/** One page's non-authoritative presentation. Domain verbs take this instance;
 * React observes `api` through the page's provider. */
export class PageProjection {
	readonly api: StoreApi<State>;
	readonly #abort = new AbortController();
	#nextItemId = 0;
	#nextToastId = 1;
	#introductions = 0;
	#heldRooms = 0;
	#lettingGo: ((key: string, gone: readonly Item[]) => void) | null = null;
	#lineRecorder: LineRecorder | null = null;

	constructor() {
		this.api = createStore<State>()(() => initialState());
		const { signal } = this.#abort;
		// The layout is a query, not a document, and the store's own verbs depend
		// on it: which field "show the rooms list" writes is decided here. Whether
		// the tab is being *looked at* is a document fact, so `hooks.ts` subscribes
		// to that one and reports it through `noteVisibility`.
		mobileQuery.addEventListener("change", (e) => {
			this.set({ mobile: e.matches });
		}, { signal });
	}

	/** Stop mirroring layout queries. A page that outlives the tab does not call
	 * this; tests that construct many projections do. */
	dispose(): void {
		this.#abort.abort();
	}

	/** The current state.
	 *
	 * Read-only all the way down, so "never write through it" is a thing the
	 * compiler refuses rather than a rule a reader has to keep. Every write
	 * already copies before it mutates; this is what stops the next one from
	 * forgetting, and it is the whole of the one-authority claim above. */
	get(): Readonly<State> {
		return this.api.getState();
	}

	/** Replace the named fields and tell every reader. The object identity
	 * changes on every write, which is how React knows to look again. */
	set(patch: Partial<State>): void {
		this.api.setState(patch);
	}

	subscribe(listener: () => void): () => void {
		return this.api.subscribe(listener);
	}

	/** Empty presentation and presentation counters. Recorder and line-drop
	 * wiring stay: those are I/O seats, not snapshot fields. */
	reset(): void {
		this.#nextItemId = 0;
		this.#nextToastId = 1;
		this.#introductions = 0;
		this.#heldRooms = 0;
		this.api.setState(initialState(), true);
	}

	/** Report whether the tab is being looked at.
	 *
	 * The count rises on the change to visible, not on every report, so telling
	 * the projection what it already believes is free, and construction can
	 * sync the real value without it reading as a return. */
	noteVisibility(visible: boolean): void {
		const state = this.get();
		if (state.visible === visible) return;
		this.set({ visible, returns: visible ? state.returns + 1 : state.returns });
	}

	/** Hear about lines this tab is giving up.
	 *
	 * A line carries things the projection knows nothing about: the URL a
	 * picture is drawn from, the capability its bytes come from, the reference
	 * that governs one of our own. The projection knows when a line stops being
	 * drawn and nothing about what it was holding; the data layer knows the
	 * opposite, so it listens here.
	 *
	 * Lines leave three ways and only two of them are the log's doing: the
	 * scrollback passing its far end, a reader emptying a conversation, and a
	 * conversation being forgotten outright. */
	onLinesDropped(hook: (key: string, gone: readonly Item[]) => void): () => void {
		this.#lettingGo = hook;
		return () => {
			if (this.#lettingGo === hook) this.#lettingGo = null;
		};
	}

	/** Give `gone` up, from whichever of those three ways it was. */
	letLinesGo(key: string, gone: readonly Item[]): void {
		if (gone.length > 0) this.#lettingGo?.(key, gone);
	}

	setLineRecorder(fn: LineRecorder | null): void {
		this.#lineRecorder = fn;
	}

	recordLine(conv: Conv, item: Item, change?: "withdrawn" | "edited"): void {
		this.#lineRecorder?.(conv, item, change);
	}

	allocItemId(): number {
		return this.#nextItemId++;
	}

	allocToastId(): number {
		return this.#nextToastId++;
	}

	nextIntroduction(): number {
		this.#introductions += 1;
		return this.#introductions;
	}

	nextHeldRoom(): string {
		this.#heldRooms += 1;
		return "held:" + this.#heldRooms;
	}
}

/** Projection the page shell reads. Drafts, last-sent recall, typing flags,
 * rosters, history, unread, and the conversation map stay out so a keystroke,
 * a join, or a line does not rebuild Settings, overlays, and directory cards. */
export function appShellState({
	drafts: _drafts,
	lastSent: _lastSent,
	typers: _typers,
	members: _members,
	histories: _histories,
	unreads: _unreads,
	convs: _convs,
	...state
}: State): Omit<State, "drafts" | "lastSent" | "typers" | "members" | "histories" | "unreads" | "convs"> {
	return state;
}

/** The conversation on screen. Identity is preserved when history is replaced. */
export function activeConvOf(state: Pick<State, "activeKey" | "convs">): Conv | null {
	return state.activeKey == null ? null : state.convs.get(state.activeKey) ?? null;
}

/** Unread lines across every conversation, for the title and the rail toggle. */
export function unreadTotal(state: Pick<State, "unreads">): number {
	let total = 0;
	for (const unread of state.unreads.values()) {
		if (unread.kind === "unread") total += unread.count;
	}
	return total;
}
