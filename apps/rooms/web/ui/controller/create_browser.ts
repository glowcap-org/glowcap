// Construct the browser-owned controller: presentation, navigation, and which
// session this tab answers to.

import * as store from "../store.ts";
import * as net from "../page_navigation.ts";
import {
	installWorkspaceStatePersistence,
	setWorkspaceControllerSelection,
	workspaceControllerSelection,
} from "../workspace_state.ts";
import { clearWorkspaceState } from "../workspace/bundle.ts";
import { sharedRoomsSession } from "../../../lib/workspace_view.ts";
import { homeLocator } from "../page_bootstrap.ts";
import { attachedSessionFailureText } from "../session/attached_failure.ts";
import type { RoomsPageContext } from "../page.ts";
import type { RoomsBrowserController } from "./browser.ts";
import { deleteRoomsBrowserData } from "./browser_data.ts";
import { coverForReload, finishCoveredReload, reloadNow, uncoverReload } from "../boot.ts";

function leaveAttachedSession(
	page: RoomsPageContext,
	controller: { kind: "local" } | { kind: "none" },
	refusal: string,
): string {
	coverForReload();
	if (!setWorkspaceControllerSelection(page, controller)) {
		uncoverReload();
		return refusal;
	}
	finishCoveredReload(controller.kind === "none");
	return "";
}

export function createRoomsBrowserController(
	page: RoomsPageContext,
	navigate: (path: string) => void,
	addressOfActive: () => string,
): RoomsBrowserController {
	const backToRooms = <A extends unknown[]>(act: (...args: A) => void) => (...args: A): void => {
		act(...args);
		if (location.pathname.startsWith("/ops")) queueMicrotask(() => navigate(addressOfActive()));
	};
	const projection = page.projection;
	return {
		showRail: (shown) => store.showRail(projection, shown),
		reachFor: backToRooms((act) => net.reachFor(page, act)),
		showJoinCard: backToRooms(() => store.showJoinCard(projection)),
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
		openHelp: () => store.openHelp(projection),
		closeHelp: () => store.closeHelp(projection),
		openOperations: () => {
			store.closeSettings(projection);
			navigate("/ops");
		},
		showActiveConversation: () => navigate(addressOfActive()),
		setOpsPane: (pane) => store.setOpsPane(projection, pane),
		changeLine: (id, text) => store.startChange(projection, id, text),
		changeFiles: (id, caption, keeping) => store.startRefile(projection, id, caption, keeping),
		dropKeptFile: (index) => store.dropKeptFile(projection, index),
		cancelChange: () => store.cancelChange(projection),
		addFiles: (files) => net.addFiles(page, files),
		removeFile: (index) => store.removeDraftFile(projection, index),
		closeViewer: () => store.closeViewer(projection),
		editJoin: (patch) => store.editJoin(projection, patch),
		attachRoomsSession: async (sturdyref) => {
			const before = workspaceControllerSelection(page);
			let why = "";
			try {
				if (page.workspace.persistenceControl == null) installWorkspaceStatePersistence(page);
				await page.workspace.persistenceControl!.attach(sturdyref, await homeLocator(page));
			} catch (error) {
				why = attachedSessionFailureText(error);
			}
			if (why === "") {
				const after = workspaceControllerSelection(page);
				const beforeShared = sharedRoomsSession(before);
				const afterShared = sharedRoomsSession(after);
				if (
					before.kind !== after.kind ||
					beforeShared?.sturdyref !== afterShared?.sturdyref
				) {
					reloadNow();
				}
			}
			return why;
		},
		shareRoomsSession: () => page.hostedSession.share(),
		useLocalRoomsSession: () =>
			leaveAttachedSession(page, { kind: "local" }, "This browser refused to save local Rooms reconstruction."),
		leaveRoomsSession: () =>
			leaveAttachedSession(page, { kind: "none" }, "This browser refused to leave the current Rooms session."),
		controllerSelection: page.workspace.controllerSelection,
		resetBrowserWorkspace: () => {
			coverForReload();
			if (!clearWorkspaceState(page)) {
				uncoverReload();
				return "This browser refused to forget the saved workspace.";
			}
			finishCoveredReload(true);
			return "";
		},
		deleteBrowserData: async () => {
			coverForReload();
			const why = await deleteRoomsBrowserData(page);
			if (why !== "") {
				uncoverReload();
				return why;
			}
			finishCoveredReload(true);
			return "";
		},
	};
}
