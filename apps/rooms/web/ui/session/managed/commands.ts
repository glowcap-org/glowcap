import { conversationById } from "./conversation_lookup.ts";
import { editLine } from "./edit.ts";
import type { Conv } from "../../conversation.ts";
// Slash commands select exact conversation fields. Command names confer no
// authority and never cause recovery through a stronger entrance.
import { withdrawLine } from "./withdraw.ts";
import * as store from "../../store.ts";
import type { RoomsPageContext } from "../../page.ts";
import type { RoomsBrowserController } from "../../controller/browser.ts";
import type { RoomsRoomController } from "../../controller/session.ts";
import type { ManagedRoomsSession } from "./session.ts";
import type { CommandPowers } from "../../commands.ts";
import { type DirId, liveRoomCounts } from "../../directory.ts";
import { directoryName, roomCalled } from "../../text.ts";
import {
	inviteWithoutTheRoom,
	KICK_WITHOUT_MODERATOR,
	linkNotHeldFor,
	linkRoomNotJoined,
	moderatorLinkLine,
	moderatorLinkTaken,
	NO_DIRECTORY_TO_GIVE_BACK,
	NO_LINE_TO_CHANGE,
	NO_LINE_TO_TAKE_BACK,
	NO_ROOM_TO_HAND_OVER,
	NO_ROOM_TO_LINK,
	NO_ROOM_TO_MODERATE,
	NO_ROOM_TO_SAY_THAT_IN,
	NO_SUBJECT_OFFERED,
	NOT_ON_A_DIRECTORY,
	notRegisteredForDirect,
	roomLinkLine,
} from "../../commands/targets.ts";
import { roomBearer } from "../bearer.ts";
import { linksNotShownHere, roomLinkHandedHint, roomLinkNoneHint } from "../../../../lib/text/room_authority.ts";
import { JOIN_DEFAULT_NICK, roomLinkDestination } from "../../joining.ts";
import { alreadyInRoom } from "../../../../lib/text/attached.ts";
import { thatLinkDidNotOpen } from "../../../../lib/text/commands.ts";
import { refusalText } from "../../../../lib/text/failure.ts";
import { roomsErrorInMessage } from "../../../../lib/error_codes.ts";

/** Run work that opens a direct line to `who`. The directory answers a name
 * nobody registered with its peer-offline code. That is the reader's typo,
 * said where they typed it. Anything else is the line itself failing and
 * stays one. */
async function unlessUnregistered(who: string, work: () => Promise<void>): Promise<string | null> {
	try {
		await work();
	} catch (error) {
		if (roomsErrorInMessage(error)?.code === "peer-offline") return notRegisteredForDirect(who);
		throw error;
	}
	return null;
}
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
		return row == null || row.type === "directory" ? null : conversationById(session.current, row.persistId);
	};
	// A held room was entered by this exact link when its retained access was
	// imported from it or minted as it. Labels and room names prove nothing.
	const enteredBy = (link: string) => session.actions.roomEnteredBy(link);
	const edit = async (verb: "editLine" | "withdrawLine", text?: string) => {
		const row = selected();
		const line = row?.lines?.at(-1);
		if (row == null || line == null) return verb === "editLine" ? NO_LINE_TO_CHANGE : NO_LINE_TO_TAKE_BACK;
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
		return null;
	};
	// The listed room this session is in under `name` on the same directory as
	// `here`, or null. A name a reader types is matched the way the room list
	// shows it, and a private room's id is a label rather than a name.
	const roomNamed = (here: Extract<Conv, { type: "room" }>, name: string) => {
		const wanted = name.toLowerCase();
		return store.listedRoomsOn(projection.get().convs, here.dir).find((row) => row.id.toLowerCase() === wanted) ??
			null;
	};
	const powers: CommandPowers = {
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
		directMessage: (who) => {
			const id = directory();
			if (id == null) return Promise.resolve(NOT_ON_A_DIRECTORY);
			return unlessUnregistered(who, () =>
				session.openings.run(async (opening) => {
					const conversation = await session.actions.direct(id, who, false, undefined, opening);
					await opening.select(conversation);
				}, { kind: "direct", peer: who }));
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
			if (row?.kind !== "room" || row.subject == null) return NO_SUBJECT_OFFERED;
			await session.actions.run(
				"setRoomSubject",
				link === undefined ? [row.id, description] : [row.id, description, link],
			);
			return null;
		},
		setAway: async (text) => {
			const row = selected();
			if (row?.kind !== "room") return NO_ROOM_TO_SAY_THAT_IN;
			await session.actions.run("setEffectiveStanding", [row.id, text]);
			return null;
		},
		invite: (who) => {
			const live = active();
			const row = selected();
			if (live?.type !== "room" || row?.kind !== "room") return Promise.resolve(NO_ROOM_TO_HAND_OVER);
			// A seat in the room is not the room. Joining a listed room by name
			// seats the member; the room itself is held by whoever made it or
			// was handed it, and only that reference can cross to somebody.
			if (row.access == null) {
				return Promise.resolve(inviteWithoutTheRoom(live.id, live.policy.visibility === "listed"));
			}
			return unlessUnregistered(who, async () => {
				const direct = await session.actions.direct(row.directory, who, false);
				await session.actions.run("offerRoom", [row.id, direct]);
			});
		},
		kick: async (who) => {
			const row = active();
			if (row?.type !== "room") return NO_ROOM_TO_MODERATE;
			// The catalog hides /kick from a member the room handed no steward
			// capability, but typing it still reaches here. Possession is the
			// permission, so a session without it is told that, not refused by
			// the room in words meant for a moderator.
			if (!row.grants.has("steward")) return KICK_WITHOUT_MODERATOR;
			const refusal = await rooms.askRoomMemberOut(row.key, who);
			return refusal === "" ? null : refusal;
		},
		steward: async (link) => {
			const row = active();
			if (row?.type !== "room") return NO_ROOM_TO_MODERATE;
			const refusal = await rooms.stewardRoom(row.key, link);
			if (refusal !== "") return refusal;
			const held = await roomBearer(session, row, "steward");
			powers.say(held == null ? moderatorLinkTaken(row.id) : moderatorLinkLine(row.id, held), row.key);
			return null;
		},
		roomLink: async (name) => {
			const here = active();
			if (here?.type !== "room") return NO_ROOM_TO_LINK;
			const target = name == null || name.toLowerCase() === here.id.toLowerCase() ? here : roomNamed(here, name);
			if (target == null) return linkRoomNotJoined(name ?? here.id);
			if (!session.permits("shareCustody")) return linksNotShownHere;
			// A room handed over by /invite is held as a live reference with no
			// link text behind it, so the question is whether a link can be read,
			// not whether the row holds access. Minting is the room manager's, and
			// only for the room it is typed in. Anyone else holds a seat, or the
			// handed room, and the card says the same.
			let link = await roomBearer(session, target, "link");
			if (link == null) {
				if (target !== here) return linkNotHeldFor(target.id);
				if (target.managerToken == null) {
					return target.linkToken == null ? roomLinkNoneHint : roomLinkHandedHint;
				}
				const refusal = await rooms.createRoomLink(target.key);
				if (refusal !== "") return refusal;
				link = await roomBearer(session, target, "link");
				if (link == null) return roomLinkNoneHint;
			}
			powers.say(roomLinkLine(target.id, link), here.key);
			return null;
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
			// A direct line has one person on the other end. Whether the line is
			// live is what this window knows of them.
			if (row?.type === "dm") return [{ name: row.id, online: row.line === "live", away: "", reachable: true }];
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
				address: row.address,
				name: directoryName(row.id, projection.get().homeDirectory),
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
	return powers;
}
