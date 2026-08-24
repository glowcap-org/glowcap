// The page around the conversation: which panels are open, what the foot says,
// and what the join card is holding.
//
// None of this is the conversation, and that is the point of keeping it apart.
// A phone and a wide screen disagree about what "show the rooms list" means, so
// the verbs here answer for the layout in force rather than making every
// control know which one it is on.

import {
	type AttachmentView,
	type DiagnosticRow,
	type DirId,
	type ListenerRow,
	type OpsCap,
	type PeeringState,
	type ToastKind,
	type ViewerDirection,
	type VizPublishState,
} from "../types.ts";
import type { IrcGatewayState } from "../types.ts";
import { kindOf } from "../media.ts";
import { type Draft, KEY, NO_DRAFT, set, type State, state } from "./core.ts";
import { LS } from "../storage.ts";
import { actingDir } from "./convs.ts";
import { markRead } from "./items.ts";
import { patchDir, setDirStatus } from "./dirs.ts";

// ── Session, join card, chrome ────────────────────────────────────────────
/** What the application is doing on the directory the reader is on. Says nothing
 * about any session's health, which is why it cannot paint a dot. */
export function setStatus(statusText: string): void {
	const here = actingDir();
	if (here !== null) setDirStatus(here.id, statusText);
}

/** How many notices the stack will hold. Past this the oldest is dropped so a
 * looping failure cannot bury the page. */
const MAX_TOASTS = 5;
let nextToastId = 1;

/** Put a notice on the stack. Several may be up; a new one takes the top and
 * the others move down. */
export function toast(kind: ToastKind, text: string): void {
	const notice = { id: nextToastId++, kind, text };
	const toasts = [notice, ...state.toasts];
	set({ toasts: toasts.length > MAX_TOASTS ? toasts.slice(0, MAX_TOASTS) : toasts });
}

/** Take one notice off, by the id it was given. Unknown ids are a no-op so a
 * timer and a press can race without the second one inventing a failure. */
export function dismissToast(id: number): void {
	if (!state.toasts.some((notice) => notice.id === id)) return;
	set({ toasts: state.toasts.filter((notice) => notice.id !== id) });
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
	setActiveDraft({ ...activeDraft(), text, changing: id, keeping: undefined, files: [] });
}

/** Begin changing a file line's files: its caption goes into the composer and
 * its current files fill it as removable chips, with room to add more. */
export function startRefile(id: number, caption: string, keeping: readonly AttachmentView[]): void {
	setActiveDraft({ ...activeDraft(), text: caption, changing: id, keeping, files: [] });
}

/** Drop one of the kept files from a file-line change, by its position among
 * them. A no-op when the composer is not changing a file line. */
export function dropKeptFile(index: number): void {
	const draft = activeDraft();
	if (draft.keeping === undefined) return;
	setActiveDraft({ ...draft, keeping: draft.keeping.filter((_, at) => at !== index) });
}

/** Stop changing, leaving the line as it was posted and the composer empty. */
export function cancelChange(): void {
	setActiveDraft({ ...activeDraft(), text: "", changing: undefined, keeping: undefined, files: [] });
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
/** Open or close the card describing one directory. */
export function showAboutDir(dir: DirId | null): void {
	set({ aboutDir: dir, errorDetail: null });
}

/** Open the card that holds the rest of a long refusal. */
export function showErrorDetail(detail: { title: string; text: string }): void {
	set({ errorDetail: detail, aboutConv: false, aboutDir: null });
}

/** Put the error card away. */
export function closeErrorDetail(): void {
	if (state.errorDetail !== null) set({ errorDetail: null });
}

/** Open the card about the conversation on screen. Nothing happens with none. */
export function showAboutConv(): void {
	if (state.activeKey === null) return;
	set({ aboutConv: true, errorDetail: null, aboutDir: null });
}

/** Put the conversation card away. */
export function closeAboutConv(): void {
	if (state.aboutConv) set({ aboutConv: false });
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
export function setTheme(theme: "light" | "dark"): void {
	LS.set(KEY.theme, theme);
	set({ theme });
}
export function setNotify(notifyOn: boolean): void {
	LS.set(KEY.notify, notifyOn ? "1" : "0");
	set({ notifyOn });
}

export function openSettings(): void {
	set({
		settingsOpen: true,
		opsTake: null,
		helpOpen: false,
		// The last panel the reader chose, not a reset: the store keeps it and
		// its localStorage twin carries it across reloads.
		settingsTab: state.settingsTab,
		aboutDir: null,
		errorDetail: null,
		aboutConv: false,
	});
}

/** Which Settings panel is selected, remembered on this device so the dialog
 * reopens where the reader was. */
export function setSettingsTab(settingsTab: State["settingsTab"]): void {
	LS.set(KEY.settingsTab, settingsTab);
	set({ settingsTab });
}

export function closeSettings(): void {
	if (state.settingsOpen || state.helpOpen || state.opsTake !== null) {
		set({
			settingsOpen: false,
			helpOpen: false,
			opsTake: null,
			aboutDir: null,
			errorDetail: null,
			aboutConv: false,
		});
	}
}

/** Close Settings beneath the glossary so only one native modal is open. The
 * Settings session stays open so the Settings control stays pressed, and Help's own
 * copy of that title row keeps the Help control on screen, pressed. */
export function openHelp(): void {
	set({ helpOpen: true, opsTake: null });
}

/** Put Settings back after Help. */
export function closeHelp(): void {
	set({ helpOpen: false, settingsOpen: true });
}

/** Which operations pane the reader stood on last, remembered on this
 * device so /ops lands where they were. */
export function setOpsTab(opsTab: OpsCap): void {
	LS.set(KEY.opsTab, opsTab);
	set({ opsTab });
}

/** Open `cap`'s take modal: asking to hold the capability, which lands only
 * when the take succeeds. Cancel or a failed take leaves nothing held.
 * `from` records who asked — the Settings toggle, or an Operations-page
 * gate — which is where the close returns. */
export function openOpsTake(cap: OpsCap, from: "settings" | "ops" = "settings"): void {
	set({ opsTake: cap, opsTakeFrom: from, helpOpen: false });
}

/** Put the asking surface back after the take modal — Settings on the
 * Capabilities panel for its toggle, nothing at all for an Operations-page gate,
 * which is still standing where it was. */
/** Flip whether this device keeps direct-message history. The store field
 * is what the switch draws; `ui/history.ts` owns the bytes and does the
 * wiping, so the caller hands it the same choice. */
export function setKeepHistory(keep: boolean): void {
	set({ keepHistory: keep });
}

export function closeOpsTake(): void {
	if (state.opsTakeFrom === "settings") {
		set({ opsTake: null, settingsOpen: true, settingsTab: "capabilities" });
		return;
	}
	set({ opsTake: null });
}

/** What the row fields say when a capability arrives or goes.
 *
 * Possession is derived from these rows, so this is also where its
 * consequences live: rows landing select that pane. A reconnect's drops flow through here
 * too, which is what makes the Capabilities toggles fall back off with the
 * capabilities they mirror. */
function patchOpsRows(
	patch: {
		diagnostics?: readonly DiagnosticRow[] | null;
		listeners?: readonly ListenerRow[] | null;
		irc?: IrcGatewayState | null;
		peering?: PeeringState | null;
		viz?: VizPublishState | null;
	},
): void {
	// Arrival does not move the selection: the modal opens on the pane the
	// reader last chose (or the first held one), however the capabilities
	// came in.
	const grew: Parameters<typeof set>[0] = { ...patch };
	set(grew);
}

export function setDiagnostics(diagnostics: readonly DiagnosticRow[] | null): void {
	patchOpsRows({ diagnostics });
}

export function setListeners(listeners: readonly ListenerRow[] | null): void {
	patchOpsRows({ listeners });
}

/** What the gateway possession row says when the capability arrives, the
 * bridged list changes, or the capability goes. */
export function setIrcGateway(irc: IrcGatewayState | null): void {
	patchOpsRows({ irc });
}

/** What the peering possession row says when the capability arrives, a
 * publication changes standing, or the capability goes. */
export function setPeering(peering: PeeringState | null): void {
	patchOpsRows({ peering });
}

/** What the viz possession row says when the capability arrives, redials, or
 * goes. A connectivity flip on an already-held capability rides the same
 * path and moves no tab. */
export function setVizPublish(viz: VizPublishState | null): void {
	patchOpsRows({ viz });
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
		// A withdrawn line's bubble no longer shows its pictures, so the arrows
		// must not step onto them either: the walk and the log describe one
		// conversation.
		if (item.kind !== "chat" || item.attachments === undefined || item.withdrawn === true) continue;
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

/** Put a conversation on screen, and nothing else.
 *
 * Which conversation is open and whether the rail is open are two facts, and
 * only this one belongs to where a reader is standing: an address, a shared
 * link, or the browser's back button decides the conversation and must leave
 * the chrome exactly as the reader left it. A *press* means more than that,
 * which is what `switchTo` adds. */
export function showConv(key: string): void {
	if (!state.convs.has(key)) return;
	set({ activeKey: key });
	markRead(key);
}

/** Pressing a conversation: show it, and dismiss the phone's overlays the
 * press was made through. On a wide layout those fields are simply not
 * read. */
export function switchTo(key: string): void {
	if (!state.convs.has(key)) return;
	showConv(key);
	set({ listScreen: false, rosterSheet: false });
}

/** Nothing selected, and nothing else touched: the join card is the
 * conversation column standing empty, so this is the selection half of
 * `showJoinCard` for a caller that must not move the chrome. */
export function clearConv(): void {
	set({ activeKey: null });
}

/** Back to the state the page opens in: the join card up, with nothing selected
 * behind it. Everything that only means something inside a conversation is
 * derived from `activeKey`, so this one field is the whole of it. */
export function showJoinCard(): void {
	set({ activeKey: null, listScreen: false, rosterSheet: false, aboutConv: false });
}
