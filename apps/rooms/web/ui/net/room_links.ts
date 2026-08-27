// Durable room links on an already-open directory session.

import { type Ref } from "@pancake/runtime";
import { roomCalledAs } from "../../../lib/room_client.ts";
import { joinedForLink } from "../joining.ts";
import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { reason, trouble } from "./common.ts";
import { convSession, directoryLocators, dirSession, isCurrent, type Live } from "./live.ts";
import { linkDirectory } from "./bootstrap.ts";
import { enterRoom } from "./rooms.ts";
import { roomsSturdyrefForSession } from "../../../lib/locator.ts";

/** Create or recover one room's durable link, keeping operational failure as
 * the answer to the control that asked instead of turning it into a transient
 * conversation line. */
export async function createRoomLink(key: string): Promise<string> {
	const session = convSession(key);
	if (session === null || !session.rooms.has(key)) {
		return "This room membership is not connected right now.";
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
	const room = session.rooms.get(key);
	if (room === undefined) throw new Error("this tab is not in that room");
	const minted = await room.link();
	const linked = linkDirectory(minted);
	if (linked === null) throw new Error("the room Host answered with an invalid sturdyref");
	store.noteRoomLink(key, minted);
	directoryLocators.set(session.id, linked.address);
	store.patchDir(session.id, { locator: linked.address });
	return minted;
}

/** Redeem a reader-supplied link on the directory session its locator selected. */
export function redeemRoomLink(dir: DirId, link: string, label: string, nick: string): Promise<string> {
	return redeemOn(dir, link, label, nick);
}

/** Re-enter one retained private-room conversation on the new session for its
 * directory. The sturdyref is the authority and the existing key is the page's
 * conversation identity; unlike a reader's paste, reconnect must not mint a
 * second row or switch what they are reading. */
export function reenterRoomLink(
	dir: DirId,
	key: string,
	link: string,
	label: string,
	nick: string,
): Promise<string> {
	return redeemOn(dir, link, label, nick, key);
}

/** Bring the link to life on the directory it names, and enter the room.
 *
 * The two failures stay apart. A directory that will not answer the link does
 * not know that durable authority. A room that refuses `subscribe` is a live
 * room saying no, which is a different and often actionable answer. */
async function redeemOn(
	dir: DirId,
	link: string,
	label: string,
	nick: string,
	reentryKey?: string,
): Promise<string> {
	const session = dirSession(dir);
	if (session === null) return "not connected to the room directory yet";
	let room: Ref;
	try {
		room = await session.dir.session.enliven(roomsSturdyrefForSession(link, session.dir.session));
	} catch (err) {
		if (!isCurrent(session)) return "the connection to that directory ended before the link was answered";
		return `that directory has no room by that link: ${reason(err)}`;
	}
	if (!isCurrent(session)) {
		releaseUnseated(session, room);
		return "";
	}
	const already = (key: string): "" => {
		session.dir.session.release(room);
		store.noteRoomLink(key, link);
		if (reentryKey == null) store.switchTo(key);
		store.deliver(key, store.sysItem("You are already in this room."));
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
	const here = joinedForLink(store.joinedRooms(dir), new Set(session.rooms.keys()), link, null);
	if (here !== null) return already(here);
	return await enterRoom(
		dir,
		name,
		store.dirNick(dir) || nick,
		reentryKey == null ? { room, link, select: true } : { held: { key: reentryKey, room }, link, reentry: true },
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
		trouble("an unseated room-link reference could not be released", error);
	}
}
