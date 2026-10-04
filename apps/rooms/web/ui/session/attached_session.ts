// The session controller an attached tab implements: store verbs over one
// durable Rooms session rather than a local directory peer.

import * as store from "../store.ts";
import { cannotJoinReadOnly } from "../../../lib/text/conversation.ts";
import type { RoomsBrowserController } from "../controller/browser.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { AttachedSessionFiles } from "./attached_files.ts";
import { directoryId as inspectDirectoryId } from "../application.ts";
import { attachedCommandPowers } from "./attached_command_powers.ts";
import { attachedStateActions, reloadWouldEndHostedSession } from "./attached_state.ts";
import { attachedArchiveShareActions } from "./attached_archive_shares.ts";
import { attachedComposerActions } from "./attached_composer.ts";
import { attachedOperations } from "./attached_operations.ts";
import type { CapabilitySetEventSource } from "../ops/capability_set_events.ts";
import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import type { RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import type { DirId, SessionConv } from "../types.ts";
import { privateRoomPolicy } from "../room_policy.ts";
import type { RoomsPageContext } from "../page.ts";
import { coverForReload, finishCoveredReload, uncoverReload } from "../boot.ts";
import { persistCurrentWorkspace } from "../workspace_state.ts";
import { writeSearch } from "../prefs.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import {
	archiveOwnDurable,
	connectionChoiceSaveRefused,
	joinDirectoryFirst,
	roomNoLongerInSession,
	roomNoLongerOpen,
	roomRecoveryFailed,
	roomRecoveryInProgress,
	roomRecoveryNeedsLink,
	roomStillUnavailable,
} from "../../../lib/text/attached.ts";
import { roomsErrorInMessage } from "../../../lib/error_codes.ts";

function settleTransientTypingFailure(_error: unknown): void {
	// Connection state owns the visible failure. Typing is presence, not a
	// durable act, and repeating its refusal in the trouble journal would make
	// every keystroke another copy of the same disconnect.
}

export function createAttachedRoomsSession(
	page: RoomsPageContext,
	browser: Pick<RoomsBrowserController, "aboutConversation" | "setTheme" | "showRoster">,
	controller: AttachedRoomsController,
	files: AttachedSessionFiles,
	options: {
		defaultDirectoryLocator?: string | null;
		capabilityEvents?: CapabilitySetEventSource;
		recoverSends?: boolean;
	} = {},
): RoomsSessionController {
	const projection = page.projection;
	const defaultDirectoryLocator = options.defaultDirectoryLocator ?? null;
	const failure = (error: unknown) => store.toast(projection, "failure", refusalText(error));
	const powers = attachedCommandPowers(projection, controller, browser);
	const active = () => store.activeConv(projection);
	const readOnly = () => controller.current?.access !== "interact" && controller.current?.access !== "admin";
	const showConversation = (conversationId: string) => {
		const conversation = store.convByPersistId(projection, conversationId);
		if (conversation != null) store.switchTo(projection, conversation.key);
	};
	const showSnapshotSelection = (snapshot: RoomsSessionSnapshot) => {
		if (snapshot.checkpoint.active != null) showConversation(snapshot.checkpoint.active);
	};
	const selectConversation = (conversationId: string) => {
		if (readOnly()) {
			showConversation(conversationId);
			return;
		}
		void controller.select(conversationId).then((selected) => {
			if (controller.current?.revision !== selected.revision || selected.checkpoint.active !== conversationId) {
				return;
			}
			showConversation(conversationId);
		}).catch(failure);
	};
	const openExisting = (conversation: RoomsSessionState["conversations"][number]) => {
		selectConversation(conversation.id);
	};
	const stateActions = attachedStateActions(page, controller);
	const archiveShareActions = attachedArchiveShareActions(projection, page, controller, failure);
	const { retireConversation, ...composerActions } = attachedComposerActions(
		projection,
		controller,
		powers,
		failure,
		options.recoverSends,
	);
	const retireConversations = (
		conversations: readonly SessionConv[],
		work: Promise<unknown>,
	): void => {
		const drafts = conversations.flatMap((conversation) => {
			const draft = projection.get().drafts.get(conversation.key);
			return draft == null ? [] : [{ conversation, draft }];
		});
		for (const conversation of conversations) controller.cancelDraftSave(conversation.persistId);
		void work.then(
			() => {
				for (const conversation of conversations) retireConversation(conversation.persistId);
			},
			(error) => {
				for (const { conversation, draft } of drafts) {
					if (controller.closed || store.draftFor(projection, conversation.key) !== draft) continue;
					void controller.scheduleDraft(conversation.persistId, draft.text).catch(failure);
				}
				failure(error);
			},
		).catch(failure);
	};
	const retireOne = (conversation: SessionConv): void =>
		retireConversations([conversation], controller.leaveConversation(conversation.persistId));
	const retireDirectoryAfterCommit = (directory: DirId): void => {
		const conversations = [...projection.get().convs.values()].filter(
			(conversation): conversation is SessionConv =>
				conversation.type !== "directory" && conversation.dir === directory,
		);
		retireConversations(conversations, controller.leaveDirectory(directory));
	};
	const operations = attachedOperations(page, projection, controller);
	const openManagedRoom = (
		directory: DirId,
		label: string,
		policy: import("../room_policy.ts").RoomPolicy,
	) => {
		void controller.chooseRoom(directory, label, policy).then(showSnapshotSelection).catch(failure);
	};

	return {
		...stateActions,
		...archiveShareActions,
		...composerActions,
		...operations.actions,
		watchOpsBundle: (changed) => options.capabilityEvents?.watch(changed) ?? (() => {}),
		directoryReady: Promise.resolve(),
		openManagedRoom,
		acceptInvite: async (id) => {
			await controller.acceptInvitation(id);
		},
		declineInvite: (id) => {
			void controller.dismissInvitation(id).catch(failure);
		},
		bridgeForm: (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return Promise.resolve(null);
			return controller.roomBridgeForm(conversation.persistId);
		},
		submitBridgeForm: async (key, scope, action, answers, secrets) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.submitRoomBridgeForm(conversation.persistId, scope, action, answers, secrets);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		stewardRoom: async (key, link) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.takeRoomModerator(conversation.persistId, link?.trim() || undefined);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		managerRoom: async (key, link) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.takeRoomManager(conversation.persistId, link.trim());
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		recoverRoomManager: async (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.recoverRoomManager(conversation.persistId);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		dropRoomManager: async (key, token) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.dropRoomManager(conversation.persistId, token);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		revokeManagedRoomAuthority: async (key, kind, token) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.revokeManagedRoomAuthority(conversation.persistId, kind, token);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		unregisterManagedRoom: async (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.unregisterManagedRoom(conversation.persistId);
				store.setRoomPolicy(projection, key, privateRoomPolicy());
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		setManagedRoomPolicy: async (key, policy) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.setManagedRoomPolicy(conversation.persistId, policy);
				store.setRoomPolicy(projection, key, policy);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		dropRoomModerator: async (key, token) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.dropRoomModerator(conversation.persistId, token);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		createRoomLink: async (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.ensureRoomLink(conversation.persistId);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		recoverRoom: async (key, link) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			const intended = controller.current?.checkpoint.conversations.find((entry) =>
				entry.kind === "room" && entry.id === conversation.persistId
			);
			if (intended?.kind !== "room") return roomNoLongerInSession;
			if (intended.reconnect === "requested") return roomRecoveryInProgress;
			const currentLink = link?.trim() ?? "";
			if (intended.held && currentLink === "" && intended.link == null) {
				return roomRecoveryNeedsLink;
			}
			try {
				await controller.joinRoom({
					...intended,
					...(currentLink === "" ? {} : { link: currentLink }),
				});
				const snapshot = await controller.refreshSnapshot();
				const recovered = snapshot.checkpoint.conversations.find((entry) => entry.id === intended.id);
				if (recovered?.kind === "room" && recovered.reconnect === "manual") {
					return snapshot.issues.find((issue) =>
						issue.subject === `room:${intended.directory}:${intended.id}`
					)
						?.reason ?? roomRecoveryFailed;
				}
				if (!snapshot.roomViews.some((view) => view.conversationId === intended.id)) {
					return snapshot.issues.find((issue) =>
						issue.subject === `room:${intended.directory}:${intended.id}`
					)
						?.reason ?? roomStillUnavailable;
				}
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		askRoomMemberOut: async (key, name) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return roomNoLongerOpen;
			try {
				await controller.kickRoomMember(conversation.persistId, name);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		pickRoom: (directory, name, key) => {
			if (!readOnly()) {
				const conversation = key == null ? null : store.getConv(projection, key);
				if (conversation != null && conversation.type !== "directory") {
					selectConversation(conversation.persistId);
				} else {
					void controller.chooseRoom(directory, name).then(showSnapshotSelection).catch(failure);
				}
				return;
			}
			const existing = key == null
				? controller.current?.checkpoint.conversations.find((conversation) =>
					conversation.kind === "room" && conversation.directory === directory && conversation.name === name
				)
				: (() => {
					const conversation = store.getConv(projection, key);
					if (conversation == null || conversation.type === "directory") return undefined;
					return controller.current?.checkpoint.conversations.find((entry) =>
						entry.id === conversation.persistId
					);
				})();
			if (existing != null) {
				openExisting(existing);
				return;
			}
			failure(new Error(cannotJoinReadOnly));
		},
		openConv: async (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation == null) return;
			if (conversation.type === "directory") {
				store.switchTo(projection, conversation.key);
				return;
			}
			const intended = controller.current?.checkpoint.conversations.find((entry) =>
				entry.id === conversation.persistId
			);
			if (intended == null) return;
			if (readOnly()) {
				showConversation(intended.id);
				return;
			}
			const selected = await controller.select(intended.id);
			if (controller.current?.revision !== selected.revision || selected.checkpoint.active !== intended.id) {
				return;
			}
			showConversation(intended.id);
		},
		setStanding: (standing) => void controller.preferences.setStanding(standing).catch(failure),
		releaseNick: async (directory) => {
			try {
				await controller.preferences.setDirectoryNick(directory, "");
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		setDirStanding: (directory, standing) =>
			void controller.preferences.setDirectoryStanding(directory, standing).catch(failure),
		setRoomStanding: (key, standing) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return;
			void controller.preferences.setRoomStanding(conversation.persistId, standing).catch(failure);
		},
		leaveRoom: (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return;
			retireOne(conversation);
		},
		leaveDirectory: (directory) => {
			retireDirectoryAfterCommit(directory);
		},
		closeDm: (conversation) => {
			retireOne(conversation);
		},
		endConv: () => {
			const conversation = active();
			if (conversation == null) return;
			if (conversation.type === "directory") {
				store.dismissDirectoryView(projection, conversation.key);
				return;
			}
			retireOne(conversation);
		},
		applySettings: async (next) => {
			const checkpoint = controller.current?.checkpoint;
			if (checkpoint == null) return false;
			const hosting = reloadWouldEndHostedSession(page);
			if (!hosting) coverForReload();
			try {
				const selected = await controller.chooseConnection(
					next.dm ?? checkpoint.dmMode,
					next.trace ?? checkpoint.traceOverride,
				);
				if (!persistCurrentWorkspace(page)) {
					throw new Error(connectionChoiceSaveRefused);
				}
				const url = new URL(location.href);
				writeSearch(url, { dm: selected.checkpoint.dmMode, trace: selected.checkpoint.traceOverride });
				history.replaceState(null, "", url);
				if (!hosting) finishCoveredReload();
				return true;
			} catch (error) {
				if (!hosting) uncoverReload();
				failure(error);
				return false;
			}
		},
		setKeepHistory: async (keep) => {
			await controller.chooseHistoryRetention(keep);
		},
		takeArchivePeer: async (sturdyref) => {
			try {
				await controller.selectArchive(sturdyref.trim());
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		retryArchivePeer: async () => {
			const sturdyref = controller.current?.checkpoint.capabilities.archivePeer;
			if (sturdyref == null) return archiveOwnDurable;
			try {
				await controller.selectArchive(sturdyref);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		useOwnedArchive: async () => {
			await controller.selectArchive(null);
		},
		withdraw: (key, id) => {
			const conversation = store.getConv(projection, key);
			const item = store.historyOf(projection, key).find((row) => row.id === id);
			if (
				conversation == null || conversation.type === "directory" || item?.kind !== "chat" ||
				item.lineId == null
			) return;
			void controller.withdrawLine(conversation.persistId, item.lineId).catch(failure);
		},
		openFile: (key, id) => files.open(key, id),
		openViewer: (key, id) => files.openViewer(key, id),
		stepViewer: (direction) => files.stepViewer(direction),
		resumeSessionEffect: async (id) => {
			try {
				await controller.resumeEffect(id);
				await operations.refreshOperator();
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		resolveSessionEffect: async (id, outcome) => {
			try {
				await controller.resolveEffect(id, outcome);
				await operations.refreshOperator();
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		issueSessionGrant: async (id, rights, label, history) => {
			try {
				await controller.issueGrant(id, rights, label, history);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		revokeSessionGrant: async (id) => {
			try {
				await controller.revokeGrant(id);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		changeSessionGrant: async (id, patch) => {
			try {
				await controller.changeGrant(id, patch);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		selfLocator: () => controller.current?.memberLocator ?? null,
		directoryLocator: () =>
			controller.current?.checkpoint.directories.find((directory) => directory.home)?.locator ??
				defaultDirectoryLocator,
		dirAddress: (directory) =>
			controller.current?.checkpoint.directories.find((candidate) => candidate.id === directory)?.locator ??
				directory,
		directoryId: inspectDirectoryId,
		startDm: (who) => {
			const directory = active()?.dir ??
				controller.current?.checkpoint.directories.find((candidate) => candidate.home)?.id;
			if (directory == null) {
				store.toast(projection, "failure", joinDirectoryFirst);
				return;
			}
			void controller.chooseDirect(directory, who, true).catch(failure);
		},
		setTyping: (on) => {
			const conversation = active();
			if (conversation == null || conversation.type === "directory") return;
			// Typing is transient presentation state. Losing one update at a
			// connection boundary must not surface as a durable operation failure.
			void controller.setTyping(conversation.persistId, on).catch(settleTransientTypingFailure);
		},
		reachDirectory: async (locator, nick, signal) => {
			if (signal?.aborted) return "";
			try {
				await controller.reachDirectory(locator, nick, defaultDirectoryLocator ?? "", signal);
				return "";
			} catch (error) {
				return refusalText(error);
			}
		},
		join: async (destination, nick, signal) => {
			if (signal?.aborted) return { ok: true };
			try {
				const snapshot = await controller.joinDestination(
					destination,
					nick,
					defaultDirectoryLocator ?? "",
					signal,
				);
				if (!signal?.aborted) showSnapshotSelection(snapshot);
				return { ok: true };
			} catch (error) {
				if (signal?.aborted) return { ok: true };
				return { ok: false, code: roomsErrorInMessage(error)?.code ?? null, text: refusalText(error) };
			}
		},
	};
}
