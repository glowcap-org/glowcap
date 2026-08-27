import * as net from "../net.ts";
import * as store from "../store.ts";
import {
	clearWorkspaceState,
	setWorkspaceControllerSelection,
	workspaceControllerSelection,
	workspaceStateOf,
} from "../workspace_state.ts";
import { connectAttachedRoomsSession } from "../session/attached_connection.ts";
import { attachRoomsController } from "../session/controller_transition.ts";
import type { RoomsBrowserController } from "./browser.ts";
import { deleteRoomsBrowserData } from "./browser_data.ts";

export function createRoomsBrowserController(
	navigate: (path: string) => void,
	addressOfActive: () => string,
): RoomsBrowserController {
	const backToRooms = <A extends unknown[]>(act: (...args: A) => void) => (...args: A): void => {
		act(...args);
		if (location.pathname.startsWith("/ops")) queueMicrotask(() => navigate(addressOfActive()));
	};
	return {
		showRail: store.showRail,
		reachFor: backToRooms(net.reachFor),
		showJoinCard: backToRooms(store.showJoinCard),
		aboutDirectory: net.aboutDirectory,
		aboutConversation: store.showAboutConv,
		manageIrcIdentity: () => store.showAboutConv("irc"),
		closeAboutConversation: store.closeAboutConv,
		showError: store.showErrorDetail,
		closeError: store.closeErrorDetail,
		toast: store.toast,
		showRoster: store.showRoster,
		toggleNotify: net.toggleNotify,
		openSettings: store.openSettings,
		closeSettings: store.closeSettings,
		setSettingsTab: store.setSettingsTab,
		setTheme: store.setTheme,
		openHelp: store.openHelp,
		closeHelp: store.closeHelp,
		openOperations: () => {
			store.closeSettings();
			navigate("/ops");
		},
		setOpsPane: store.setOpsPane,
		changeLine: store.startChange,
		changeFiles: store.startRefile,
		dropKeptFile: store.dropKeptFile,
		cancelChange: store.cancelChange,
		addFiles: net.addFiles,
		removeFile: store.removeDraftFile,
		closeViewer: store.closeViewer,
		editJoin: store.editJoin,
		attachRoomsSession: async (sturdyref) => {
			const why = await attachRoomsController(sturdyref, {
				current: workspaceControllerSelection,
				localCheckpoint: () => workspaceStateOf(store.get()).session,
				connect: connectAttachedRoomsSession,
				select: setWorkspaceControllerSelection,
				reportCleanupFailure: (error) => {
					store.noteTrouble(
						"shared session attachment cleanup",
						error instanceof Error ? error.message : String(error),
					);
				},
			});
			if (why === "") location.reload();
			return why;
		},
		useLocalRoomsSession: () => {
			if (!setWorkspaceControllerSelection({ kind: "local" })) {
				return "This browser refused to save local Rooms reconstruction.";
			}
			location.reload();
			return "";
		},
		leaveRoomsSession: () => {
			if (!setWorkspaceControllerSelection({ kind: "none" })) {
				return "This browser refused to leave the current Rooms session.";
			}
			location.reload();
			return "";
		},
		roomsController: workspaceControllerSelection,
		resetBrowserWorkspace: () => {
			if (!clearWorkspaceState()) return "This browser refused to forget the saved workspace.";
			location.reload();
			return "";
		},
		deleteBrowserData: async () => {
			const why = await deleteRoomsBrowserData();
			if (why === "") location.reload();
			return why;
		},
	};
}
