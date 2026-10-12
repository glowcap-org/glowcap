// Construct the browser-owned controller: presentation, navigation, and which
// session this tab answers to.

import { refusalText } from "../../../lib/text/failure.ts";
import * as store from "../store.ts";
import * as net from "../page_navigation.ts";
import { tabIdentity } from "../session/managed/open.ts";
import { attachedSessionFailureText } from "../session/attached_failure.ts";
import type { openManagedSession } from "../session/managed/open.ts";
import type { RoomsPageContext } from "../page.ts";
import type { RoomsBrowserController } from "./browser.ts";
import { coverForReload, finishCommittedMove, finishCoveredReload, uncoverReload } from "../boot.ts";
import type { ManagedRoomsSession } from "../session/managed/session.ts";
import { requestBrowserDataDeletion } from "./browser_data.ts";

export function createRoomsBrowserController(
	page: RoomsPageContext,
	navigate: (path: string) => void,
	addressOfActive: () => string,
	openLocalWorkspace: () => ReturnType<typeof openManagedSession>,
): RoomsBrowserController {
	const backToRooms = <A extends unknown[]>(act: (...args: A) => void) => (...args: A): void => {
		act(...args);
		if (location.pathname.startsWith("/ops")) queueMicrotask(() => navigate(addressOfActive()));
	};
	const projection = page.projection;
	let sharing: Promise<string> | null = null;
	let conversationGesture = 0;
	const managed = async () => {
		return page.managedSession ?? (await openLocalWorkspace()).session;
	};
	// A move commits when its selection lands. A failure before that point is
	// the move's own and the page stays; after it, the page leaves.
	const moveTo = async (uri: string | null, chosen: boolean, toFront: boolean): Promise<string> => {
		coverForReload();
		let session: ManagedRoomsSession;
		try {
			session = await managed();
			await session.selectWorkspace(uri);
			if (chosen) localStorage.setItem(chosenKey(), "yes");
			else localStorage.removeItem(chosenKey());
		} catch (error) {
			uncoverReload();
			return attachedSessionFailureText(error);
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
			if (address !== `${location.pathname}${location.search}`) navigate(address);
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
					return attachedSessionFailureText(error);
				}
			})().finally(() => {
				sharing = null;
			}),
		useLocalRoomsSession: () => selectLocal(true),
		leaveRoomsSession: () => selectLocal(false),
		controllerSelection: page.controllerSelection,
		resetBrowserWorkspace: async () => {
			try {
				await (await managed()).actions.clear();
				return await selectLocal(false);
			} catch (error) {
				return attachedSessionFailureText(error);
			}
		},
		deleteBrowserData: () => {
			try {
				requestBrowserDataDeletion();
			} catch (error) {
				return Promise.resolve(attachedSessionFailureText(error));
			}
			coverForReload();
			finishCoveredReload(true);
			return Promise.resolve("");
		},
	};
}
export const chosenKey = () => `rooms.workspace-choice.${tabIdentity()}`;
