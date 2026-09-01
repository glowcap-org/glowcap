// The session controller an attached tab implements: store verbs over one
// durable Rooms session rather than a local directory peer.

import * as store from "../store.ts";
import type { RoomsBrowserController } from "../controller/browser.ts";
import type { RoomsSessionController } from "../controller/session.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { AttachedSessionFiles } from "./attached_files.ts";
import { roomsPeerAuthority } from "../../../lib/routes.ts";
import { roomsLocator } from "../../../lib/locator.ts";
import { MAX_ROOM, newManagedRoomId, nickRefusal } from "../../../lib/limits.ts";
import { attachedCommandPowers, startAttachedDirectMessage } from "./attached_command_powers.ts";
import { attachedStateActions, reloadWouldEndHostedSession } from "./attached_state.ts";
import { attachedArchiveShareActions } from "./attached_archive_shares.ts";
import { attachedComposerActions } from "./attached_composer.ts";
import { attachedOperations } from "./attached_operations.ts";
import type { CapabilitySetEventSource } from "../ops/capability_set_events.ts";
import type { RoomsSessionState } from "../../../lib/rooms_state.ts";
import type { RoomsSessionSnapshot } from "../../../lib/session/client.ts";
import { planJoinDestination, privateRoomNameRefusal } from "../joining.ts";
import { type DirId, dirId } from "../types.ts";
import { PRIVATE_ROOM_POLICY } from "../../../lib/room/policy.ts";
import type { RoomsPageContext } from "../page.ts";
import { coverForReload, finishCoveredReload, uncoverReload } from "../boot.ts";
import { directoryReachIsStanding, waitForDirectoryReach } from "./attached_directory_reach.ts";

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
	options: { defaultDirectoryLocator?: string | null; capabilityEvents?: CapabilitySetEventSource } = {},
): RoomsSessionController {
	const projection = page.projection;
	const defaultDirectoryLocator = options.defaultDirectoryLocator ?? null;
	const failure = (error: unknown) =>
		store.toast(projection, "failure", error instanceof Error ? error.message : String(error));
	const powers = attachedCommandPowers(projection, controller, browser, failure);
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
	const { retireConversation, retireDirectory, ...composerActions } = attachedComposerActions(
		projection,
		controller,
		powers,
		failure,
	);
	const operations = attachedOperations(projection, controller);
	const openManagedRoom = (
		directory: DirId,
		label: string,
		policy: import("../../../lib/room/policy.ts").RoomPolicy,
	) => {
		void controller.openManagedRoom(
			{
				kind: "room",
				id: crypto.randomUUID(),
				directory,
				name: label,
				held: policy.visibility === "secret",
				standing: null,
				draft: "",
			},
			newManagedRoomId(),
			policy,
		).then(showSnapshotSelection).catch(failure);
	};
	// The workspace record a directory needs before anything in it can be
	// named. Entering a room and reaching a directory to read its listing both
	// want it, and want it identically, so it is made once here rather than
	// spelled at each — two copies of a record shape are two things to keep
	// agreeing. Holding one already is not an error: the entry only has its
	// name brought up to date.
	const ensureDirectoryEntry = async (
		checkpoint: NonNullable<typeof controller.current>["checkpoint"],
		id: string,
		locator: string,
		nick: string,
	): Promise<void> => {
		const existing = checkpoint.directories.find((entry) => entry.id === id);
		if (existing == null) {
			await controller.joinDirectory({
				id,
				locator,
				home: checkpoint.directories.length === 0,
				reached: false,
				nick,
				standing: null,
			});
		} else if (existing.nick !== nick) {
			await controller.setDirectoryNick(id, nick);
		}
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
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.submitRoomBridgeForm(conversation.persistId, scope, action, answers, secrets);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		stewardRoom: async (key, link) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.takeRoomModerator(conversation.persistId, link?.trim() || undefined);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		managerRoom: async (key, link) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.takeRoomManager(conversation.persistId, link.trim());
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		recoverRoomManager: async (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.recoverRoomManager(conversation.persistId);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		dropRoomManager: async (key, token) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.dropRoomManager(conversation.persistId, token);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		revokeManagedRoomAuthority: async (key, kind, token) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.revokeManagedRoomAuthority(conversation.persistId, kind, token);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		unregisterManagedRoom: async (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.unregisterManagedRoom(conversation.persistId);
				store.setRoomPolicy(projection, key, PRIVATE_ROOM_POLICY);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		setManagedRoomPolicy: async (key, policy) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.setManagedRoomPolicy(conversation.persistId, policy);
				store.setRoomPolicy(projection, key, policy);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		dropRoomModerator: async (key, token) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.dropRoomModerator(conversation.persistId, token);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		createRoomLink: async (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			try {
				await controller.ensureRoomLink(conversation.persistId);
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		recoverRoom: async (key, link) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return "That room is no longer open.";
			const intended = controller.current?.checkpoint.conversations.find((entry) =>
				entry.kind === "room" && entry.id === conversation.persistId
			);
			if (intended?.kind !== "room") return "That room is no longer in this shared session.";
			if (intended.reconnect === "requested") return "This room recovery is already in progress.";
			const currentLink = link?.trim() ?? "";
			if (intended.held && currentLink === "" && intended.link == null) {
				return "Paste a current link for this private room.";
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
						?.reason ?? "That room could not be recovered. It still needs an explicit rejoin.";
				}
				if (!snapshot.roomViews.some((view) => view.conversationId === intended.id)) {
					return snapshot.issues.find((issue) =>
						issue.subject === `room:${intended.directory}:${intended.id}`
					)
						?.reason ?? "That room is still unavailable.";
				}
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		askRoomMemberOut: async (key, name) => {
			const conversation = store.getConv(projection, key);
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
			}).then(showSnapshotSelection).catch(failure);
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
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return;
			void controller.setRoomStanding(conversation.persistId, standing).catch(failure);
		},
		leaveRoom: (key) => {
			const conversation = store.getConv(projection, key);
			if (conversation?.type !== "room") return;
			retireConversation(conversation.persistId);
			void controller.leaveConversation(conversation.persistId).catch(failure);
		},
		leaveDirectory: (directory) => {
			retireDirectory(directory);
			void controller.leaveDirectory(directory).catch(failure);
		},
		closeDm: (conversation) => {
			retireConversation(conversation.persistId);
			void controller.leaveConversation(conversation.persistId).catch(failure);
		},
		endConv: () => {
			const conversation = active();
			if (conversation == null) return;
			if (conversation.type === "directory") {
				store.dismissDirectoryView(projection, conversation.key);
				return;
			}
			retireConversation(conversation.persistId);
			void controller.leaveConversation(conversation.persistId).catch(failure);
		},
		applySettings: async (next) => {
			const checkpoint = controller.current?.checkpoint;
			if (checkpoint == null) return false;
			const hosting = reloadWouldEndHostedSession(page);
			if (!hosting) coverForReload();
			try {
				await controller.chooseConnection(
					next.dm ?? checkpoint.dmMode,
					next.viz ?? checkpoint.vizOverride,
				);
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
		issueSessionGrant: async (id, rights, label, history) => {
			try {
				await controller.issueGrant(id, rights, label, history);
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
		changeSessionGrant: async (id, patch) => {
			try {
				await controller.changeGrant(id, patch);
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
				store.toast(projection, "failure", "Join a directory before starting a direct conversation.");
				return;
			}
			const why = startAttachedDirectMessage(projection, controller, directory, who, failure);
			if (why != null) failure(new Error(why));
		},
		// Shared sends are recovered by the durable session, so the attached view
		// does not expose local retry or cancellation controls. Keep the session
		// verbs harmless if a stale caller invokes one during a transition.
		retry: () => {},
		stopSend: () => {},
		setTyping: (on) => {
			const conversation = active();
			if (conversation == null || conversation.type === "directory") return;
			// Typing is transient presentation state. Losing one update at a
			// connection boundary must not surface as a durable operation failure.
			void controller.setTyping(conversation.persistId, on).catch(settleTransientTypingFailure);
		},
		// The directory half of `join`, on its own: a card that needs a listing
		// before it can tell one room from another asks for the directory first
		// and the room after. Adding one the session already holds is not an
		// error, so an existing entry only has its name brought up to date.
		reachDirectory: async (locator, nick, signal) => {
			if (signal?.aborted) return "";
			const address = locator === "" ? defaultDirectoryLocator : locator;
			if (address == null) return "Name the directory to join.";
			let directory: string;
			try {
				directory = roomsPeerAuthority(roomsLocator(address));
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
			const nickWhy = nickRefusal(nick);
			if (nickWhy != null) return nickWhy;
			const checkpoint = controller.current?.checkpoint;
			if (checkpoint == null) return "The shared session has not produced its workspace yet.";
			const existing = checkpoint.directories.find((entry) => entry.id === directory);
			try {
				await ensureDirectoryEntry(checkpoint, directory, address, nick);
				const why = await waitForDirectoryReach(controller, directory, signal);
				if (!directoryReachIsStanding(existing) && (why !== "" || signal?.aborted === true)) {
					await controller.leaveDirectory(directory).catch(() => {
						// best-effort: the card already has the reach refusal or the stop;
						// a leftover workspace row would keep dialling a locator the reader
						// is still looking at to correct.
					});
				}
				if (signal?.aborted) return "";
				return why;
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
		join: async (destination, nick, signal) => {
			if (signal?.aborted) return "";
			let planned: ReturnType<typeof planJoinDestination>;
			try {
				planned = planJoinDestination(destination);
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
			if (planned.kind === "directory" && (planned.room === "" || planned.room.length > MAX_ROOM)) {
				return `A room name must be between 1 and ${MAX_ROOM} characters.`;
			}
			if (planned.kind === "room-link" && planned.label.length > MAX_ROOM) {
				return `A room name must be at most ${MAX_ROOM} characters.`;
			}
			const nickWhy = nickRefusal(nick);
			if (nickWhy != null) return nickWhy;
			const checkpoint = controller.current?.checkpoint;
			if (checkpoint == null) return "The shared session has not produced its workspace yet.";
			if (planned.kind === "room-link") {
				if (signal?.aborted) return "";
				try {
					showSnapshotSelection(
						await controller.joinRoom({
							kind: "room",
							id: crypto.randomUUID(),
							directory: planned.directory,
							name: planned.label || "a room",
							held: true,
							link: planned.link,
							standing: null,
							draft: "",
						}, { locator: planned.address, nick }),
					);
					return "";
				} catch (error) {
					return error instanceof Error ? error.message : String(error);
				}
			}
			const locator = planned.locator.trim() || checkpoint.directories.find((entry) => entry.home)?.locator ||
				defaultDirectoryLocator;
			if (locator == null) return "Name the directory to join.";
			let directoryId: string;
			try {
				directoryId = roomsPeerAuthority(roomsLocator(locator));
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
			if (signal?.aborted) return "";
			try {
				const room = {
					kind: "room" as const,
					id: crypto.randomUUID(),
					directory: directoryId,
					name: planned.room,
					held: planned.policy.visibility === "secret",
					standing: null,
					draft: "",
				};
				if (planned.policy.visibility === "listed" && planned.policy.speaking === "open") {
					showSnapshotSelection(await controller.joinRoom(room, { locator, nick }));
					return "";
				}
				if (planned.policy.visibility === "secret") {
					const collision = privateRoomNameRefusal(
						planned.room,
						[...(projection.get().dirs.get(dirId(directoryId))?.liveRooms.values() ?? [])].map((
							entry,
						) => entry.name),
					);
					if (collision != null) return collision;
				}
				await ensureDirectoryEntry(checkpoint, directoryId, locator, nick);
				if (signal?.aborted) return "";
				showSnapshotSelection(await controller.openManagedRoom(room, newManagedRoomId(), planned.policy));
				return "";
			} catch (error) {
				return error instanceof Error ? error.message : String(error);
			}
		},
	};
}
