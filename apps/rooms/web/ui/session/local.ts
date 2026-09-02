// UI-facing operations for a Rooms session reconstructed in this browser.

import * as store from "../store.ts";
import { MEMBERSHIP_NOT_CONNECTED } from "../net/common.ts";
import { setHistoryKept } from "../history.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import { deleteRoomsBrowserData } from "../controller/browser_data.ts";
import { exportWorkspaceState, importWorkspaceState } from "../workspace/bundle.ts";
import type { CapabilitySetEventSource } from "../ops/capability_set_events.ts";
import type { ArchiveTargetController } from "../net/archive_target.ts";
import type { RoomsPageContext } from "../page.ts";
import * as net from "../net.ts";
import * as prefs from "../prefs.ts";
import { coverForReload, finishCoveredReload, uncoverReload } from "../boot.ts";

export function createLocalRoomsSession(
	page: RoomsPageContext,
	capabilityEvents: CapabilitySetEventSource,
	archives: ArchiveTargetController,
): RoomsSessionController {
	return {
		directoryReady: page.bootstrap.directoryReady,
		pickRoom: (dir, name, key) => net.pickRoom(page, dir, name, key),
		leaveRoom: (key) => net.leaveRoom(page, key),
		openManagedRoom: (dir, label, policy) => {
			void net.openManagedRoom(page, dir, label, policy).then((why) => {
				if (why !== "") store.toast(page.projection, "failure", why);
			});
		},
		acceptInvite: (id) =>
			net.acceptInvite(page, id).then((why) => {
				if (why !== "") store.toast(page.projection, "failure", why);
			}),
		declineInvite: (id) => net.declineInvite(page, id),
		setStanding: (standing) => net.setStanding(page, standing),
		releaseNick: (dir) => net.releaseDirectoryNick(page, dir),
		setDirStanding: (dir, standing) => net.setDirStanding(page, dir, standing),
		setRoomStanding: (key, standing) => net.setRoomStanding(page, key, standing),
		bridgeForm: (key) => net.askRoomBridgeForm(page, key),
		submitBridgeForm: (key, scope, action, answers, secrets) =>
			net.submitBridgeForm(page, key, scope, action, answers, secrets),
		stewardRoom: (key, link) => {
			const work = net.takeStewardship(page, key, link);
			if (work != null) return work;
			return Promise.resolve(MEMBERSHIP_NOT_CONNECTED);
		},
		dropRoomModerator: (key, token) => net.dropStewardship(page, key, token),
		managerRoom: (key, link) => net.takeRoomManager(page, key, link),
		dropRoomManager: (key, token) => net.dropRoomManager(page, key, token),
		revokeManagedRoomAuthority: (key, kind, token) => net.revokeManagedRoomAuthority(page, key, kind, token),
		unregisterManagedRoom: (key) => net.unregisterManagedRoom(page, key),
		setManagedRoomPolicy: (key, policy) => net.setManagedRoomPolicy(page, key, policy),
		createRoomLink: (key) => net.createRoomLink(page, key),
		recoverRoom: (key, link) => net.retryRoom(page, key, link),
		askRoomMemberOut: (key, name) => {
			const work = net.askMemberOutSettled(page, key, name);
			if (work != null) return work;
			return Promise.resolve("This tab does not hold this room's moderation capability.");
		},
		leaveDirectory: (dir) => net.leaveDirectory(page, dir),
		openConv: (key) => {
			store.switchTo(page.projection, key);
			return Promise.resolve();
		},
		closeDm: (conv) => net.closeDm(page, conv),
		endConv: () => net.endConversation(page),
		applySettings: (next) => Promise.resolve(prefs.apply(page, next)),
		exportRoomsState: (includeCapabilities) => exportWorkspaceState(page, includeCapabilities),
		importRoomsState: (raw) =>
			Promise.resolve().then(() => {
				coverForReload();
				const why = importWorkspaceState(page, raw);
				if (why !== "") {
					uncoverReload();
					return why;
				}
				finishCoveredReload();
				return "";
			}),
		clearRoomsState: async () => {
			coverForReload();
			const why = await deleteRoomsBrowserData(page);
			if (why !== "") {
				uncoverReload();
				return why;
			}
			finishCoveredReload(true);
			return "";
		},
		selfLocator: () => net.selfLocator(page),
		directoryLocator: () => net.directoryLocator(page),
		dirAddress: (dir) => net.dirAddress(page, dir),
		directoryId: net.directoryId,
		openBridgeConnection: (answers) => net.openBridgeConnection(page, JSON.stringify(answers)),
		closeBridgeConnection: (connectionId) => net.closeBridgeConnection(page, connectionId),
		addBridgeLease: (connectionId, answers) => net.addBridgeLease(page, connectionId, JSON.stringify(answers)),
		removeBridgeLease: (connectionId, leaseId) => net.removeBridgeLease(page, connectionId, leaseId),
		setKeepHistory: async (keep) => {
			await setHistoryKept(page, keep);
			store.setKeepHistory(page.projection, keep);
		},
		takeArchivePeer: (sturdyref, remember) => archives.takeArchivePeer(sturdyref, remember),
		retryArchivePeer: () => archives.retryArchivePeer(),
		useOwnedArchive: () => archives.useDeviceArchive(),
		shareArchiveHistory: (key, peer, records) => net.shareArchiveHistory(page, archives, key, peer, records),
		offerDurableArchive: (key, peer, records) => net.offerDurableArchive(page, archives, key, peer, records),
		readArchiveShare: (id) => net.readArchiveShare(page, id),
		dropArchiveShare: (id) => net.dropArchiveShare(page, id),
		listIssuedArchiveShares: () => archives.listShares(),
		revokeIssuedArchiveShare: async (id) => {
			try {
				await archives.revokeShare(id);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		readOpsBundle: () => net.readOpsBundle(page),
		replaceOpsBundle: async (raw) => {
			const result = await net.replaceOpsBundle(page, raw);
			capabilityEvents.broadcast();
			return result;
		},
		watchOpsBundle: (changed) => capabilityEvents.watch(changed),
		refreshOpsCap: (cap) => net.refreshOpsCap(page, cap),
		listenerUp: (transport, options) => net.requestListenerUp(page, transport, options),
		listenerDown: (id) => net.requestListenerDown(page, id),
		giveRoomStewardship: (name) => net.requestStewardGive(page, name),
		revokeRoomStewardship: (name) => net.requestStewardRevoke(page, name),
		revokeRoomLink: (name) => net.requestRoomLinkRevoke(page, name),
		revokeRoomAuthority: (kind, token) => net.requestRoomAuthorityRevoke(page, kind, token),
		recoverRoomManager: async (key) => {
			return await net.recoverRoomManager(page, key, (identity) => net.requestRoomManager(page, identity));
		},
		revokeNick: (nick, sessionId) => net.requestNickRevoke(page, nick, sessionId),
		disconnectSession: (id) => net.requestSessionDisconnect(page, id),
		removeOperatorRoom: (id) => net.requestOperatorRoomRemove(page, id),
		releaseOperatorReference: (id) => net.requestOperatorReferenceRelease(page, id),
		clearOperatorTrouble: () => net.requestOperatorTroubleClear(page),
		resumeSessionEffect: () => Promise.resolve("This browser is not attached to a durable Rooms session."),
		resolveSessionEffect: () => Promise.resolve("This browser is not attached to a durable Rooms session."),
		issueSessionGrant: () => Promise.resolve("This browser is not attached to a durable Rooms session."),
		changeSessionGrant: () => Promise.resolve("This browser is not attached to a durable Rooms session."),
		revokeSessionGrant: () => Promise.resolve("This browser is not attached to a durable Rooms session."),
		resetOperatorScope: (scope) => net.requestOperatorReset(page, scope),
		loadMoreOperator: (category) => net.loadMoreOperator(page, category),
		searchOperator: async (query, referenceKind) => {
			await net.refreshOperator(page, query, referenceKind);
			return "";
		},
		retireMatchingOperator: (category, query, limit, referenceKind) =>
			net.retireMatchingOperator(page, category, query, limit, referenceKind),
		publishPeeredRoom: (key, name) => net.publishPeeredRoom(page, key, name),
		revokePeeredPublication: (id) => net.revokePeeredPublication(page, id),
		startDm: (who) => net.startDm(page, who),
		retry: (key, id) => net.retrySend(page, key, id),
		stopSend: (key, id) => net.stopSend(page, key, id),
		withdraw: (key, id) => net.withdraw(page, key, id),
		mention: (who) => net.mention(page, who),
		setDraft: (text) => net.setDraft(page, text),
		recallLastSent: () => net.recallLastSent(page),
		send: () => net.send(page),
		openFile: (key, id) => net.openAttachment(page, key, id),
		openViewer: (key, id) => store.openViewer(page.projection, key, id),
		stepViewer: (direction) => net.stepViewer(page, direction),
		setTyping: (on) => net.setTyping(page, on),
		join: (destination, nick, signal) => net.joinRoom(page, destination, nick, signal),
		// No nick: a tab of its own records one per room it enters, not per
		// directory it reads, so there is nowhere here to put a name and nothing
		// that would read it back. The shared session keeps a per-directory nick
		// and does take it.
		reachDirectory: async (locator, _nick, signal) => {
			try {
				return await net.openDirectory(
					page,
					locator === "" ? null : locator,
					net.FIRST_BACKOFF_MS,
					signal,
				);
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
	};
}
