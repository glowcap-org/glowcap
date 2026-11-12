// Construct the browser-owned controller: presentation, navigation, and which
// session this tab answers to.

import { type LocalRefusal, refusalText } from "../../../lib/text/failure.ts";
import * as store from "../store.ts";
import * as net from "../page_navigation.ts";
import { keptTabIdentity, tabIdentity } from "../session/managed/open.ts";
import { attachedSessionFailureText } from "../session/attached_failure.ts";
import type { openManagedSession } from "../session/managed/open.ts";
import type { RoomsPageContext } from "../page.ts";
import type { RoomsBrowserController } from "./browser.ts";
import { coverForReload, finishCommittedMove, finishCoveredReload, uncoverReload } from "../boot.ts";
import type { ManagedRoomsSession } from "../session/managed/session.ts";
import { requestBrowserDataDeletion } from "./browser_data.ts";
import { pagePath } from "../page_base.ts";
import { addressAt } from "../route_address.ts";
import { serverInUse } from "../server_choice.ts";
import { localArea } from "../page_storage.ts";

export function createRoomsBrowserController(
	page: RoomsPageContext,
	navigate: (path: string) => void,
	addressOfActive: () => string,
	openLocalWorkspace: () => ReturnType<typeof openManagedSession>,
): RoomsBrowserController {
	const backToRooms = <A extends unknown[]>(act: (...args: A) => void) => (...args: A): void => {
		act(...args);
		if (pagePath().startsWith("/ops")) queueMicrotask(() => navigate(addressOfActive()));
	};
	const projection = page.projection;
	let sharing: Promise<string> | null = null;
	let conversationGesture = 0;
	const managed = async () => {
		return page.managedSession ?? (await openLocalWorkspace()).session;
	};
	// A move commits when its selection lands. A failure before that point is
	// the move's own and the page stays. After it, the page leaves. The tab's
	// choice is the one step the browser can refuse, so it is recorded first
	// and put back when the selection does not land.
	const moveTo = async (uri: string | null, chosen: boolean, toFront: boolean): Promise<string> => {
		coverForReload();
		let session: ManagedRoomsSession;
		try {
			session = await managed();
			const was = workspaceChosen();
			const refused = recordWorkspaceChoice(chosen);
			if (refused != null) throw refused;
			try {
				await session.selectWorkspace(uri);
			} catch (error) {
				// tolerant: the browser kept this key a moment ago, and a refusal
				// here leaves only which screen the next load opens on.
				recordWorkspaceChoice(was);
				throw error;
			}
		} catch (error) {
			uncoverReload();
			return attachedSessionFailureText(error, serverInUse(), uri);
		}
		await finishCommittedMove(() => session.close(), toFront);
		return "";
	};
	const selectLocal = (chosen: boolean) => moveTo(null, chosen, !chosen);
	return {
		showRail: (shown) => store.showRail(projection, shown),
		reachFor: backToRooms((act) => net.reachFor(page, act)),
		showJoinCard: backToRooms(() => {
			page.managedSession?.openings.dismiss();
			store.showJoinCard(projection);
		}),
		aboutDirectory: (dir, askingLeave) => net.aboutDirectory(page, dir, askingLeave),
		showDirectory: backToRooms((dir) => net.showDirectory(page, dir)),
		aboutMember: (about) => net.aboutMember(page, about),
		aboutConversation: (pane, askingLeave) => {
			const conv = store.activeConv(projection);
			if (conv?.type === "directory") {
				net.aboutDirectory(page, conv.dir, askingLeave);
				return;
			}
			store.showAboutConv(projection, pane, askingLeave);
		},
		manageBridgeIdentity: () => store.showAboutConv(projection, "bridge"),
		closeAboutConversation: () => store.closeAboutConv(projection),
		showError: (detail) => store.showErrorDetail(projection, detail),
		closeError: () => store.closeErrorDetail(projection),
		toast: (kind, text) => store.toast(projection, kind, text),
		showRoster: (shown) => store.showRoster(projection, shown),
		toggleNotify: () => net.toggleNotify(page),
		openSettings: () => store.openSettings(projection),
		closeSettings: () => store.closeSettings(projection),
		setSettingsTab: (tab) => store.setSettingsTab(projection, tab),
		setTheme: (theme) => store.setTheme(projection, theme),
		openHelp: (tab) => store.openHelp(projection, tab),
		setHelpTab: (tab) => store.setHelpTab(projection, tab),
		closeHelp: () => store.closeHelp(projection),
		openOperations: () => {
			page.managedSession?.openings.dismiss();
			store.closeSettings(projection);
			navigate("/ops");
		},
		showActiveConversation: async (selection) => {
			const gesture = ++conversationGesture;
			const arrival = globalThis.history?.state?.key;
			try {
				await selection;
			} catch (error) {
				store.toast(projection, "failure", refusalText(error));
				return;
			}
			// The operation retains its receipt, but a newer gesture or browser
			// arrival owns navigation. Acknowledgment must not reopen its view.
			if (gesture !== conversationGesture || arrival !== globalThis.history?.state?.key) return;
			const address = addressOfActive();
			// Acknowledging the visible conversation is not a fresh route act.
			// Re-entering the directory route would cancel its pending room lookup.
			if (address !== addressAt({ pathname: pagePath(), search: location.search, hash: location.hash })) {
				navigate(address);
			}
		},
		cancelConversationOpening: () => {
			conversationGesture++;
			page.managedSession?.openings.dismiss();
		},
		setOpsPane: (pane) => store.setOpsPane(projection, pane),
		changeLine: (id, text) => store.startChange(projection, id, text),
		changeFiles: (id, caption, keeping) => store.startRefile(projection, id, caption, keeping),
		dropKeptFile: (index) => store.dropKeptFile(projection, index),
		cancelChange: () => store.cancelChange(projection),
		addFiles: (files) => net.addFiles(page, files),
		removeFile: (index) => store.removeDraftFile(projection, index),
		startPreview: (key, id) => store.startDraftPreview(projection, key, id),
		settlePreview: (key, id, attempt, outcome) => store.settleDraftPreview(projection, key, id, attempt, outcome),
		cancelPreview: (key, id, attempt) => store.cancelDraftPreview(projection, key, id, attempt),
		removePreview: (key, id) => store.removeDraftPreview(projection, key, id),
		retryPreview: (key, id) => store.retryDraftPreview(projection, key, id),
		closeViewer: () => store.closeViewer(projection),
		editJoin: (patch) => store.editJoin(projection, patch),
		attachRoomsSession: async (uri) => {
			const current = page.controllerSelection.getSnapshot();
			if ((current.kind === "attached" || current.kind === "hosted") && current.sturdyref === uri) return "";
			return await moveTo(uri, true, false);
		},
		shareRoomsSession: () =>
			sharing ??= (async () => {
				try {
					const uri = await (await managed()).workspace.publish();
					const local = page.controllerSelection.getSnapshot().kind !== "attached";
					page.controllerSelection.set({ kind: local ? "hosted" : "attached", sturdyref: uri });
					return "";
				} catch (error) {
					return attachedSessionFailureText(error, serverInUse());
				}
			})().finally(() => {
				sharing = null;
			}),
		useLocalRoomsSession: () => selectLocal(true),
		server: serverInUse,
		serverHeld: () => page.managedSession != null,
		leaveRoomsSession: () => selectLocal(false),
		controllerSelection: page.controllerSelection,
		resetBrowserWorkspace: async () => {
			try {
				await (await managed()).actions.clear();
				return await selectLocal(false);
			} catch (error) {
				return attachedSessionFailureText(error, serverInUse());
			}
		},
		deleteBrowserData: () => {
			const refused = requestBrowserDataDeletion();
			if (refused != null) return Promise.resolve(refusalText(refused));
			coverForReload();
			finishCoveredReload(true);
			return Promise.resolve("");
		},
	};
}
const choiceKey = (tab: string) => `rooms.workspace-choice.${tab}`;

/** Whether this tab chose a session, so startup opens it rather than session
 * setup. False on a fresh tab, and wherever the browser refuses to say. */
export function workspaceChosen(): boolean {
	const tab = keptTabIdentity();
	return tab != null && localArea.read(choiceKey(tab)) === "yes";
}

/** Record whether this tab chose a session. Null once kept, and otherwise the
 * browser's refusal. */
function recordWorkspaceChoice(chosen: boolean): LocalRefusal | null {
	return chosen ? localArea.write(choiceKey(tabIdentity()), "yes") : forgetWorkspaceChoice();
}

/** Forget this tab's session choice, so the next load shows setup. Null once
 * forgotten or when there was none, and otherwise the browser's refusal. */
export function forgetWorkspaceChoice(): LocalRefusal | null {
	const tab = keptTabIdentity();
	return tab == null ? null : localArea.remove(choiceKey(tab));
}
