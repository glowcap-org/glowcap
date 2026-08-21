// What was said in a conversation: lines, files, and the unread mark.
//
// The store owns the log and knows nothing about capabilities or object URLs.
// Callers reach these through `store.ts`.

import { MAX_SCROLLBACK } from "../../../lib/limits.ts";
import { silencedByIgnore } from "../types.ts";
import type { AttachmentView, DirId, Item, SendState, SysAudience, Unread } from "../types.ts";
import { letLinesGo, set, state } from "./core.ts";
import { getConv, patch, put } from "./convs.ts";

let nextItemId = 0;

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
export function sysItem(text: string, audience: SysAudience = "here"): Item {
	return { kind: "sys", id: nextItemId++, text, at: Date.now(), audience };
}

/** Add one line to a conversation.
 *
 * A conversation nobody is reading counts the line as unread and remembers where
 * the unread run started, which is where the log draws its rule. System lines
 * and notices are not counted, whether they are this tab talking to itself or
 * the room saying something about itself.
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
/** Told when lines leave the far end of a conversation, so whoever holds what
 * they carried can let it go. The store owns the log and knows nothing about
 * capabilities or object URLs; the network layer owns those and knows nothing
 * about when a line stops being drawn. This is the one seam between them. */
export function deliver(key: string, item: Item): void {
	const conv = getConv(key);
	if (!conv) return;
	const read = key === state.activeKey && state.visible;
	// A line the reader will never see must not be counted at them: an unread
	// badge that clears to nothing teaches a reader to stop trusting the badge.
	const counts = (item.kind === "chat" || item.kind === "action") &&
		!silencedByIgnore(item, state.ignored);
	const history = [...conv.history, item];
	// Past the bound, the oldest go. How much a room says is the room's own
	// choice, and this window's log grew with it for as long as the tab was open.
	const over = history.length - MAX_SCROLLBACK;
	const gone = over > 0 ? history.splice(0, over) : [];
	let unread = read || !counts ? conv.unread : count(conv.unread, item.id);
	// A run of unread lines that began before the far end still began: the rule
	// hangs on the oldest line there is rather than on one nobody can scroll to.
	if (unread.kind !== "caught-up") {
		const anchor = unread.from;
		if (gone.some((left) => left.id === anchor)) {
			unread = { ...unread, from: history[0]?.id ?? item.id };
		}
	}
	put(patch(conv, { history, unread }));
	letLinesGo(key, gone);
}

/** One more unread line. A run that is already going keeps the line it started
 * on; a rule still up from the last visit adopts that same line, so arriving,
 * reading, and being interrupted again does not move the mark up the log. */
function count(unread: Unread, at: number): Unread {
	if (unread.kind === "unread") return { ...unread, count: unread.count + 1 };
	return { kind: "unread", count: 1, from: unread.kind === "rule-only" ? unread.from : at };
}

/** Deliver to the conversation on screen, for a notice about this tab itself. */
/** Deliver into whatever conversation is on screen, and say whether one was.
 *
 * The answer matters to a caller latching "already said": a truth delivered
 * while the join card is up reaches nobody, and latching it anyway guarantees
 * it is never said at all. */
export function deliverActive(item: Item): boolean {
	if (!state.activeKey) return false;
	deliver(state.activeKey, item);
	return true;
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
/** Empty this conversation's history in this window.
 *
 * Yours and only yours: the room keeps what was said and hands it back on the
 * way in again, so this is a window being tidied rather than anything being
 * destroyed. That is the whole reason it needs no permission — there is nothing
 * here to ask anybody about. */
export function clearHistory(key: string): void {
	const conv = getConv(key);
	if (conv === null || conv.history.length === 0) return;
	const gone = conv.history;
	put({ ...conv, history: [] });
	// The third way lines leave the log, through the same door as the other
	// two: the scrollback trim and a closing conversation both hand what their
	// departing lines were holding — object URLs, blob capabilities, the
	// references governing our own lines — to the release seam. Bypassing it
	// here kept all of that alive until the directory session ended, for a
	// reader who had just asked for the room to be emptied.
	letLinesGo(key, gone);
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
			else drafts.set(conv.key, { ...draft, changing: undefined, keeping: undefined });
			set({ drafts });
			stoppedChanging.push(conv.key);
		}
	}
	return stoppedChanging;
}
