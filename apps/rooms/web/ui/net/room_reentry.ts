// The room authority a replacement directory session can take back up.

import * as store from "../store.ts";
import { named } from "../intent.ts";
import { roomLinkDestination } from "../joining.ts";
import { roomReentry } from "../types.ts";
import type { Live } from "./live.ts";
import { reenterRoomLink } from "./room_links.ts";
import { enterRoom, gateJoin } from "./rooms.ts";
import type { RoomsPageContext } from "../page.ts";

const REENTRY_CONCURRENCY = 4;

/** Re-enter every recoverable room in its original order. True means at least
 * one re-entry was started, so a staged first join must wait for another
 * session instead of competing with the rooms this page already holds. */
export function reenterRooms(page: RoomsPageContext, id: Live["id"]): boolean {
	const projection = page.projection;
	const planned = store.joinedRooms(projection, id).map((conv) => ({ conv, reentry: roomReentry(conv) }));
	// Reconstruction identity is the name this directory was asked to grant, not
	// the join card's default. Using that default walked a nameless copy of a
	// shared session into every room as "guest".
	const nick = store.requestedDirNick(projection, id);
	const recoverable: typeof planned = [];
	for (const item of planned) {
		const { conv, reentry } = item;
		if (reentry.kind === "lost") {
			store.setRoomMembership(projection, conv.key, "unavailable");
			store.deliver(
				projection,
				conv.key,
				store.sysItem(
					projection,
					"This room was reached by a one-session invitation, and that reference went with the connection. " +
						"Somebody in it can hand it over again, or share a durable room entry link.",
				),
			);
			continue;
		}
		if (conv.reconnect === "manual" || nick === "") {
			store.setRoomMembership(projection, conv.key, "unavailable");
			continue;
		}
		store.setRoomMembership(projection, conv.key, "joining");
		recoverable.push(item);
	}
	if (recoverable.length === 0) return false;
	store.setDirStatus(
		projection,
		id,
		recoverable.length === 1
			? "rejoining " + recoverable[0].conv.id + "…"
			: "rejoining " + recoverable.length + " rooms…",
	);
	let next = 0;
	const worker = async () => {
		while (next < recoverable.length) {
			const { conv, reentry } = recoverable[next];
			next += 1;
			if (reentry.kind === "name") {
				await enterRoom(page, conv.dir, reentry.name, nick, {
					publicationId: reentry.publicationId,
					manager: conv.manager,
					reentry: true,
				});
				continue;
			}
			if (reentry.kind !== "link") continue;
			const why = await reenterRoomLink(page, id, reentry.key, reentry.link, reentry.label, nick);
			if (why !== "") {
				store.deliver(
					projection,
					reentry.key,
					store.sysItem(projection, `Could not re-enter this room: ${why}`),
				);
			}
		}
	};
	void Promise.all(Array.from({ length: Math.min(REENTRY_CONCURRENCY, recoverable.length) }, worker));
	return true;
}

/** Explicitly retry one selected room without coupling the act to rail
 * navigation. A replacement link is the only recovery for a private/lost
 * authority; a public room can be re-entered by its directory name. */
export async function retryRoom(page: RoomsPageContext, key: string, replacementLink?: string): Promise<string> {
	const projection = page.projection;
	const conv = store.getConv(projection, key);
	if (conv?.type !== "room") return "That room is no longer in this workspace.";
	const nick = store.requestedDirNick(projection, conv.dir) || store.dirNick(projection, conv.dir);
	if (nick === "") {
		const supplied = replacementLink?.trim() ?? "";
		if (conv.held) {
			const link = supplied !== "" ? supplied : conv.link;
			if (link == null || link === "") return "This private room needs a current room entry link.";
			gateJoin(page, conv.dir, conv.id, "press", named(link));
			return "";
		}
		gateJoin(page, conv.dir, conv.id, "press");
		return "";
	}
	store.setRoomMembership(projection, key, "joining");
	const supplied = replacementLink?.trim() ?? "";
	let why: string;
	if (supplied !== "") why = await reenterRoomLink(page, conv.dir, key, supplied, conv.id, nick);
	else {
		const reentry = roomReentry(conv);
		if (reentry.kind === "name") {
			why = await enterRoom(page, conv.dir, reentry.name, nick, {
				publicationId: reentry.publicationId,
				manager: conv.manager,
				reentry: true,
			});
		} else if (reentry.kind === "link") {
			why = await reenterRoomLink(page, conv.dir, reentry.key, reentry.link, reentry.label, nick);
		} else why = "This private room needs a current room entry link.";
	}
	if (why !== "") store.setRoomMembership(projection, key, "unavailable");
	return why;
}

/** The best route this page already has authority to use for a reconnect. A
 * durable room link outranks the concrete address that carried the old session
 * because its host-authored route can survive listener changes. The directory
 * id remains the page's filing identity. */
export function roomReconnectLocator(which: Live): string | null {
	for (const conv of store.joinedRooms(which.page.projection, which.id)) {
		if (conv.link === undefined) continue;
		const linked = roomLinkDestination(conv.link, conv.id);
		if (linked !== null) return linked.address;
	}
	return which.home ? null : which.locator;
}
