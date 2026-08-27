// UI-facing operations for a Rooms session reconstructed in this browser.

import * as net from "../net.ts";
import * as prefs from "../prefs.ts";
import * as store from "../store.ts";
import { setHistoryKept } from "../history.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import { deleteRoomsBrowserData } from "../controller/browser_data.ts";
import { exportWorkspaceState, importWorkspaceState } from "../workspace_state.ts";

export function createLocalRoomsSession(): RoomsSessionController {
	return {
		directoryReady: net.directoryReady,
		pickRoom: net.pickRoom,
		leaveRoom: net.leaveRoom,
		openPrivateRoom: (dir, label) => {
			void net.openPrivateRoom(dir, label).then((why) => {
				if (why !== "") store.toast("failure", why);
			});
		},
		acceptInvite: (id) =>
			net.acceptInvite(id).then((why) => {
				if (why !== "") store.toast("failure", why);
			}),
		declineInvite: net.declineInvite,
		setStanding: net.setStanding,
		releaseNick: net.releaseDirectoryNick,
		setDirStanding: net.setDirStanding,
		setRoomStanding: net.setRoomStanding,
		connectIrcIdentity: net.connectIrcIdentity,
		disconnectIrcIdentity: net.disconnectIrcIdentity,
		stewardRoom: (key, link) => {
			const work = net.takeStewardship(key, link);
			if (work != null) return work;
			return Promise.resolve("This room membership is not connected right now.");
		},
		createRoomLink: net.createRoomLink,
		askRoomMemberOut: (key, name) => {
			const work = net.askMemberOutSettled(key, name);
			if (work != null) return work;
			return Promise.resolve("This tab does not hold this room's moderation capability.");
		},
		leaveDirectory: net.leaveDirectory,
		openConv: store.switchTo,
		closeDm: net.closeDm,
		endConv: net.endConversation,
		applySettings: (next) => Promise.resolve(prefs.apply(next)),
		exportRoomsState: exportWorkspaceState,
		importRoomsState: (raw) =>
			Promise.resolve().then(() => {
				const why = importWorkspaceState(raw);
				if (why === "") location.reload();
				return why;
			}),
		clearRoomsState: async () => {
			const why = await deleteRoomsBrowserData();
			if (why === "") location.reload();
			return why;
		},
		selfLocator: net.selfLocator,
		directoryLocator: net.directoryLocator,
		dirAddress: net.dirAddress,
		directoryId: net.directoryId,
		joinIrc: net.joinIrcBridge,
		partIrc: net.partIrcBridge,
		setKeepHistory: async (keep) => {
			await setHistoryKept(keep);
			store.setKeepHistory(keep);
		},
		takeArchivePeer: net.takeArchivePeer,
		retryArchivePeer: net.retryArchivePeer,
		useDeviceArchive: net.useDeviceArchive,
		shareArchiveHistory: net.shareArchiveHistory,
		readArchiveShare: net.readArchiveShare,
		dropArchiveShare: net.dropArchiveShare,
		readOpsBundle: net.readOpsBundle,
		replaceOpsBundle: net.replaceOpsBundle,
		refreshOpsCap: net.refreshOpsCap,
		listenerUp: net.requestListenerUp,
		listenerDown: net.requestListenerDown,
		giveRoomStewardship: net.requestStewardGive,
		revokeRoomStewardship: net.requestStewardRevoke,
		revokeRoomLink: net.requestRoomLinkRevoke,
		revokeNick: net.requestNickRevoke,
		disconnectSession: net.requestSessionDisconnect,
		removeOperatorRoom: net.requestOperatorRoomRemove,
		releaseOperatorReference: net.requestOperatorReferenceRelease,
		clearOperatorTrouble: net.requestOperatorTroubleClear,
		resumeSessionEffect: () => Promise.resolve("This browser is not attached to a durable Rooms session."),
		resolveSessionEffect: () => Promise.resolve("This browser is not attached to a durable Rooms session."),
		issueSessionGrant: () => Promise.resolve("This browser is not attached to a durable Rooms session."),
		revokeSessionGrant: () => Promise.resolve("This browser is not attached to a durable Rooms session."),
		resetOperatorScope: net.requestOperatorReset,
		loadMoreOperator: net.loadMoreOperator,
		searchOperator: async (query) => {
			await net.refreshOperator(query);
			return "";
		},
		retireMatchingOperator: net.retireMatchingOperator,
		publishPeeredRoom: net.publishPeeredRoom,
		revokePeeredPublication: net.revokePeeredPublication,
		startDm: net.startDm,
		retry: net.retrySend,
		stopSend: net.stopSend,
		withdraw: net.withdraw,
		mention: net.mention,
		setDraft: net.setDraft,
		recallLastSent: net.recallLastSent,
		send: net.send,
		openFile: net.openAttachment,
		openViewer: store.openViewer,
		stepViewer: net.stepViewer,
		setTyping: net.setTyping,
		join: net.joinRoom,
	};
}
