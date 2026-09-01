// Slash-command effects expressed through one attached Rooms session controller.

import * as store from "../store.ts";
import { directoryName, roomCalled } from "../text.ts";
import { dirId, liveRoomCounts } from "../types.ts";
import { roomsPeerAuthority } from "../../../lib/routes.ts";
import { parseRoomsSturdyref } from "../../../lib/locator.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { RoomsBrowserController } from "../controller/browser.ts";
import type { PageProjection } from "../store/core.ts";
import type { CommandPowers } from "../commands.ts";
import type { WorkspaceDirectConversation as DirectConversation } from "../../../lib/rooms_state.ts";
import {
	DIRECT_NOT_SELF,
	NO_DIRECTORY_TO_GIVE_BACK,
	NOT_ON_A_DIRECTORY,
	notRegisteredForDirect,
	thatLinkDidNotOpen,
} from "../commands/targets.ts";

const JOIN_LINK_NEEDS_HELD_DIRECTORY =
	"Join the directory named by that room entry link before taking it up in this shared session.";
const NO_GRANTS: ReadonlySet<string> = new Set();

function intendedAttachedDirect(
	projection: PageProjection,
	controller: AttachedRoomsController,
	directory: string,
	who: string,
): { error: string } | { existing: DirectConversation } | { created: DirectConversation } {
	if (store.isSelf(projection, dirId(directory), who)) {
		return { error: DIRECT_NOT_SELF };
	}
	const registration = store.peerRegistration(projection, dirId(directory), who);
	if (registration == null) {
		return { error: notRegisteredForDirect(who) };
	}
	const existing = controller.current?.checkpoint.conversations.find((conversation) =>
		conversation.kind === "direct" && !conversation.closed && conversation.directory === directory &&
		conversation.peerRegistrationId === registration.registrationId
	);
	if (existing?.kind === "direct") return { existing };
	return {
		created: {
			kind: "direct",
			id: crypto.randomUUID(),
			directory,
			peer: registration.name,
			peerRegistrationId: registration.registrationId,
			closed: false,
			draft: "",
		},
	};
}

/** Open one attached direct conversation, reusing the live intended record when
 * this tab already has one for the same directory and peer. A second record for
 * the same peer makes the durable session's inbound route ambiguous.
 * `null` when the line was opened or selected. A sentence when this tab does
 * not hold an introduction to them — the caller explains that, the way the
 * catalog does for `/msg` and a click does for the sidebar. */
export function startAttachedDirectMessage(
	projection: PageProjection,
	controller: AttachedRoomsController,
	directory: string,
	who: string,
	onFailure: (error: unknown) => void,
): string | null {
	const intended = intendedAttachedDirect(projection, controller, directory, who);
	if ("error" in intended) return intended.error;
	if ("existing" in intended) {
		void controller.select(intended.existing.id).catch(onFailure);
		return null;
	}
	void controller.openDirect(intended.created).catch(onFailure);
	return null;
}

/** Ensure a same-directory DM exists without changing the reader's selection.
 * Room-card person-to-person acts (invite, archive share) use this so a pipe
 * can open beside the room they are already looking at. */
export async function ensureAttachedDirect(
	projection: PageProjection,
	controller: AttachedRoomsController,
	directory: string,
	who: string,
): Promise<DirectConversation> {
	const intended = intendedAttachedDirect(projection, controller, directory, who);
	if ("error" in intended) throw new Error(intended.error);
	if ("existing" in intended) return intended.existing;
	if (controller.current == null) throw new Error("the shared session has not produced its workspace yet");
	await controller.startDirect(intended.created);
	return intended.created;
}

export function attachedCommandPowers(
	projection: PageProjection,
	controller: AttachedRoomsController,
	view: Pick<RoomsBrowserController, "aboutConversation" | "setTheme" | "showRoster">,
	onFailure: (error: unknown) => void,
): CommandPowers {
	const active = () => store.activeConv(projection);
	const activeDirectory = () => {
		const activeDir = active()?.dir;
		if (activeDir != null) return activeDir;
		const home = controller.current?.checkpoint.directories.find((directory) => directory.home);
		return home == null ? null : dirId(home.id);
	};
	return {
		say: (text) => store.deliverActive(projection, store.sysItem(projection, text)),
		joinRoom: (name) => {
			const directory = activeDirectory();
			if (directory == null) return NOT_ON_A_DIRECTORY;
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
			return null;
		},
		joinLink: (link, label) => {
			let authority: string;
			try {
				authority = roomsPeerAuthority(parseRoomsSturdyref(link).locator);
			} catch (error) {
				return thatLinkDidNotOpen(error instanceof Error ? error.message : String(error));
			}
			const directory = controller.current?.checkpoint.directories.find((entry) => entry.id === authority);
			if (directory == null) return JOIN_LINK_NEEDS_HELD_DIRECTORY;
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
			return null;
		},
		leaveHere: () => {
			const conversation = active();
			if (conversation == null) return;
			if (conversation.type === "directory") {
				store.dismissDirectoryView(projection, conversation.key);
				return;
			}
			void controller.leaveConversation(conversation.persistId).catch(onFailure);
		},
		directMessage: (who) => {
			const directory = activeDirectory();
			if (directory == null) return NOT_ON_A_DIRECTORY;
			return startAttachedDirectMessage(projection, controller, directory, who, onFailure);
		},
		you: () => {
			const directory = activeDirectory();
			return directory == null ? "" : store.dirNick(projection, directory);
		},
		setTheme: view.setTheme,
		showRoster: view.showRoster,
		clearHere: () => {
			const key = projection.get().activeKey;
			if (key != null) store.clearHistory(projection, key);
		},
		ignore: (name) => {
			const next = new Set(projection.get().ignored);
			next.add(name.toLowerCase());
			void controller.setIgnoredNames([...next]).catch(onFailure);
		},
		unignore: (name) => {
			const next = new Set(projection.get().ignored);
			const changed = next.delete(name.toLowerCase());
			if (changed) void controller.setIgnoredNames([...next]).catch(onFailure);
			return changed;
		},
		ignored: () => [...projection.get().ignored].sort(),
		editLast: (text) => {
			const conversation = active();
			const line = conversation == null
				? null
				: [...store.historyOf(projection, conversation.key)].reverse().find((item) =>
					item.kind === "chat" && item.mine && !item.withdrawn && item.lineId != null
				);
			if (
				conversation == null || conversation.type === "directory" || line?.kind !== "chat" ||
				line.lineId == null
			) return false;
			void controller.editLine(conversation.persistId, line.lineId, text).catch(onFailure);
			return true;
		},
		withdrawLast: () => {
			const conversation = active();
			const line = conversation == null
				? null
				: [...store.historyOf(projection, conversation.key)].reverse().find((item) =>
					item.kind === "chat" && item.mine && !item.withdrawn && item.lineId != null
				);
			if (
				conversation == null || conversation.type === "directory" || line?.kind !== "chat" ||
				line.lineId == null
			) return false;
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
			} else if (projection.get().dirs.get(conversation.dir)?.standing != null) {
				void controller.setDirectoryStanding(conversation.dir, reason === "" ? null : reason).catch(onFailure);
			} else void controller.setStanding(reason).catch(onFailure);
			return true;
		},
		invite: (name) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			void (async () => {
				const direct = await ensureAttachedDirect(projection, controller, conversation.dir, name);
				const room = controller.current?.checkpoint.conversations.find((candidate) =>
					candidate.kind === "room" && candidate.id === conversation.persistId
				);
				if (room?.kind !== "room") throw new Error("that room is no longer in the shared session");
				await controller.offerRoom(room.id, direct.id);
				store.deliver(
					projection,
					conversation.key,
					store.sysItem(projection, `${name} has been offered this room.`),
				);
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
				: [...projection.get().convs.values()].find((candidate) =>
					candidate.type === "room" && candidate.dir === conversation.dir && candidate.id === name
				);
			if (room?.type !== "room") return false;
			if (room.link != null) {
				store.deliverActive(
					projection,
					store.sysItem(
						projection,
						`Anybody who holds this link can be in ${roomCalled(room.id, room.held)}:\n  ${room.link}`,
					),
				);
				return true;
			}
			void controller.ensureRoomLink(room.persistId).then((snapshot) => {
				const linked = snapshot.checkpoint.conversations.find((candidate) => candidate.id === room.persistId);
				if (linked?.kind === "room" && linked.link != null) {
					store.deliverActive(
						projection,
						store.sysItem(
							projection,
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
			return conversation?.type === "room" ? store.standingFor(projection, conversation.key) : "";
		},
		granted: () => {
			const conversation = active();
			return conversation?.type === "room" ? conversation.grants : NO_GRANTS;
		},
		liveRooms: () => liveRoomCounts(store.actingDir(projection)?.liveRooms ?? new Map()),
		roster: () => {
			const conversation = active();
			if (conversation?.type !== "room") return [];
			const reachable = projection.get().dirs.get(conversation.dir)?.dmablePeers ?? new Set<string>();
			return [...store.membersOf(projection, conversation.key)].map(([name, standing]) => ({
				name,
				online: standing.online,
				away: standing.away,
				reachable: reachable.has(name.toLowerCase()),
			}));
		},
		directories: () => {
			const state = projection.get();
			return [...state.dirs.values()].map((directory) => ({
				locator: directory.locator,
				name: directoryName(directory.id, state.homeDir),
				nick: directory.nick,
				standing: store.standingOn(projection, directory.id, state),
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
			if (directory == null) return NO_DIRECTORY_TO_GIVE_BACK;
			void controller.leaveDirectory(directory).catch(onFailure);
			return null;
		},
		aboutConversation: view.aboutConversation,
	};
}
