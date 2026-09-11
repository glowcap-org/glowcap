// The page around the conversation: which panels are open, what the foot says,
// and what the join card is holding.
//
// None of this is the conversation, and that is the point of keeping it apart.
// A phone and a wide screen disagree about what "show the rooms list" means, so
// the verbs here answer for the layout in force rather than making every
// control know which one it is on.

import type {
	AttachmentView,
	DiagnosticRow,
	DirId,
	ListenerRow,
	OpsCap,
	PeeringState,
	RoomsOperatorState,
	ToastKind,
	ViewerDirection,
	VizPublishState,
} from "../types.ts";
import type { IrcGatewayState, MemberRef } from "../types.ts";
import type { ArchiveTargetView } from "../archive_model.ts";
import { kindOf } from "../media.ts";
import { type Draft, NO_DRAFT, type PageProjection, type State } from "./core.ts";
import { actingDir, forgetConv, getConv, nextStandingKey } from "./convs.ts";
import { markRead } from "./items.ts";
import { patchDir, setDirStatus } from "./dirs.ts";

// ── Session, join card, chrome ────────────────────────────────────────────
/** What the application is doing on the directory the reader is on. Says nothing
 * about any session's health, which is why it cannot paint a dot. */
export function setStatus(projection: PageProjection, statusText: string): void {
	const here = actingDir(projection);
	if (here !== null) setDirStatus(projection, here.id, statusText);
}

/** How many notices the stack will hold. Past this the oldest is dropped so a
 * looping failure cannot bury the page. */
const MAX_TOASTS = 5;

/** Put a notice on the stack. Several may be up; a new one takes the top and
 * the others move down. */
export function toast(projection: PageProjection, kind: ToastKind, text: string): void {
	const notice = { id: projection.allocToastId(), kind, text };
	const toasts = [notice, ...projection.get().toasts];
	projection.set({ toasts: toasts.length > MAX_TOASTS ? toasts.slice(0, MAX_TOASTS) : toasts });
}

/** Take one notice off, by the id it was given. Unknown ids are a no-op so a
 * timer and a press can race without the second one inventing a failure. */
export function dismissToast(projection: PageProjection, id: number): void {
	const toasts = projection.get().toasts;
	if (!toasts.some((notice) => notice.id === id)) return;
	projection.set({ toasts: toasts.filter((notice) => notice.id !== id) });
}
/** What is ready to send in a conversation, or an empty draft.
 *
 * Every reader of a draft goes through here, so "no row yet" and "a row that has
 * been emptied" are one answer rather than two the callers each have to handle. */
export function draftFor(projection: PageProjection, key: string | null): Draft {
	return (key === null ? undefined : projection.get().drafts.get(key)) ?? NO_DRAFT;
}

/** The draft of the conversation on screen. The composer only exists inside one,
 * so this is what it reads and what its verbs below write. */
export function activeDraft(projection: PageProjection): Draft {
	return draftFor(projection, projection.get().activeKey);
}

/** Each edit has its own immutable identity, including an explicit clear.
 * Pending submissions use that identity to distinguish a newer empty draft
 * from the empty draft they left behind. Untouched conversations have no row;
 * touched rows are bounded by open conversations and retire with them. */
function setDraftOn(projection: PageProjection, key: string, next: Draft): void {
	if (!projection.get().convs.has(key)) return;
	const drafts = new Map(projection.get().drafts);
	drafts.set(key, next);
	projection.set({ drafts });
}

/** Replace only the draft an asynchronous submission observed. A later edit,
 * file selection, or retired conversation keeps ownership of its own state. */
export function replaceDraft(
	projection: PageProjection,
	key: string,
	expected: Draft,
	next: Draft,
): boolean {
	if (!projection.get().convs.has(key) || draftFor(projection, key) !== expected) return false;
	setDraftOn(projection, key, next);
	return true;
}

/** Write the conversation on screen's draft. Nothing happens with none on
 * screen: there would be no addressee, and the composer is not drawn there. */
function setActiveDraft(projection: PageProjection, next: Draft): void {
	const key = projection.get().activeKey;
	if (key === null) return;
	setDraftOn(projection, key, next);
}

/** Write a conversation's draft text. The composer types into whoever is on
 * screen; a send names the conversation that was composed, because a command
 * may have already put that conversation away. */
export function setDraft(
	projection: PageProjection,
	text: string,
	key: string | null = projection.get().activeKey,
): void {
	if (key == null) return;
	setDraftOn(projection, key, { ...draftFor(projection, key), text });
}

/** Begin changing a line already posted: its words go into the composer, and
 * the composer remembers which line they belong to. */
export function startChange(projection: PageProjection, id: number, text: string): void {
	setActiveDraft(projection, { ...activeDraft(projection), text, changing: id, keeping: undefined, files: [] });
}

/** Begin changing a file line's files: its caption goes into the composer and
 * its current files fill it as removable chips, with room to add more. */
export function startRefile(
	projection: PageProjection,
	id: number,
	caption: string,
	keeping: readonly AttachmentView[],
): void {
	setActiveDraft(projection, { ...activeDraft(projection), text: caption, changing: id, keeping, files: [] });
}

/** Drop one of the kept files from a file-line change, by its position among
 * them. A no-op when the composer is not changing a file line. */
export function dropKeptFile(projection: PageProjection, index: number): void {
	const draft = activeDraft(projection);
	if (draft.keeping === undefined) return;
	setActiveDraft(projection, { ...draft, keeping: draft.keeping.filter((_, at) => at !== index) });
}

/** Stop changing, leaving the line as it was posted and the composer empty. */
export function cancelChange(
	projection: PageProjection,
	key: string | null = projection.get().activeKey,
): void {
	if (key == null) return;
	setDraftOn(projection, key, {
		...draftFor(projection, key),
		text: "",
		changing: undefined,
		keeping: undefined,
		files: [],
	});
}
export function addDraftFiles(projection: PageProjection, files: readonly File[]): void {
	const draft = activeDraft(projection);
	setActiveDraft(projection, { ...draft, files: [...draft.files, ...files] });
}
export function removeDraftFile(projection: PageProjection, index: number): void {
	const draft = activeDraft(projection);
	setActiveDraft(projection, { ...draft, files: draft.files.filter((_, at) => at !== index) });
}
export function clearDraftFiles(
	projection: PageProjection,
	key: string | null = projection.get().activeKey,
): void {
	if (key == null) return;
	setDraftOn(projection, key, { ...draftFor(projection, key), files: [] });
}
/** Record the name `dir` granted.
 *
 * One directory's answer and no other's. Admission accepts the requested
 * value exactly or refuses it, and an accepted name is true only in this
 * directory. */
export function setDirNick(projection: PageProjection, dir: DirId, nick: string): void {
	patchDir(projection, dir, { nick });
}

/** Record the exact nickname this workspace will request on reconstruction.
 * This is intent, not evidence that the directory granted it. */
export function setRequestedDirNick(projection: PageProjection, dir: DirId, nick: string): void {
	patchDir(projection, dir, { requestedNick: nick });
}

/** The name `dir` granted, or empty when it has granted none. */
export function dirNick(projection: PageProjection, dir: DirId): string {
	return projection.get().dirs.get(dir)?.nick ?? "";
}

/** The exact name a reconstructed connection should ask this directory for. */
export function requestedDirNick(projection: PageProjection, dir: DirId): string {
	return projection.get().dirs.get(dir)?.requestedNick ?? "";
}
/** Open or close the card describing one directory.
 *
 * `askingLeave` opens it already asking to give the directory back: the title's
 * mark uses that so the question lives in this card rather than in a second
 * dialog over it. Closing, or opening without asking, clears the flag. */
export function showAboutDir(projection: PageProjection, dir: DirId | null, askingLeave = false): void {
	projection.set({
		aboutDir: dir,
		aboutDirLeave: dir !== null && askingLeave,
		errorDetail: null,
	});
}

/** Open or close the card describing one person.
 *
 * This does not close the directory card, because the two stand together on
 * purpose: a person's card names the directory that granted their name, that
 * name is a door, and a reader who goes through it has to be able to come back.
 * Everything else that takes the layer still closes this, the same as it closes
 * the others. */
export function showAboutMember(projection: PageProjection, about: MemberRef | null): void {
	projection.set({ aboutMember: about, errorDetail: null });
}

/** Open the card that holds the rest of a long refusal. */
export function showErrorDetail(projection: PageProjection, detail: { title: string; text: string }): void {
	projection.set({ errorDetail: detail });
}

/** Put the error card away. */
export function closeErrorDetail(projection: PageProjection): void {
	if (projection.get().errorDetail !== null) projection.set({ errorDetail: null });
}

/** Open the card about the conversation on screen. Nothing happens with none.
 * A directory conversation opens its directory card from the title chip, not
 * this conversation card.
 *
 * `askingLeave` opens it already asking to leave: the title's mark uses that
 * so the question lives in this card rather than acting from the header. The
 * about pane is the one that holds Leave, so asking always opens there. */
export function showAboutConv(
	projection: PageProjection,
	pane: "about" | "bridge" | "capabilities" = "about",
	askingLeave = false,
): void {
	const state = projection.get();
	if (state.activeKey === null) return;
	if (getConv(projection, state.activeKey, state)?.type === "directory") return;
	projection.set({
		aboutConv: true,
		aboutConvPane: askingLeave ? "about" : pane,
		aboutConvRequest: state.aboutConvRequest + 1,
		aboutConvLeave: askingLeave,
		errorDetail: null,
		aboutDir: null,
		aboutDirLeave: false,
		aboutMember: null,
	});
}

/** Put the conversation card away. */
export function closeAboutConv(projection: PageProjection): void {
	const state = projection.get();
	if (state.aboutConv || state.aboutConvLeave) projection.set({ aboutConv: false, aboutConvLeave: false });
}

/** End the directory view without leaving the directory.
 *
 * `/leave` puts this view away: the session and the name stay, and a room or
 * direct line still open comes forward, or the join card if none is. The
 * title's mark asks to give the directory back, which is a different act. */
export function dismissDirectoryView(projection: PageProjection, key: string): void {
	if (getConv(projection, key)?.type !== "directory") return;
	const wasReading = projection.get().activeKey === key;
	forgetConv(projection, key);
	if (!wasReading) return;
	closeAboutConv(projection);
	showAboutDir(projection, null);
	const next = nextStandingKey(projection.get().convs);
	if (next === undefined) showJoinCard(projection);
	else switchTo(projection, next);
}

export function setTheme(projection: PageProjection, theme: "light" | "dark"): void {
	projection.set({ theme });
}
export function setNotify(projection: PageProjection, notifyOn: boolean): void {
	projection.set({ notifyOn });
}

export function openSettings(projection: PageProjection): void {
	projection.set({
		settingsOpen: true,
		helpOpen: false,
		// The last panel the reader chose, not a reset: the store keeps it and
		// its localStorage twin carries it across reloads.
		settingsTab: projection.get().settingsTab,
		aboutDir: null,
		aboutDirLeave: false,
		aboutMember: null,
		errorDetail: null,
		aboutConv: false,
		aboutConvLeave: false,
	});
}

/** Which Settings panel is selected, remembered on this device so the dialog
 * reopens where the reader was. */
export function setSettingsTab(projection: PageProjection, settingsTab: State["settingsTab"]): void {
	projection.set({ settingsTab });
}

export function closeSettings(projection: PageProjection): void {
	const state = projection.get();
	if (state.settingsOpen || state.helpOpen) {
		projection.set({
			settingsOpen: false,
			helpOpen: false,
			aboutDir: null,
			aboutDirLeave: false,
			aboutMember: null,
			errorDetail: null,
			aboutConv: false,
			aboutConvLeave: false,
		});
	}
}

/** Close Settings beneath the glossary so only one native modal is open. The
 * Settings session stays open so the Settings control stays pressed, and Help's own
 * copy of that title row keeps the Help control on screen, pressed. */
export function openHelp(projection: PageProjection): void {
	projection.set({ helpOpen: true });
}

/** Put Settings back after Help. */
export function closeHelp(projection: PageProjection): void {
	projection.set({ helpOpen: false, settingsOpen: true });
}

/** Which operations pane the reader stood on last, remembered on this
 * device so /ops lands where they were. */
export function setOpsPane(projection: PageProjection, opsPane: OpsCap): void {
	projection.set({ opsPane });
}

/** Flip whether the selected archive keeps message history. The store field
 * is what the switch draws; `ui/history.ts` owns the bytes and does the
 * wiping, so the caller hands it the same choice. */
export function setKeepHistory(projection: PageProjection, keep: boolean): void {
	projection.set({ keepHistory: keep });
}

/** Reflect archive connection state without retaining its bearer authority in
 * the presentation store. */
export function setArchiveTarget(projection: PageProjection, archiveTarget: ArchiveTargetView): void {
	projection.set({ archiveTarget });
}

/** What the row fields say when a capability arrives or goes.
 *
 * Possession is derived from these rows, so this is also where its
 * consequences live: rows landing select that pane. A reconnect's drops flow through here
 * too, which is what makes the Holdings toggles fall back off with the
 * capabilities they mirror. */
function patchOpsRows(projection: PageProjection, patch: {
	diagnostics?: readonly DiagnosticRow[] | null;
	listeners?: readonly ListenerRow[] | null;
	irc?: IrcGatewayState | null;
	operator?: RoomsOperatorState | null;
	peering?: PeeringState | null;
	viz?: VizPublishState | null;
}): void {
	// Arrival does not move the selection: the modal opens on the pane the
	// reader last chose (or the first held one), however the capabilities
	// came in.
	const grew: Partial<State> = { ...patch };
	projection.set(grew);
}

export function setDiagnostics(projection: PageProjection, diagnostics: readonly DiagnosticRow[] | null): void {
	patchOpsRows(projection, { diagnostics });
}

export function setListeners(projection: PageProjection, listeners: readonly ListenerRow[] | null): void {
	patchOpsRows(projection, { listeners });
}

/** What the gateway possession row says when the capability arrives, the
 * bridged list changes, or the capability goes. */
export function setIrcGateway(projection: PageProjection, irc: IrcGatewayState | null): void {
	patchOpsRows(projection, { irc });
}

export function setRoomsOperator(projection: PageProjection, operator: RoomsOperatorState | null): void {
	patchOpsRows(projection, { operator });
}

/** What the peering possession row says when the capability arrives, a
 * publication changes standing, or the capability goes. */
export function setPeering(projection: PageProjection, peering: PeeringState | null): void {
	patchOpsRows(projection, { peering });
}

/** What the viz possession row says when the capability arrives, redials, or
 * goes. A connectivity flip on an already-held capability rides the same
 * path and moves no tab. */
export function setVizPublish(projection: PageProjection, viz: VizPublishState | null): void {
	patchOpsRows(projection, { viz });
}

/** Open one posted file full-screen, over everything. */
export function openViewer(projection: PageProjection, key: string, id: number): void {
	projection.set({ viewing: { key, id } });
}

export function closeViewer(projection: PageProjection): void {
	if (projection.get().viewing !== null) projection.set({ viewing: null });
}

/** Move to the adjacent picture in this conversation's message order.
 *
 * The conversation owns the order, not the gallery that happened to draw a
 * subset of it. Non-image attachments do not enter that order, and reaching an
 * end is a no-op rather than an implicit jump across the conversation. Returns
 * the newly selected image so the network edge can fetch it when necessary. */
export function stepViewer(projection: PageProjection, direction: ViewerDirection): AttachmentView | null {
	const state = projection.get();
	const viewing = state.viewing;
	if (viewing === null) return null;
	const history = state.histories.get(viewing.key) ?? [];
	if (state.convs.get(viewing.key) === undefined) return null;

	let previous: AttachmentView | null = null;
	let found = false;
	for (const item of history) {
		// A withdrawn line's bubble no longer shows its pictures, so the arrows
		// must not step onto them either: the walk and the log describe one
		// conversation.
		if (item.kind !== "chat" || item.attachments === undefined || item.withdrawn === true) continue;
		for (const file of item.attachments) {
			if (kindOf(file.mime) !== "image") continue;
			if (found) {
				projection.set({ viewing: { key: viewing.key, id: file.id } });
				return file;
			}
			if (file.id === viewing.id) {
				if (direction === "previous") {
					if (previous !== null) projection.set({ viewing: { key: viewing.key, id: previous.id } });
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
export function viewedAttachment(
	snapshot: Readonly<Pick<State, "viewing" | "histories">>,
): AttachmentView | null {
	if (snapshot.viewing === null) return null;
	const history = snapshot.histories.get(snapshot.viewing.key) ?? [];
	for (const item of history) {
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
export function showRail(projection: PageProjection, shown: boolean): void {
	projection.set(projection.get().mobile ? { listScreen: shown } : { railOpen: shown });
}

/** Show or hide the roster, the same way. */
export function showRoster(projection: PageProjection, shown: boolean): void {
	projection.set(projection.get().mobile ? { rosterSheet: shown } : { rosterOpen: shown });
}

/** Dismiss the narrow layout's roster sheet, whatever the layout. Navigation
 * does this; it is not a preference and has no wide-layout meaning. */
export function closeRosterSheet(projection: PageProjection): void {
	if (projection.get().rosterSheet) projection.set({ rosterSheet: false });
}

/** Put a conversation on screen, and nothing else.
 *
 * Which conversation is open and whether the rail is open are two facts, and
 * only this one belongs to where a reader is standing: an address, a shared
 * link, or the browser's back button decides the conversation and must leave
 * the chrome exactly as the reader left it. A *press* means more than that,
 * which is what `switchTo` adds. */
export function showConv(projection: PageProjection, key: string): void {
	if (!projection.get().convs.has(key)) return;
	projection.set({ activeKey: key });
	markRead(projection, key);
}

/** Pressing a conversation: show it, and dismiss the phone's overlays the
 * press was made through. On a wide layout those fields are simply not
 * read. */
export function switchTo(projection: PageProjection, key: string): void {
	if (!projection.get().convs.has(key)) return;
	showConv(projection, key);
	projection.set({ listScreen: false, rosterSheet: false });
}

/** Nothing selected, and nothing else touched: the join card is the
 * conversation column standing empty, so this is the selection half of
 * `showJoinCard` for a caller that must not move the chrome. */
export function clearConv(projection: PageProjection): void {
	projection.set({ activeKey: null });
}

/** Back to the state the page opens in: the join card up, with nothing selected
 * behind it. Everything that only means something inside a conversation is
 * derived from `activeKey`, so this one field is the whole of it. */
export function showJoinCard(projection: PageProjection): void {
	projection.set({ activeKey: null, listScreen: false, rosterSheet: false, aboutConv: false, aboutConvLeave: false });
}
