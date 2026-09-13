// Slash-command effects expressed through one attached Rooms session controller.

import * as store from "../store.ts";
import { directoryName, roomCalled } from "../text.ts";
import { dirId, liveRoomCounts } from "../types.ts";
import type { AttachedRoomsController } from "./attached.ts";
import type { RoomsBrowserController } from "../controller/browser.ts";
import type { PageProjection } from "../store/core.ts";
import type { CommandPowers } from "../commands.ts";
import type { WorkspaceDirectConversation as DirectConversation } from "../../../lib/rooms_state.ts";
import { NO_DIRECTORY_TO_GIVE_BACK, NOT_ON_A_DIRECTORY, thatLinkDidNotOpen } from "../commands/targets.ts";
import { refusalText } from "../../../lib/text/failure.ts";
import { alreadyInRoom, offeredRoom, roomLinkSaid } from "../../../lib/text/attached.ts";

const NO_GRANTS: ReadonlySet<string> = new Set();

/** Open a direct route for an invitation or archive share without changing selection. */
export function ensureAttachedDirect(
	controller: AttachedRoomsController,
	directory: string,
	who: string,
): Promise<DirectConversation> {
	return controller.chooseDirect(directory, who, false);
}

export function attachedCommandPowers(
	projection: PageProjection,
	controller: AttachedRoomsController,
	view: Pick<RoomsBrowserController, "aboutConversation" | "setTheme" | "showRoster">,
): CommandPowers {
	const active = () => store.activeConv(projection);
	const activeDirectory = () => {
		const activeDir = active()?.dir;
		if (activeDir != null) return activeDir;
		const home = controller.current?.checkpoint.directories.find((directory) => directory.home);
		return home == null ? null : dirId(home.id);
	};
	return {
		say: (text, key = projection.get().activeKey ?? undefined) => {
			if (key != null) store.deliver(projection, key, store.sysItem(projection, text));
		},
		joinRoom: (name) => {
			const directory = activeDirectory();
			if (directory == null) return NOT_ON_A_DIRECTORY;
			return controller.chooseRoom(directory, name).then(() => null);
		},
		joinLink: (link, label) => {
			const key = active()?.key ?? null;
			return controller.takeRoomLink(link, label ?? "").then((already) => {
				if (already && key != null) {
					store.deliver(projection, key, store.sysItem(projection, alreadyInRoom));
				}
				return null;
			}, (error) => {
				throw new Error(thatLinkDidNotOpen(refusalText(error)), {
					cause: error,
				});
			});
		},
		leaveHere: () => {
			const conversation = active();
			if (conversation == null) return;
			if (conversation.type === "directory") {
				store.dismissDirectoryView(projection, conversation.key);
				return;
			}
			return controller.leaveConversation(conversation.persistId).then(() => {});
		},
		directMessage: (who) => {
			const directory = activeDirectory();
			if (directory == null) return NOT_ON_A_DIRECTORY;
			return controller.chooseDirect(directory, who, true).then(() => null);
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
			return controller.preferences.setIgnoredName(name, true).then(() => {});
		},
		unignore: (name) => {
			const changed = projection.get().ignored.has(name.toLowerCase());
			return controller.preferences.setIgnoredName(name, false).then(() => changed);
		},
		ignored: () => [...projection.get().ignored].sort(),
		editLast: (text) => {
			const conversation = active();
			if (conversation == null || conversation.type === "directory") return false;
			const line = controller.lastEditableLine(conversation.persistId);
			if (line == null) return false;
			return controller.editLine(conversation.persistId, line, text).then(() => true);
		},
		withdrawLast: () => {
			const conversation = active();
			if (conversation == null || conversation.type === "directory") return false;
			const line = controller.lastEditableLine(conversation.persistId);
			if (line == null) return false;
			return controller.withdrawLine(conversation.persistId, line).then(() => true);
		},
		setTopic: (text) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			return controller.setRoomTopic(conversation.persistId, text).then(() => true);
		},
		setAway: (reason) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			return controller.preferences.setEffectiveStanding(conversation.persistId, reason).then(() => true);
		},
		invite: (name) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			return controller.inviteToRoom(conversation.persistId, name).then(() => {
				store.deliver(
					projection,
					conversation.key,
					store.sysItem(projection, offeredRoom(name)),
				);
				return true;
			});
		},
		kick: (name) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			return controller.kickRoomMember(conversation.persistId, name).then(() => true);
		},
		steward: (link) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			return controller.takeRoomModerator(conversation.persistId, link).then(() => true);
		},
		roomLink: (name) => {
			const conversation = active();
			if (conversation?.type !== "room") return false;
			return controller.roomLinkFor(conversation.persistId, name).then((room) => {
				store.deliver(
					projection,
					conversation.key,
					store.sysItem(
						projection,
						roomLinkSaid(roomCalled(room.name, room.held), room.link),
					),
				);
				return true;
			});
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
			return controller.leaveDirectory(directory).then(() => null);
		},
		aboutConversation: view.aboutConversation,
	};
}
