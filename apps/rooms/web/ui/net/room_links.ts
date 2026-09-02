// Durable room links on an already-open directory session.

import * as store from "../store.ts";
import { PublicationNotFound, type Ref } from "@glowcap/runtime";
import { roomCalledAs } from "../../../lib/room/client.ts";
import { roomAuthorityToken } from "../../../lib/room/authority.ts";
import { joinedForLink, roomLinkDestination } from "../joining.ts";
import type { DirId } from "../types.ts";
import { MEMBERSHIP_NOT_CONNECTED, reason, trouble } from "./common.ts";
import { convSession, dirSession, isCurrent, type Live } from "./live.ts";
import { enterRoom } from "./rooms.ts";
import type { RoomsPageContext } from "../page.ts";

/** Create or recover one room's durable link, keeping operational failure as
 * the answer to the control that asked instead of turning it into a transient
 * conversation line. */
export async function createRoomLink(page: RoomsPageContext, key: string): Promise<string> {
	const session = convSession(page, key);
	if (session === null || !session.rooms.has(key)) {
		return MEMBERSHIP_NOT_CONNECTED;
	}
	try {
		await mintRoomLink(session, key);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Mint a complete durable authority for one room this tab is in. */
export async function mintRoomLink(session: Live, key: string): Promise<string> {
	const page = session.page;
	const room = session.rooms.get(key);
	if (room === undefined) throw new Error("this tab is not in that room");
	const minted = await room.link();
	const linked = roomLinkDestination(minted, "");
	if (linked === null) throw new Error("the room Host answered with an invalid sturdyref");
	store.noteRoomLink(page.projection, key, minted);
	session.page.live.directoryLocators.set(session.id, linked.address);
	store.patchDir(page.projection, session.id, { locator: linked.address });
	return minted;
}

/** Redeem a reader-supplied link on the directory session its locator selected. */
export function redeemRoomLink(
	page: RoomsPageContext,
	dir: DirId,
	link: string,
	label: string,
	nick: string,
): Promise<string> {
	return redeemOn(page, dir, link, label, nick);
}

/** Re-enter one retained private-room conversation on the new session for its
 * directory. The sturdyref is the authority and the existing key is the page's
 * conversation identity; unlike a reader's paste, reconnect must not mint a
 * second row or switch what they are reading. */
export function reenterRoomLink(
	page: RoomsPageContext,
	dir: DirId,
	key: string,
	link: string,
	label: string,
	nick: string,
): Promise<string> {
	return redeemOn(page, dir, link, label, nick, key);
}

/** Bring the link to life on the directory it names, and enter the room.
 *
 * The two failures stay apart. A directory that will not answer the link does
 * not know that durable authority. A room that refuses `subscribe` is a live
 * room saying no, which is a different and often actionable answer. */
async function redeemOn(
	page: RoomsPageContext,
	dir: DirId,
	link: string,
	label: string,
	nick: string,
	reentryKey?: string,
): Promise<string> {
	const projection = page.projection;
	const session = dirSession(page, dir);
	if (session === null) return "not connected to the room directory yet";
	let room: Ref;
	try {
		room = await session.dir.session.enliven(link);
	} catch (err) {
		if (!isCurrent(session)) return "the connection to that directory ended before the link was answered";
		if (err instanceof PublicationNotFound && reentryKey != null) {
			const retained = store.getConv(projection, reentryKey);
			if (retained?.type === "room" && retained.link === link) {
				store.clearRoomAuthority(projection, reentryKey, {
					kind: "room",
					token: roomAuthorityToken(link),
					claimable: false,
				});
				store.setRoomMembership(projection, reentryKey, "unavailable");
				return retained.held
					? "that room entry link was retired. Somebody in the room must share a current link"
					: "that room entry link was retired. Open the room controls and restore access by name";
			}
		}
		return `that directory has no room by that link: ${reason(err)}`;
	}
	if (!isCurrent(session)) {
		releaseUnseated(session, room);
		return "";
	}
	const already = (key: string): "" => {
		session.dir.session.release(room);
		store.noteRoomLink(projection, key, link);
		if (reentryKey == null) store.switchTo(projection, key);
		store.deliver(projection, key, store.sysItem(projection, "You are already in this room."));
		return "";
	};
	for (const [key, held] of session.rooms) {
		if (held.reference.equals(room)) return already(key);
	}
	let name = "";
	try {
		name = await roomCalledAs(session.dir.session, room);
	} catch {
		// A room with no convenience name still remains fully reachable by the
		// authority that produced `room`.
	}
	if (name === "") name = label;
	if (!isCurrent(session)) {
		releaseUnseated(session, room);
		return "";
	}
	const here = joinedForLink(store.joinedRooms(projection, dir), new Set(session.rooms.keys()), link, null);
	if (here !== null) return already(here);
	const reentryConv = reentryKey == null ? null : store.getConv(projection, reentryKey);
	return await enterRoom(
		page,
		dir,
		name,
		store.dirNick(projection, dir) || nick,
		reentryKey == null ? { room, link, select: true } : {
			held: { key: reentryKey, room },
			link,
			manager: reentryConv?.type === "room" ? reentryConv.manager : undefined,
			reentry: true,
		},
	);
}

/** Give back a link occurrence whose directory session was replaced while an
 * informational ask was settling. The Host may already be retiring that
 * session, so a failed release is diagnostic rather than a second operation
 * result nobody is still waiting for. */
function releaseUnseated(session: Live, room: Ref): void {
	try {
		session.dir.session.release(room);
	} catch (error) {
		trouble(session.page.projection, "an unseated room-link reference could not be released", error);
	}
}
