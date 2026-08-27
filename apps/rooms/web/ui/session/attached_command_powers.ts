// Slash-command effects expressed through one attached Rooms session controller.

import type { CommandPowers } from "../commands.ts";
import * as store from "../store.ts";
import { directoryName, roomCalled } from "../text.ts";
import { dirId, liveRoomCounts } from "../types.ts";
import { roomsPeerAuthority } from "../../../lib/routes.ts";
import { parseRoomsSturdyref } from "../../../lib/locator.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { RoomsBrowserController } from "../controller/browser.ts";

const NO_GRANTS: ReadonlySet<string> = new Set();

/** Open one attached direct conversation, reusing the live intended record when
 * this tab already has one for the same directory and peer. A second record for
 * the same peer makes the durable session's inbound route ambiguous. */
export function startAttachedDirectMessage(
	controller: AttachedRoomsController,
	directory: string,
	who: string,
	onFailure: (error: unknown) => void,
): void {
	const registration = store.peerRegistration(dirId(directory), who);
	if (registration == null) {
		onFailure(new Error(`${who} is not registered for direct messages on that directory`));
		return;
	}
	const existing = controller.current?.checkpoint.conversations.find((conversation) =>
		conversation.kind === "direct" && !conversation.closed && conversation.directory === directory &&
		conversation.peerRegistrationId === registration.registrationId
	);
	if (existing?.kind === "direct") {
		void controller.select(existing.id).catch(onFailure);
		return;
	}
	const direct = {
		kind: "direct" as const,
		id: crypto.randomUUID(),
		directory,
		peer: registration.name,
		peerRegistrationId: registration.registrationId,
		closed: false,
		draft: "",
	};
	void controller.openDirect(direct).catch(onFailure);
}

export function attachedCommandPowers(
	controller: AttachedRoomsController,
	view: Pick<RoomsBrowserController, "aboutConversation" | "setTheme" | "showRoster">,
	onFailure: (error: unknown) => void,
): CommandPowers {
	const active = () => store.activeConv();
	const activeDirectory = () => {
		const activeDir = active()?.dir;
		if (activeDir != null) return activeDir;
		const home = controller.current?.checkpoint.directories.find((directory) => directory.home);
		return home == null ? null : dirId(home.id);
	};
	return {
		say: (text) => store.deliverActive(store.sysItem(text)),
		joinRoom: (name) => {
			const directory = activeDirectory();
			if (directory == null) {
				store.deliverActive(store.sysItem("There is no directory to enter a room on yet."));
				return;
			}
			const room = {
				kind: "room" as const,
				id: crypto.randomUUID(),
				directory,
				name,
				held: false,
				standing: null,
				draft: "",
			};
			void controller.joinRoom(room).catch(onFailure);
		},
		joinLink: (link, label) => {
			try {
				const authority = roomsPeerAuthority(parseRoomsSturdyref(link).locator);
				const directory = controller.current?.checkpoint.directories.find((entry) => entry.id === authority);
				if (directory == null) {
					store.deliverActive(
						store.sysItem(
							"Join the directory named by that room link before taking it up in this shared session.",
						),
					);
					return;
				}
				const room = {
					kind: "room" as const,
					id: crypto.randomUUID(),
					directory: directory.id,
					name: label || "private room",
					held: true,
					link,
					standing: null,
					draft: "",
				};
				void controller.joinRoom(room).catch(onFailure);
			} catch (error) {
				onFailure(error);
			}
		},
		leaveHere: () => {
			const conversation = active();
			if (conversation != null) void controller.leaveConversation(conversation.persistId).catch(onFailure);
		},
		directMessage: (who) => {
			const directory = activeDirectory();
			if (directory == null) return;
			startAttachedDirectMessage(controller, directory, who, onFailure);
		},
		you: () => {
			const directory = activeDirectory();
			return directory == null ? "" : store.dirNick(directory);
		},
		setTheme: view.setTheme,
		showRoster: view.showRoster,
		clearHere: () => {
			const key = store.get().activeKey;
			if (key != null) store.clearHistory(key);
		},
		ignore: (name) => {
			const next = new Set(store.get().ignored);
			next.add(name.toLowerCase());
			void controller.setIgnoredNames([...next]).catch(onFailure);
		},
		unignore: (name) => {
			const next = new Set(store.get().ignored);
			const changed = next.delete(name.toLowerCase());
			if (changed) void controller.setIgnoredNames([...next]).catch(onFailure);
			return changed;
		},
		ignored: () => [...store.get().ignored].sort(),
		editLast: (text) => {
			const conversation = active();
			const line = conversation == null
				? null
				: [...conversation.history].reverse().find((item) =>
					item.kind === "chat" && item.mine && !item.withdrawn && item.lineId != null
				);
			if (conversation == null || line?.kind !== "chat" || line.lineId == null) return false;
			void controller.editLine(conversation.persistId, line.lineId, text).catch(onFailure);
			return true;
		},
		withdrawLast: () => {
			const conversation = active();
			const line = conversation == null
				? null
				: [...conversation.history].reverse().find((item) =>
					item.kind === "chat" && item.mine && !item.withdrawn && item.lineId != null
				);
			if (conversation == null || line?.kind !== "chat" || line.lineId == null) return false;
			void controller.withdrawLine(conversation.persistId, line.lineId).catch(onFailure);
			return true;
		},
		setTopic: (text) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			void controller.setRoomTopic(conversation.persistId, text).catch(onFailure);
			return true;
		},
		setAway: (reason) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			if (conversation.standing != null) {
				void controller.setRoomStanding(conversation.persistId, reason === "" ? null : reason).catch(onFailure);
			} else if (store.get().dirs.get(conversation.dir)?.standing != null) {
				void controller.setDirectoryStanding(conversation.dir, reason === "" ? null : reason).catch(onFailure);
			} else void controller.setStanding(reason).catch(onFailure);
			return true;
		},
		invite: (name) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			void (async () => {
				const registration = store.peerRegistration(conversation.dir, name);
				if (registration == null) throw new Error(`${name} is not registered for direct messages here`);
				let snapshot = controller.current;
				if (snapshot == null) throw new Error("the shared session has not produced its workspace yet");
				let direct = snapshot.checkpoint.conversations.find((candidate) =>
					candidate.kind === "direct" && candidate.directory === conversation.dir && !candidate.closed &&
					candidate.peerRegistrationId === registration.registrationId
				);
				if (direct == null) {
					direct = {
						kind: "direct" as const,
						id: crypto.randomUUID(),
						directory: conversation.dir,
						peer: registration.name,
						peerRegistrationId: registration.registrationId,
						closed: false,
						draft: "",
					};
					snapshot = await controller.startDirect(direct);
				}
				let room = snapshot.checkpoint.conversations.find((candidate) =>
					candidate.kind === "room" && candidate.id === conversation.persistId
				);
				if (room?.kind !== "room") throw new Error("that room is no longer in the shared session");
				const roomId = room.id;
				if (room.link == null) {
					snapshot = await controller.ensureRoomLink(roomId);
					room = snapshot.checkpoint.conversations.find((candidate) => candidate.id === roomId);
				}
				if (room?.kind !== "room" || room.link == null) {
					throw new Error("the shared session did not retain the room link before offering it");
				}
				await controller.offerRoom(roomId, direct.id);
				store.deliver(conversation.key, store.sysItem(`${name} has been offered this room.`));
			})().catch(onFailure);
			return true;
		},
		kick: (name) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			void controller.kickRoomMember(conversation.persistId, name).catch(onFailure);
			return true;
		},
		steward: (link) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			void controller.takeRoomModerator(conversation.persistId, link).catch(onFailure);
			return true;
		},
		roomLink: (name) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			const room = name == null || name === ""
				? conversation
				: [...store.get().convs.values()].find((candidate) =>
					candidate.type === "room" && candidate.dir === conversation.dir && candidate.id === name
				);
			if (room?.type !== "room") return false;
			if (room.link != null) {
				store.deliverActive(
					store.sysItem(
						`Anybody who holds this link can be in ${roomCalled(room.id, room.held)}:\n  ${room.link}`,
					),
				);
				return true;
			}
			void controller.ensureRoomLink(room.persistId).then((snapshot) => {
				const linked = snapshot.checkpoint.conversations.find((candidate) => candidate.id === room.persistId);
				if (linked?.kind === "room" && linked.link != null) {
					store.deliverActive(
						store.sysItem(
							`Anybody who holds this link can be in ${
								roomCalled(linked.name, linked.held)
							}:\n  ${linked.link}`,
						),
					);
				}
			}).catch(onFailure);
			return true;
		},
		standingHere: () => {
			const conversation = active();
			return conversation?.type === "room" ? store.standingFor(conversation.key) : "";
		},
		granted: () => {
			const conversation = active();
			return conversation?.type === "room" ? conversation.grants : NO_GRANTS;
		},
		liveRooms: () => liveRoomCounts(store.actingDir()?.liveRooms ?? new Map()),
		roster: () => {
			const conversation = active();
			if (conversation?.type !== "room") return [];
			const reachable = store.get().dirs.get(conversation.dir)?.dmablePeers ?? new Set<string>();
			return [...conversation.members].map(([name, standing]) => ({
				name,
				online: standing.online,
				away: standing.away,
				reachable: reachable.has(name.toLowerCase()),
			}));
		},
		directories: () => {
			const state = store.get();
			return [...state.dirs.values()].map((directory) => ({
				locator: directory.locator,
				name: directoryName(directory.id, state.homeDir),
				nick: directory.nick,
				standing: store.standingOn(directory.id, state),
				rooms: liveRoomCounts(directory.liveRooms),
				joined: [...state.convs.values()].flatMap((conversation) =>
					conversation.type === "room" && conversation.dir === directory.id
						? [roomCalled(conversation.id, conversation.held)]
						: []
				),
				connected: controller.current?.connectedDirectories.includes(directory.id) === true,
			}));
		},
		quitDirectory: () => {
			const directory = activeDirectory();
			if (directory == null) store.deliverActive(store.sysItem("There is no directory to give back."));
			else void controller.leaveDirectory(directory).catch(onFailure);
		},
		aboutConversation: view.aboutConversation,
	};
}
