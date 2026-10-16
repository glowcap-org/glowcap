import { editLine } from "./edit.ts";
// Slash commands select exact conversation fields. Command names confer no
// authority and never cause recovery through a stronger entrance.
import { withdrawLine } from "./withdraw.ts";
import * as store from "../../store.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { RoomsBrowserController } from "../../controller/browser.ts";
import type { RoomsRoomController } from "../../controller/session.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { CommandPowers } from "../../commands.ts";
import { type DirId, liveRoomCounts } from "../../types.ts";
import { directoryName, roomCalled } from "../../text.ts";
import { NO_DIRECTORY_TO_GIVE_BACK, NOT_ON_A_DIRECTORY } from "../../commands/targets.ts";
import { JOIN_DEFAULT_NICK, roomLinkDestination } from "../../joining.ts";
import { alreadyInRoom } from "../../../../lib/text/attached.ts";
import { thatLinkDidNotOpen } from "../../../../lib/text/commands.ts";
import { refusalText } from "../../../../lib/text/failure.ts";

export function managedCommandPowers(
	page: RoomsPageContext,
	browser: Pick<RoomsBrowserController, "setTheme" | "showRoster" | "aboutConversation">,
	session: ManagedRoomsSession,
	rooms: RoomsRoomController,
	pick: (id: DirId, name: string) => Promise<void>,
	select: (id: string) => Promise<void>,
): CommandPowers {
	const projection = page.projection;
	const active = () => store.activeConv(projection);
	const directory = () =>
		active()?.dir ?? (session.current?.intent.directories.find((row) => row.home)?.id as DirId | undefined);
	const selected = () => {
		const row = active();
		return row == null || row.type === "directory"
			? null
			: session.current?.intent.conversations.find((entry) => entry.id === row.persistId);
	};
	// A held room was entered by this exact link when its retained access was
	// imported from it or minted as it. Labels and room names prove nothing.
	const enteredBy = async (link: string): Promise<string | null> => {
		for (const row of session.current?.intent.conversations ?? []) {
			if (row.kind !== "room" || row.access == null) continue;
			const coordinate = JSON.stringify({ role: "roomAccess", key: row.access });
			if (await session.workspace.custodyRecipe(coordinate) === link) return row.id;
		}
		return null;
	};
	const edit = async (verb: "editLine" | "withdrawLine", text?: string) => {
		const row = selected();
		const line = row?.lines?.at(-1);
		if (row == null || line == null) return false;
		const conversation = store.convByPersistId(projection, row.id);
		const item = conversation == null
			? null
			: store.historyOf(projection, conversation.key).find((item) =>
				item.kind === "chat" && item.lineId === line.id
			);
		if (verb === "withdrawLine" && conversation != null && item != null) {
			await withdrawLine(page, session, conversation.key, item.id);
		} else if (verb === "editLine" && conversation != null && item != null) {
			await editLine(page, session, conversation.key, item.id, text ?? "");
		} else await session.actions.run(verb, [row.id, String(line.id), ...(text == null ? [] : [text])]);
		return true;
	};
	return {
		say: (text, key = projection.get().activeKey ?? undefined) => {
			if (key != null) store.deliver(projection, key, store.sysItem(projection, text));
		},
		joinRoom: async (name) => {
			const id = directory();
			if (id == null) return NOT_ON_A_DIRECTORY;
			await pick(id, name);
			return null;
		},
		joinLink: async (link, name) => {
			try {
				const destination = roomLinkDestination(link, name);
				if (destination == null) throw new Error("that is not a room entry link");
				const held = await enteredBy(link);
				if (held != null) {
					await select(held);
					const key = store.convByPersistId(projection, held)?.key;
					if (key != null) store.deliver(projection, key, store.sysItem(projection, alreadyInRoom));
					return null;
				}
				const rows = session.current?.intent.directories ?? [];
				const row = rows.find((row) => row.id === destination.directory);
				const current = rows.find((row) => row.id === directory());
				const nick = row?.nick ?? current?.nick ?? JOIN_DEFAULT_NICK;
				await session.openings.run(async (opening) => {
					const room = await session.actions.roomLink(destination.directory, link, name, {
						route: destination.address,
						nick: row?.nickAllocation === "exact"
							? { kind: "exact", name: nick }
							: { kind: "automatic", base: nick },
						home: row?.home ?? false,
					}, opening);
					await opening.select(room);
				});
			} catch (error) {
				return thatLinkDidNotOpen(refusalText(error));
			}
			return null;
		},
		leaveHere: async () => {
			const row = active();
			if (row?.type === "directory") store.dismissDirectoryView(projection, row.key);
			else if (row != null) await session.actions.run("leaveConversation", [row.persistId]);
		},
		directMessage: async (who) => {
			const id = directory();
			if (id == null) return NOT_ON_A_DIRECTORY;
			await session.openings.run(async (opening) => {
				const conversation = await session.actions.direct(id, who, false, undefined, opening);
				await opening.select(conversation);
			}, { kind: "direct", peer: who });
			return null;
		},
		setTheme: browser.setTheme,
		showRoster: browser.showRoster,
		aboutConversation: browser.aboutConversation,
		clearHere: () => {
			const key = projection.get().activeKey;
			if (key != null) store.clearHistory(projection, key);
		},
		ignore: async (name) => {
			await session.actions.run("setIgnoredName", [name, "true"]);
		},
		unignore: async (name) => {
			const held = projection.get().ignored.has(name.toLowerCase());
			await session.actions.run("setIgnoredName", [name, "false"]);
			return held;
		},
		ignored: () => [...projection.get().ignored].sort(),
		editLast: (text) => edit("editLine", text),
		withdrawLast: () => edit("withdrawLine"),
		setSubject: async (description, link) => {
			const row = selected();
			if (row?.kind !== "room" || row.subject == null) return false;
			await session.actions.run(
				"setRoomSubject",
				link === undefined ? [row.id, description] : [row.id, description, link],
			);
			return true;
		},
		setAway: async (text) => {
			const row = selected();
			if (row?.kind !== "room") return false;
			await session.actions.run("setEffectiveStanding", [row.id, text]);
			return true;
		},
		invite: async (who) => {
			const row = selected();
			if (row?.kind !== "room" || row.access == null) return false;
			const direct = await session.actions.direct(row.directory, who, false);
			await session.actions.run("offerRoom", [row.id, direct]);
			return true;
		},
		kick: async (who) => {
			const row = active();
			if (row?.type !== "room") return false;
			const refusal = await rooms.askRoomMemberOut(row.key, who);
			if (refusal) throw new Error(refusal);
			return true;
		},
		steward: async (link) => {
			const row = active();
			if (row?.type !== "room") return false;
			const refusal = await rooms.stewardRoom(row.key, link);
			if (refusal) throw new Error(refusal);
			return true;
		},
		roomLink: async (name) => {
			const row = active();
			if (row?.type !== "room") return false;
			if (name != null && name !== row.id) {
				await pick(row.dir, name);
				return false;
			}
			const refusal = await rooms.createRoomLink(row.key);
			if (refusal) throw new Error(refusal);
			return true;
		},
		you: () => {
			const id = directory();
			return id == null ? "" : store.dirNick(projection, id);
		},
		standingHere: () => {
			const row = active();
			return row?.type === "room" ? store.standingFor(projection, row.key) : "";
		},
		granted: () => {
			const row = active();
			return row?.type === "room" ? row.grants : new Set();
		},
		liveRooms: () => liveRoomCounts(store.actingDir(projection)?.liveRooms ?? new Map()),
		roster: () => {
			const row = active();
			if (row?.type !== "room") return [];
			const reachable = projection.get().dirs.get(row.dir)?.dmablePeers;
			return [...store.membersOf(projection, row.key)].map(([name, standing]) => ({
				name,
				online: standing.online,
				away: standing.away,
				reachable: reachable?.has(name.toLowerCase()) === true,
			}));
		},
		directories: () =>
			[...projection.get().dirs.values()].map((row) => ({
				locator: row.locator,
				name: directoryName(row.id, projection.get().homeDir),
				nick: row.nick,
				standing: store.standingOn(projection, row.id),
				rooms: liveRoomCounts(row.liveRooms),
				joined: [...projection.get().convs.values()].flatMap((conv) =>
					conv.type === "room" && conv.dir === row.id ? [roomCalled(conv.id, conv.held)] : []
				),
				connected: row.session === "connected",
			})),
		quitDirectory: async () => {
			const id = directory();
			if (id == null) return NO_DIRECTORY_TO_GIVE_BACK;
			await session.actions.run("leaveDirectory", [id]);
			return null;
		},
	};
}
