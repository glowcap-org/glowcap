// What a slash command may reach on a live local session.
//
// One table, named a verb at a time, rather than handing commands the net
// barrel. A command that wants something not here is a decision somebody makes
// on purpose — the same argument this app makes about authority everywhere else,
// turned on its own vocabulary.

import * as store from "../store.ts";
import { type CommandPowers } from "../commands.ts";
import {
	DIRECT_NOT_SELF,
	NO_DIRECTORY_TO_GIVE_BACK,
	NOT_A_ROOM_ENTRY_LINK,
	NOT_ON_A_DIRECTORY,
	notRegisteredForDirect,
	thatLinkDidNotOpen,
} from "../commands/targets.ts";
import { roomLinkDestination } from "../joining.ts";
import type { RoomsPageContext } from "../page.ts";
import { directoryName, roomCalled } from "../text.ts";
import { type DirId, liveRoomCounts } from "../types.ts";
import { reason } from "./common.ts";
import { leaveDirectory } from "./connection.ts";
import { openDm, startDm } from "./direct.ts";
import { takeRoomLink } from "./invites.ts";
import { convSession, dirAddress, dirSession } from "./live.ts";
import { mintRoomLink } from "./room_links.ts";
import { endConversation, pickRoom } from "./rooms.ts";
import { editLine, lastLineOfOurs, withdraw } from "./send.ts";
import { setDirStanding, setRoomStanding, setStanding } from "./standing.ts";
import { askMemberOut, steward } from "./stewardship.ts";

const NO_GRANTS: ReadonlySet<string> = new Set();

export function commandPowers(page: RoomsPageContext): CommandPowers {
	const projection = page.projection;
	return {
		say(text) {
			store.deliverActive(projection, store.sysItem(projection, text));
		},
		joinRoom(name) {
			const conv = store.activeConv(projection);
			const dir = conv?.dir ?? store.actingDir(projection)?.id ?? null;
			if (dir === null) return NOT_ON_A_DIRECTORY;
			pickRoom(page, dir, name);
			return null;
		},
		leaveHere() {
			endConversation(page);
		},
		directMessage(who) {
			const conv = store.activeConv(projection);
			const dir = conv?.dir ?? store.actingDir(projection)?.id ?? null;
			if (dir === null) return NOT_ON_A_DIRECTORY;
			if (store.isSelf(projection, dir, who)) return DIRECT_NOT_SELF;
			if (store.peerRegistration(projection, dir, who) == null) return notRegisteredForDirect(who);
			startDm(page, who);
			return null;
		},
		you() {
			const conv = store.activeConv(projection);
			const dir = conv?.dir ?? store.actingDir(projection)?.id ?? null;
			return dir === null ? "" : store.dirNick(projection, dir);
		},
		setTheme(theme) {
			store.setTheme(projection, theme);
		},
		showRoster(shown) {
			store.showRoster(projection, shown);
		},
		clearHere() {
			const key = projection.get().activeKey;
			if (key !== null) store.clearHistory(projection, key);
		},
		ignore(name) {
			store.ignore(projection, name);
		},
		unignore(name) {
			return store.unignore(projection, name);
		},
		ignored() {
			return [...projection.get().ignored].sort();
		},
		editLast(text) {
			const key = projection.get().activeKey;
			const last = key === null ? null : lastLineOfOurs(page, key);
			if (key === null || last === null) return false;
			editLine(page, key, last.id, text);
			return true;
		},
		withdrawLast() {
			const key = projection.get().activeKey;
			const last = key === null ? null : lastLineOfOurs(page, key);
			if (key === null || last === null) return false;
			withdraw(page, key, last.id);
			return true;
		},
		setTopic(text) {
			const conv = store.activeConv(projection);
			const room = conv === null ? undefined : convSession(page, conv.key)?.rooms.get(conv.key);
			if (conv?.type !== "room" || room === undefined || !room.canSetTopic) return false;
			// The room answers everybody with the change, this tab included, so there
			// is nothing to apply here: what is on screen comes back off the wire.
			room.setTopic(text).catch((error) => {
				store.deliverActive(
					projection,
					store.sysItem(projection, `Could not set the topic: ${reason(error)}`),
				);
			});
			return true;
		},
		kick(who) {
			const conv = store.activeConv(projection);
			return conv?.type === "room" ? askMemberOut(page, conv.key, who) : false;
		},
		steward(link) {
			const conv = store.activeConv(projection);
			return conv?.type === "room" ? steward(page, conv.key, link) : false;
		},
		setAway(why) {
			const conv = store.activeConv(projection);
			if (conv?.type !== "room") return false;
			// Written where this reader's standing already comes from, rather than
			// always at one level. Nobody who has never touched the other two is given
			// a room-shaped answer to a question they asked in words that mean
			// everywhere, and nobody who *has* set a room or a directory apart finds
			// `/away` quietly overruling it from outside.
			if (conv.standing !== null) setRoomStanding(page, conv.key, why);
			else if (projection.get().dirs.get(conv.dir)?.standing != null) setDirStanding(page, conv.dir, why);
			else setStanding(page, why);
			return true;
		},
		joinLink(link, label) {
			// No directory is named here, and that is the point: a link carries its
			// own, so taking one up does not depend on where the reader happens to be
			// standing. What this side supplies is the name they would like to be
			// called, from the directory they are reading if it has granted them one.
			const dir = store.activeConv(projection)?.dir ?? store.actingDir(projection)?.id ?? null;
			const nick = (dir === null ? "" : store.dirNick(projection, dir)) ||
				store.reachingNick(projection);
			let destination: ReturnType<typeof roomLinkDestination>;
			try {
				destination = roomLinkDestination(link, label);
			} catch (error) {
				return thatLinkDidNotOpen(reason(error));
			}
			if (destination === null) return NOT_A_ROOM_ENTRY_LINK;
			void takeRoomLink(page, destination, nick).then((why) => {
				if (why !== "") {
					store.deliverActive(
						projection,
						store.sysItem(projection, thatLinkDidNotOpen(why)),
					);
				}
			}, (error) => {
				store.deliverActive(
					projection,
					store.sysItem(projection, thatLinkDidNotOpen(reason(error))),
				);
			});
			return null;
		},
		invite(nick) {
			const conv = store.activeConv(projection);
			const session = conv === null ? null : convSession(page, conv.key);
			const room = conv === null ? undefined : session?.rooms.get(conv.key);
			if (conv?.type !== "room" || session === null || room === undefined) return false;
			if (store.isSelf(projection, session.id, nick)) return false;
			// The room itself, handed over the direct line to them: the reference is
			// the invitation, carried across as a handoff, with nothing asked of the
			// room or the directory about who may be offered it and nothing durable
			// minted anywhere — which a link is not free of. They may take it up,
			// store.ignore it, or pass it on.
			// Offering a room means opening a line to carry it, which puts a direct
			// conversation on screen. Say why it appeared, in the line itself — a
			// bare DM opening beside the room with no reason reads as the app doing
			// something unbidden. Only on a line that did not already exist: a
			// standing conversation should not gain a system line every invite.
			const label = conv.id;
			const registration = store.peerRegistration(projection, session.id, nick);
			if (registration == null) return false;
			const existed =
				store.liveDmWith(projection, session.id, registration.name, registration.registrationId) != null;
			const line = store.ensureDm(projection, session.id, registration.name, registration.registrationId);
			if (line === null) return false;
			const conversation = store.getConv(projection, line.key);
			if (conversation?.type !== "dm") return false;
			if (!existed) {
				store.deliver(
					projection,
					line.key,
					store.sysItem(
						projection,
						`This opened so you could offer ${nick} ${label ? roomCalled(label, conv.held) : "a room"}. ` +
							`It is now a direct line to them like any other.`,
					),
				);
			}
			void openDm(page, conversation)
				.then((dm) => dm.handRoom(label, room.reference))
				.then(() =>
					store.deliver(
						projection,
						conv.key,
						store.sysItem(projection, `${nick} has been offered this room.`),
					)
				)
				.catch((error) =>
					store.deliver(
						projection,
						conv.key,
						store.sysItem(
							projection,
							`Could not offer this room to ${nick}: ${reason(error)}. ` +
								`/link makes an offer that travels as text instead`,
						),
					)
				);
			return true;
		},
		roomLink(name) {
			const asked = name?.trim().replace(/^#/, "") ?? "";
			if (asked !== "") {
				const conv = store.activeConv(projection);
				const dir = conv?.dir ?? store.actingDir(projection)?.id ?? null;
				const session = dir === null ? null : dirSession(page, dir);
				if (session === null) return false;
				void session.dir.link(asked)
					.then((link) => {
						const target = store.joinedRooms(projection, session.id).find((row) =>
							!row.held && row.id.toLowerCase() === asked.toLowerCase()
						);
						if (target !== undefined) store.noteRoomLink(projection, target.key, link);
						store.deliverActive(
							projection,
							store.sysItem(
								projection,
								`Anybody who holds this link can be in ${roomCalled(asked, false)}:\n  ${link}`,
							),
						);
					})
					.catch((error) =>
						store.deliverActive(
							projection,
							store.sysItem(
								projection,
								`Could not link ${roomCalled(asked, false)}: ${reason(error)}`,
							),
						)
					);
				return true;
			}
			const conv = store.activeConv(projection);
			const session = conv === null ? null : convSession(page, conv.key);
			if (conv?.type !== "room" || session === null) return false;
			void mintRoomLink(session, conv.key)
				.then((link) =>
					store.deliver(
						projection,
						conv.key,
						store.sysItem(
							projection,
							`Anybody who holds this link can be in ${roomCalled(conv.id, conv.held)}:\n  ${link}`,
						),
					)
				)
				.catch((error) =>
					store.deliver(
						projection,
						conv.key,
						store.sysItem(projection, `Could not link this room: ${reason(error)}`),
					)
				);
			return true;
		},
		standingHere() {
			const conv = store.activeConv(projection);
			return conv?.type === "room" ? store.standingFor(projection, conv.key) : "";
		},
		granted() {
			const conv = store.activeConv(projection);
			return conv?.type === "room" ? conv.grants : NO_GRANTS;
		},
		liveRooms() {
			return liveRoomCounts(store.actingDir(projection)?.liveRooms ?? new Map());
		},
		roster() {
			const conv = store.activeConv(projection);
			if (conv?.type !== "room") return [];
			const reachable = store.actingDir(projection)?.dmablePeers ?? new Set<string>();
			return [...store.membersOf(projection, conv.key)].map(([name, standing]) => ({
				name,
				online: standing.online,
				away: standing.away,
				reachable: reachable.has(name.toLowerCase()),
			}));
		},
		directories() {
			const state = projection.get();
			const rooms = (dir: DirId) =>
				[...state.convs.values()].flatMap((conv) =>
					conv.type === "room" && conv.dir === dir ? [roomCalled(conv.id, conv.held)] : []
				);
			return [...state.dirs.values()].map((dir) => ({
				// The route, not the authority the map is keyed by: routing hints are
				// part of what makes an address dialable, and an address a reader
				// cannot dial is not the answer they asked for.
				locator: dirAddress(page, dir.id),
				name: directoryName(dir.id, state.homeDir),
				nick: dir.nick,
				standing: store.standingOn(projection, dir.id, state),
				rooms: liveRoomCounts(dir.liveRooms),
				joined: rooms(dir.id),
				connected: dir.session === "connected",
			}));
		},
		quitDirectory() {
			const dir = store.activeConv(projection)?.dir ?? store.actingDir(projection)?.id ?? null;
			if (dir === null) return NO_DIRECTORY_TO_GIVE_BACK;
			leaveDirectory(page, dir);
			return null;
		},
		aboutConversation() {
			const conv = store.activeConv(projection);
			if (conv?.type === "directory") {
				store.showAboutDir(projection, conv.dir);
				return;
			}
			store.showAboutConv(projection);
		},
	};
}
