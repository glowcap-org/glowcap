import type { RoomsBrowserController } from "../controller/browser.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import * as store from "../store.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { AttachedSessionFiles } from "./attached_files.ts";
import { roomsPeerAuthority } from "../../../lib/routes.ts";
import { roomsLocator } from "../../../lib/locator.ts";
import { MAX_ROOM, newPrivateRoomKey, nickRefusal } from "../../../lib/limits.ts";
import { attachedCommandPowers, startAttachedDirectMessage } from "./attached_command_powers.ts";
import { attachedStateActions } from "./attached_state.ts";
import { attachedArchiveShareActions } from "./attached_archive_shares.ts";
import { attachedComposerActions } from "./attached_composer.ts";
import { attachedOperations } from "./attached_operations.ts";

function settleTransientTypingFailure(_error: unknown): void {
	// Connection state owns the visible failure. Typing is presence, not a
	// durable act, and repeating its refusal in the trouble journal would make
	// every keystroke another copy of the same disconnect.
}

export function createAttachedRoomsSession(
	browser: Pick<RoomsBrowserController, "aboutConversation" | "setTheme" | "showRoster">,
	controller: AttachedRoomsController,
	files: AttachedSessionFiles,
	options: { defaultDirectoryLocator?: string | null } = {},
): RoomsSessionController {
	const defaultDirectoryLocator = options.defaultDirectoryLocator ?? null;
	const failure = (error: unknown) => store.toast("failure", error instanceof Error ? error.message : String(error));
	const powers = attachedCommandPowers(controller, browser, failure);
	const active = () => store.activeConv();
	const readOnly = () => controller.current?.access !== "interact" && controller.current?.access !== "admin";
	const showConversation = (conversationId: string) => {
		const conversation = [...store.get().convs.values()].find((entry) => entry.persistId === conversationId);
		if (conversation != null) store.switchTo(conversation.key);
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
	const stateActions = attachedStateActions(controller);
	const archiveShareActions = attachedArchiveShareActions(controller, failure);
	const composerActions = attachedComposerActions(controller, powers, failure);
	const operations = attachedOperations(controller);
	return {
		...stateActions,
		...archiveShareActions,
		...composerActions,
		...operations.actions,
		directoryReady: Promise.resolve(),
		openPrivateRoom: (directory, label) => {
			void controller.openPrivateRoom({
				kind: "room",
				id: crypto.randomUUID(),
				directory,
				name: label,
				held: true,
				standing: null,
				draft: "",
			}, newPrivateRoomKey()).catch(failure);
		},
		acceptInvite: async (id) => {
			await controller.acceptInvitation(id);
		},
		declineInvite: (id) => {
			void controller.dismissInvitation(id).catch(failure);
		},
		connectIrcIdentity: async (key, nick, account, password) => {
			const conversation = store.getConv(key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.connectRoomIrc(conversation.persistId, nick, account, password);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		disconnectIrcIdentity: async (key) => {
			const conversation = store.getConv(key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.disconnectRoomIrc(conversation.persistId);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		stewardRoom: async (key, link) => {
			const conversation = store.getConv(key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.takeRoomModerator(conversation.persistId, link?.trim() || undefined);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		createRoomLink: async (key) => {
			const conversation = store.getConv(key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.ensureRoomLink(conversation.persistId);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		askRoomMemberOut: async (key, name) => {
			const conversation = store.getConv(key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.kickRoomMember(conversation.persistId, name);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		pickRoom: (directory, name, key) => {
			const existing = key == null
				? controller.current?.checkpoint.conversations.find((conversation) =>
					conversation.kind === "room" && conversation.directory === directory && conversation.name === name
				)
				: (() => {
					const conversation = store.getConv(key);
					return conversation == null
						? undefined
						: controller.current?.checkpoint.conversations.find((entry) =>
							entry.id === conversation.persistId
						);
				})();
			if (existing != null) {
				selectConversation(existing.id);
				return;
			}
			if (readOnly()) {
				failure(new Error("This session capability is read only and cannot join another room."));
				return;
			}
			void controller.joinRoom({
				kind: "room",
				id: crypto.randomUUID(),
				directory,
				name,
				held: false,
				standing: null,
				draft: "",
			}).catch(failure);
		},
		openConv: (key) => {
			const conversation = store.getConv(key);
			if (conversation == null) return;
			selectConversation(conversation.persistId);
		},
		setStanding: (standing) => void controller.setStanding(standing).catch(failure),
		releaseNick: async (directory) => {
			try {
				await controller.setDirectoryNick(directory, "");
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		setDirStanding: (directory, standing) =>
			void controller.setDirectoryStanding(directory, standing).catch(failure),
		setRoomStanding: (key, standing) => {
			const conversation = store.getConv(key);
			if (conversation?.type !== "room") return;
			void controller.setRoomStanding(conversation.persistId, standing).catch(failure);
		},
		leaveRoom: (key) => {
			const conversation = store.getConv(key);
			if (conversation?.type !== "room") return;
			void controller.leaveConversation(conversation.persistId).catch(failure);
		},
		leaveDirectory: (directory) => void controller.leaveDirectory(directory).catch(failure),
		closeDm: (conversation) => void controller.leaveConversation(conversation.persistId).catch(failure),
		endConv: () => {
			const conversation = active();
			if (conversation == null) return;
			void controller.leaveConversation(conversation.persistId).catch(failure);
		},
		applySettings: async (next) => {
			const checkpoint = controller.current?.checkpoint;
			if (checkpoint == null) return false;
			try {
				await controller.chooseConnection(
					next.dm ?? checkpoint.dmMode,
					next.viz ?? checkpoint.vizOverride,
				);
				location.reload();
				return true;
			} catch (error) {
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
				return error instanceof Error ? error.message : String(error);
			}
		},
		retryArchivePeer: async () => {
			const sturdyref = controller.current?.checkpoint.capabilities.archivePeer;
			if (sturdyref == null) return "The shared session is using its own durable archive.";
			try {
				await controller.selectArchive(sturdyref);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		useDeviceArchive: async () => {
			await controller.selectArchive(null);
		},
		withdraw: (key, id) => {
			const conversation = store.getConv(key);
			const item = conversation?.history.find((row) => row.id === id);
			if (conversation == null || item?.kind !== "chat" || item.lineId == null) return;
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
				return error instanceof Error ? error.message : String(error);
			}
		},
		resolveSessionEffect: async (id, outcome) => {
			try {
				await controller.resolveEffect(id, outcome);
				await operations.refreshOperator();
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		issueSessionGrant: async (id, rights, label) => {
			try {
				await controller.issueGrant(id, rights, label);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		revokeSessionGrant: async (id) => {
			try {
				await controller.revokeGrant(id);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		selfLocator: () => controller.current?.memberLocator ?? null,
		directoryLocator: () =>
			controller.current?.checkpoint.directories.find((directory) => directory.home)?.locator ??
				defaultDirectoryLocator,
		dirAddress: (directory) =>
			controller.current?.checkpoint.directories.find((candidate) => candidate.id === directory)?.locator ??
				directory,
		directoryId: (locator) => {
			try {
				return roomsPeerAuthority(roomsLocator(locator)) as ReturnType<RoomsSessionController["directoryId"]>;
			} catch {
				return null;
			}
		},
		startDm: (who) => {
			const directory = active()?.dir ??
				controller.current?.checkpoint.directories.find((candidate) => candidate.home)?.id;
			if (directory == null) {
				store.toast("failure", "Join a directory before starting a direct conversation.");
				return;
			}
			startAttachedDirectMessage(controller, directory, who, failure);
		},
		// Shared sends are recovered by the durable session, so the attached view
		// does not expose local retry or cancellation controls. Keep the session
		// verbs harmless if a stale caller invokes one during a transition.
		retry: () => {},
		stopSend: () => {},
		setTyping: (on) => {
			const conversation = active();
			if (conversation != null) {
				// Typing is transient presentation state. Losing one update at a
				// connection boundary must not surface as a durable operation failure.
				void controller.setTyping(conversation.persistId, on).catch(settleTransientTypingFailure);
			}
		},
		join: async (destination, nick, signal) => {
			if (signal?.aborted) return "";
			if (destination.room === "" || destination.room.length > MAX_ROOM) {
				return `A room name must be between 1 and ${MAX_ROOM} characters.`;
			}
			const nickWhy = nickRefusal(nick);
			if (nickWhy != null) return nickWhy;
			const checkpoint = controller.current?.checkpoint;
			if (checkpoint == null) return "The shared session has not produced its workspace yet.";
			const locator = destination.locator.trim() || checkpoint.directories.find((entry) => entry.home)?.locator ||
				defaultDirectoryLocator;
			if (locator == null) return "Name the directory to join.";
			let directoryId: string;
			try {
				directoryId = roomsPeerAuthority(roomsLocator(locator));
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
			if (signal?.aborted) return "";
			const existing = checkpoint.directories.find((entry) => entry.id === directoryId);
			try {
				const room = {
					kind: "room" as const,
					id: crypto.randomUUID(),
					directory: directoryId,
					name: destination.room,
					held: destination.hidden === true,
					standing: null,
					draft: "",
				};
				if (destination.hidden !== true) {
					await controller.joinRoom(room, { locator, nick });
					return "";
				}
				if (existing == null) {
					await controller.joinDirectory({
						id: directoryId,
						locator,
						home: checkpoint.directories.length === 0,
						nick,
						standing: null,
					});
				} else if (existing.nick !== nick) {
					await controller.setDirectoryNick(directoryId, nick);
				}
				if (signal?.aborted) return "";
				await controller.openPrivateRoom(room, newPrivateRoomKey());
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
	};
}
