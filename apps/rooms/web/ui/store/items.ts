// What was said in a conversation: lines, files, and the unread mark.
//
// The store owns the log and knows nothing about capabilities or object URLs.
// Callers reach these through `store.ts`. History and unread are maps on the
// page projection, not fields on the conversation: a line is not identity.

import { MAX_SCROLLBACK } from "../limits.ts";
import { CAUGHT_UP, NO_HISTORY, silencedByIgnore } from "../types.ts";
import type { AttachmentView, DirId, HistoryCoordinate, Item, SendState, SysAudience, Unread } from "../types.ts";
import type { PageProjection, State } from "./core.ts";
import { getConv } from "./convs.ts";

export function historyOf(
	projection: PageProjection,
	key: string | null,
	s: Readonly<Pick<State, "histories">> = projection.get(),
): readonly Item[] {
	return key == null ? NO_HISTORY : s.histories.get(key) ?? NO_HISTORY;
}

export function unreadOf(
	projection: PageProjection,
	key: string | null,
	s: Readonly<Pick<State, "unreads">> = projection.get(),
): Unread {
	return key == null ? CAUGHT_UP : s.unreads.get(key) ?? CAUGHT_UP;
}

function writeHistory(
	projection: PageProjection,
	key: string,
	history: readonly Item[],
	unread?: Unread,
): void {
	const state = projection.get();
	const histories = new Map(state.histories);
	if (history.length === 0) histories.delete(key);
	else histories.set(key, history);
	if (unread === undefined) {
		projection.set({ histories });
		return;
	}
	const unreads = new Map(state.unreads);
	if (unread.kind === "caught-up") unreads.delete(key);
	else unreads.set(key, unread);
	projection.set({ histories, unreads });
}

function writeUnread(projection: PageProjection, key: string, unread: Unread): void {
	const unreads = new Map(projection.get().unreads);
	if (unread.kind === "caught-up") unreads.delete(key);
	else unreads.set(key, unread);
	projection.set({ unreads });
}

/** Keep an unread run attached to a row the reader can still reach. History
 * can lose rows through live scrollback, prefix restoration, or chronological
 * reconciliation; clearing the whole log clears a mark with nowhere to stand. */
function repairUnreadAfterDrop(unread: Unread, history: readonly Item[], gone: readonly Item[]): Unread {
	if (unread.kind === "caught-up" || !gone.some((item) => item.id === unread.from)) return unread;
	return history.length === 0 ? CAUGHT_UP : { ...unread, from: history[0].id };
}

// ── Message items ─────────────────────────────────────────────────────────
export function chatItem(
	projection: PageProjection,
	from: string,
	text: string,
	mine: boolean,
	sendState?: SendState,
	attachments?: readonly AttachmentView[],
	at = Date.now(),
): Extract<Item, { kind: "chat" }> {
	return {
		kind: "chat",
		id: projection.allocItemId(),
		from,
		text,
		mine,
		at,
		state: sendState,
		attachments,
	};
}

/** Give a file its own UI identity. Message ids locate bubbles; attachment ids
 * locate independently transferring capabilities inside them. Both come from
 * one tab-local sequence so no data-layer map can confuse the two. */
export function attachmentView(projection: PageProjection, fields: Omit<AttachmentView, "id">): AttachmentView {
	return { id: projection.allocItemId(), ...fields };
}

export type AttachmentFields = Omit<Partial<AttachmentView>, "id">;

/** Change any number of files in one conversation with one history scan, one
 * immutable copy, and one store notification. Parallel transfers arrive as a
 * batch because network chunk cadence is not presentation cadence. */
export function updateAttachments(
	projection: PageProjection,
	key: string,
	updates: ReadonlyMap<number, AttachmentFields>,
): void {
	if (updates.size === 0) return;
	if (getConv(projection, key) == null) return;
	const current = historyOf(projection, key);
	let history: Item[] | null = null;
	for (let at = 0; at < current.length; at++) {
		const item = current[at];
		if (item.kind !== "chat" || item.attachments === undefined) continue;
		let changed = false;
		const attachments = item.attachments.map((attachment) => {
			const fields = updates.get(attachment.id);
			if (fields === undefined) return attachment;
			changed = true;
			return { ...attachment, ...fields, id: attachment.id };
		});
		if (!changed) continue;
		if (history === null) history = current.slice();
		history[at] = { ...item, attachments };
	}
	if (history !== null) writeHistory(projection, key, history);
}

/** Change one file. Terminal state changes use this focused form; progress
 * callbacks use `updateAttachments` through the frame coalescer in the session projection. */
export function updateAttachment(projection: PageProjection, key: string, id: number, fields: AttachmentFields): void {
	updateAttachments(projection, key, new Map([[id, fields]]));
}
export function sysItem(projection: PageProjection, text: string, audience: SysAudience = "here"): Item {
	return { kind: "sys", id: projection.allocItemId(), text, at: Date.now(), audience };
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
 * memoised on exactly that identity. Past `MAX_SCROLLBACK`, the oldest lines
 * leave through the same release seam a closing conversation uses. */
export function deliver(projection: PageProjection, key: string, item: Item): void {
	const conv = getConv(projection, key);
	if (!conv) return;
	const state = projection.get();
	const read = key === state.activeKey && state.visible;
	// A line the reader will never see must not be counted at them: an unread
	// badge that clears to nothing teaches a reader to stop trusting the badge.
	const counts = (item.kind === "chat" || item.kind === "action") &&
		!silencedByIgnore(item, state.ignored);
	const history = [...historyOf(projection, key, state), item];
	// Past the bound, the oldest go. How much a room says is the room's own
	// choice, and this window's log grew with it for as long as the tab was open.
	const over = history.length - MAX_SCROLLBACK;
	const gone = over > 0 ? history.splice(0, over) : [];
	const admittedUnread = read || !counts
		? unreadOf(projection, key, state)
		: count(unreadOf(projection, key, state), item.id);
	// A run of unread lines that began before the far end still began: the rule
	// hangs on the oldest line there is rather than on one nobody can scroll to.
	const unread = repairUnreadAfterDrop(admittedUnread, history, gone);
	writeHistory(projection, key, history, unread);
	projection.letLinesGo(key, gone);
	if (item.kind !== "chat" || item.state == null) projection.recordLine(conv, item);
}

interface HistoryLine {
	from: string;
	text: string;
	mine: boolean;
	at: number;
	lineId?: number;
	history?: HistoryCoordinate;
	order?: number;
	edited?: boolean;
	attachments?: readonly (Omit<AttachmentView, "id"> | AttachmentView)[];
}

function historyItems(projection: PageProjection, lines: readonly HistoryLine[]): Item[] {
	return lines.map((line) => {
		const attachments = line.attachments?.map((attachment) =>
			"id" in attachment ? attachment : attachmentView(projection, attachment)
		);
		return {
			kind: "chat",
			id: projection.allocItemId(),
			from: line.from,
			text: line.text,
			mine: line.mine,
			at: line.at,
			...(line.lineId == null ? {} : { lineId: line.lineId }),
			...(line.history == null ? {} : { history: line.history }),
			...(line.order == null ? {} : { order: line.order }),
			...(line.edited == null ? {} : { edited: line.edited }),
			...(attachments == null || attachments.length === 0 ? {} : { attachments }),
		};
	});
}

export function historyCoordinateKey(coordinate: HistoryCoordinate): string {
	return `${coordinate.source}\u0000${coordinate.generation}\u0000${coordinate.id}`;
}

function chronologicalOrder(left: Item, right: Item): number {
	if (left.at !== right.at) return left.at - right.at;
	const leftHistory = left.kind === "chat" ? left.history : undefined;
	const rightHistory = right.kind === "chat" ? right.history : undefined;
	const leftOrder = left.kind === "chat" ? left.order ?? 0 : 0;
	const rightOrder = right.kind === "chat" ? right.order ?? 0 : 0;
	if (
		leftHistory && rightHistory && leftHistory.source === rightHistory.source &&
		leftHistory.generation === rightHistory.generation && leftOrder && rightOrder
	) {
		return leftOrder - rightOrder;
	}
	if (!!leftHistory !== !!rightHistory) return leftHistory ? -1 : 1;
	return 0;
}

/** Restore remembered lines and their attribution without counting them as
 * unread. Independent history accounts are prefixes. */
export function restoreHistory(
	projection: PageProjection,
	key: string,
	lines: readonly HistoryLine[],
	divider: string,
): void {
	if (getConv(projection, key) == null || lines.length === 0) return;
	const stood = historyItems(projection, lines);
	stood.push({ kind: "sys", id: projection.allocItemId(), text: divider, at: Date.now(), audience: "shared" });
	const combined = [...stood, ...historyOf(projection, key)];
	const over = combined.length - MAX_SCROLLBACK;
	const gone = over > 0 ? combined.splice(0, over) : [];
	const unread = repairUnreadAfterDrop(unreadOf(projection, key), combined, gone);
	writeHistory(projection, key, combined, unread);
	projection.letLinesGo(key, gone);
}

/** Change one drawn line from an archive account's current truth, without
 * naming it a line change. An archive re-read revising what it already showed
 * is not the reader editing and must not reach the line recorder: recording
 * it would write somebody's account back into an archive it was read from. */
export function reviseItem(projection: PageProjection, key: string, id: number, fields: Partial<Item>): void {
	const conv = getConv(projection, key);
	if (!conv) return;
	const current = historyOf(projection, key);
	const at = current.findIndex((item) => item.id === id);
	if (at < 0) return;
	const history = current.slice();
	history[at] = { ...history[at], ...fields } as Item;
	writeHistory(projection, key, history);
}

/** Insert newly seen lines and reorder the account's existing section by its
 * own chronology. Full recorder coordinates identify the divider independently
 * of its display text; a standing-only account can have an empty section. */
export function insertArchiveLines(
	projection: PageProjection,
	key: string,
	lines: readonly HistoryLine[],
	divider: string,
	section: Pick<HistoryCoordinate, "source" | "generation">,
): void {
	if (getConv(projection, key) == null) return;
	const current = historyOf(projection, key);
	const stood: Item[] = historyItems(projection, lines);
	const matches = (coordinate: Pick<HistoryCoordinate, "source" | "generation"> | undefined) =>
		coordinate?.source === section.source && coordinate.generation === section.generation;
	const dividerAt = current.findIndex((item) => item.kind === "sys" && matches(item.archiveSection));
	const prior = current[dividerAt];
	const dividerItem: Item = prior?.kind === "sys" ? (prior.text === divider ? prior : { ...prior, text: divider }) : {
		kind: "sys",
		id: projection.allocItemId(),
		text: divider,
		at: Date.now(),
		audience: "shared",
		archiveSection: { source: section.source, generation: section.generation },
	};
	let start = dividerAt;
	while (start > 0) {
		const item = current[start - 1];
		if (item.kind !== "chat" || !matches(item.history)) break;
		start -= 1;
	}
	const rows = dividerAt < 0 ? stood : [...current.slice(start, dividerAt), ...stood];
	rows.sort(chronologicalOrder);
	const combined: Item[] = dividerAt < 0
		? [...rows, dividerItem, ...current]
		: [...current.slice(0, start), ...rows, dividerItem, ...current.slice(dividerAt + 1)];
	if (combined.length === current.length && combined.every((item, index) => item === current[index])) return;
	const over = combined.length - MAX_SCROLLBACK;
	const gone = over > 0 ? combined.splice(0, over) : [];
	const unread = repairUnreadAfterDrop(unreadOf(projection, key), combined, gone);
	writeHistory(projection, key, combined, unread);
	projection.letLinesGo(key, gone);
}

/** Merge the attached session's own archive into its live log. Unlike a
 * separately shared history prefix, these rows fill gaps on either side of
 * live rows. The conversation's own order resolves equal timestamps; archive
 * coordinates remain identity-only. */
export function reconcileHistory(
	projection: PageProjection,
	key: string,
	lines: readonly HistoryLine[],
	divider: string,
): void {
	if (getConv(projection, key) == null) return;
	const stood = historyItems(projection, lines).sort(chronologicalOrder);
	const current = historyOf(projection, key);
	const boundaryAt = current.findIndex((item) => item.kind === "sys" && item.historyBoundary === "session");
	let base: readonly Item[] = current;
	if (boundaryAt >= 0) {
		const boundary = current[boundaryAt];
		if (boundary.text !== divider) {
			const updated = current.slice();
			updated[boundaryAt] = { ...boundary, text: divider };
			base = updated;
		}
	} else if (stood.length > 0) {
		stood.push({
			kind: "sys",
			id: projection.allocItemId(),
			text: divider,
			at: stood[stood.length - 1].at,
			audience: "shared",
			historyBoundary: "session",
		});
	}
	const combined = [...base, ...stood].sort(chronologicalOrder);
	if (combined.length === current.length && combined.every((item, index) => item === current[index])) return;
	const over = combined.length - MAX_SCROLLBACK;
	const gone = over > 0 ? combined.splice(0, over) : [];
	const unread = repairUnreadAfterDrop(unreadOf(projection, key), combined, gone);
	writeHistory(projection, key, combined, unread);
	projection.letLinesGo(key, gone);
}

/** One more unread line. A run that is already going keeps the line it started
 * on; a rule still up from the last visit adopts that same line, so arriving,
 * reading, and being interrupted again does not move the mark up the log. */
function count(unread: Unread, at: number): Unread {
	if (unread.kind === "unread") return { ...unread, count: unread.count + 1 };
	return { kind: "unread", count: 1, from: unread.kind === "rule-only" ? unread.from : at };
}

/** Deliver into whatever conversation is on screen, and say whether one was.
 *
 * The answer matters to a caller latching "already said": a truth delivered
 * while the join card is up reaches nobody, and latching it anyway guarantees
 * it is never said at all. */
export function deliverActive(projection: PageProjection, item: Item): boolean {
	const key = projection.get().activeKey;
	if (key == null) return false;
	deliver(projection, key, item);
	return true;
}

/** Change one line in place, by id. This is how the data layer moves a message
 * between sending, failed, and confirmed: it holds the id, never a DOM node. */
export function updateItem(projection: PageProjection, key: string, id: number, fields: Partial<Item>): void {
	const conv = getConv(projection, key);
	if (!conv) return;
	const current = historyOf(projection, key);
	const at = current.findIndex((item) => item.id === id);
	if (at < 0) return;
	const previous = current[at];
	const history = current.slice();
	history[at] = { ...history[at], ...fields } as Item;
	writeHistory(projection, key, history);
	// Kept history follows a line's life: a withdrawal or an edit on a chat
	// line reaches the recorder, so a kept copy cannot outlive a takedown.
	const changed = historyOf(projection, key).find((item) => item.id === id);
	if (changed !== undefined && changed.kind === "chat") {
		const change = fields as { withdrawn?: boolean; text?: string };
		if (change.withdrawn === true) {
			projection.recordLine(conv, changed, "withdrawn");
			detachDraftFromLine(projection, key, id);
		} else if (typeof change.text === "string") projection.recordLine(conv, changed, "edited");
		else if (
			Object.hasOwn(fields, "state") && previous?.kind === "chat" && previous.state != null &&
			changed.state == null
		) projection.recordLine(conv, changed);
	}
}

/** Reconcile a draft aimed at authority the room has withdrawn. Empty input was
 * the withdrawal intent and is complete. New words or files belong to the
 * reader, so preserve them while removing the stale edit target; their next
 * submission becomes a new line instead of retrying an impossible mutation. */
function detachDraftFromLine(projection: PageProjection, key: string, id: number): boolean {
	const draftsState = projection.get().drafts;
	const draft = draftsState.get(key);
	if (draft?.changing !== id) return false;
	const drafts = new Map(draftsState);
	if (draft.text === "" && draft.files.length === 0) drafts.delete(key);
	else drafts.set(key, { ...draft, changing: undefined, keeping: undefined });
	projection.set({ drafts });
	return true;
}

/** The reader has caught up with this conversation. The unread count clears at
 * once; the rule in the log stays a moment longer, so arriving at a conversation
 * still shows you where you left off. */
export function markRead(projection: PageProjection, key: string): void {
	const unread = unreadOf(projection, key);
	if (unread.kind !== "unread") return;
	writeUnread(projection, key, { kind: "rule-only", from: unread.from });
}

/** Take down the "New messages" rule, leaving the unread count as it is. Called
 * a moment after the reader arrives, so the rule is seen and then retires. */
export function clearUnreadRule(projection: PageProjection, key: string): void {
	// Only a rule that has outlived its run retires. A conversation still taking
	// lines is not caught up, so a timer landing late cannot strip its mark.
	if (unreadOf(projection, key).kind !== "rule-only") return;
	writeUnread(projection, key, CAUGHT_UP);
}
/** Empty this conversation's history in this window.
 *
 * Yours and only yours: the room keeps what was said and hands it back on the
 * way in again, so this is a window being tidied rather than anything being
 * destroyed. That is the whole reason it needs no permission — there is nothing
 * here to ask anybody about. */
export function clearHistory(projection: PageProjection, key: string): void {
	if (getConv(projection, key) === null) return;
	const gone = historyOf(projection, key);
	if (gone.length === 0) return;
	writeHistory(projection, key, NO_HISTORY, CAUGHT_UP);
	// The third way lines leave the log, through the same door as the other
	// two: the scrollback trim and a closing conversation both hand what their
	// departing lines were holding — object URLs, blob capabilities, the
	// references governing our own lines — to the release seam. Bypassing it
	// here kept all of that alive until the directory session ended, for a
	// reader who had just asked for the room to be emptied.
	projection.letLinesGo(key, gone);
}
/** Find the line a room names, and change it.
 *
 * By the room's own id rather than ours, because that is the only name both
 * sides share. A line nobody has — one that arrived before this tab did, or was
 * already cleared from this window — is not an error: the room said something
 * about a line we do not hold, and the honest answer is to do nothing. The
 * change itself goes through `updateItem`, the one seam that keeps history
 * honest: a room saying a line was edited or withdrawn must reach the archive
 * recorder exactly as a reader's own edit does, or the kept copy outlives the
 * takedown it claims to follow. */
export function applyLineChange(
	projection: PageProjection,
	key: string,
	lineId: number,
	change: { text?: string; edited?: boolean; withdrawn?: boolean },
): void {
	if (getConv(projection, key) === null) return;
	const item = historyOf(projection, key).find((row) => row.kind === "chat" && row.lineId === lineId);
	if (item === undefined) return;
	updateItem(projection, key, item.id, change);
}

/** Retire the mutation names granted by one room membership without erasing
 * what the reader saw. A recreated room starts its line counter again, so an
 * old id must not survive to name an unrelated line in the next generation. */
export function retireRoomLineIds(projection: PageProjection, key: string): void {
	if (getConv(projection, key)?.type !== "room") return;
	const current = historyOf(projection, key);
	let history: Item[] | null = null;
	for (let at = 0; at < current.length; at += 1) {
		const item = current[at];
		if (item.kind !== "chat" || item.lineId == null) continue;
		history ??= current.slice();
		const { lineId: _lineId, ...retired } = item;
		history[at] = retired;
	}
	if (history !== null) writeHistory(projection, key, history);
}
/** Remember what the room calls one of our own lines, once its echo says so. */
export function nameLine(projection: PageProjection, key: string, id: number, lineId: number): void {
	updateItem(projection, key, id, { lineId } as Partial<Item>);
}

/** Record that this tab holds the reference governing one of its own lines,
 * which is what the pencil and the close beside that message act on. */
export function holdLine(projection: PageProjection, key: string, id: number): void {
	updateItem(projection, key, id, { held: true } as Partial<Item>);
}

/** Let go of every line held on `dir`, because the connection those references
 * came over has ended and a reference cannot outlive it. The lines stay: what
 * was said is still what was said, and only what can still be done to it
 * changes. */
export function dropHeldLines(projection: PageProjection, dir: DirId): string[] {
	const stoppedChanging: string[] = [];
	for (const conv of [...projection.get().convs.values()]) {
		if (conv.dir !== dir) continue;
		const current = historyOf(projection, conv.key);
		let history: Item[] | null = null;
		const dropped = new Set<number>();
		for (let at = 0; at < current.length; at++) {
			const item = current[at];
			if (item.kind !== "chat" || (item.held !== true && item.lineId == null)) continue;
			history ??= current.slice();
			const { lineId: _lineId, ...withoutLineName } = item;
			history[at] = { ...withoutLineName, held: false };
			dropped.add(item.id);
		}
		if (history !== null) writeHistory(projection, conv.key, history);
		// A change the reader is part way through writing is aimed at one of those
		// lines, and it can no longer land. The words stay, because they are still
		// theirs to say; what goes is the aim, so pressing Enter says them as a new
		// message instead of refusing over and over.
		const draft = projection.get().drafts.get(conv.key);
		if (
			draft?.changing !== undefined && dropped.has(draft.changing) &&
			detachDraftFromLine(projection, conv.key, draft.changing)
		) stoppedChanging.push(conv.key);
	}
	return stoppedChanging;
}
