// The room authority a replacement directory session can take back up.

import * as store from "../store.ts";
import { roomReentry } from "../types.ts";
import { linkDirectory } from "./bootstrap.ts";
import type { Live } from "./live.ts";
import { reenterRoomLink } from "./room_links.ts";
import { enterRoom } from "./rooms.ts";

const REENTRY_CONCURRENCY = 4;

/** Re-enter every recoverable room in its original order. True means at least
 * one re-entry was started, so a staged first join must wait for another
 * session instead of competing with the rooms this page already holds. */
export function reenterRooms(id: Live["id"]): boolean {
	const planned = store.joinedRooms(id).map((conv) => ({ conv, reentry: roomReentry(conv) }));
	for (const { conv, reentry } of planned) {
		store.setRoomMembership(conv.key, "joining");
		if (reentry.kind !== "lost") continue;
		store.setRoomMembership(conv.key, "unavailable");
		store.deliver(
			conv.key,
			store.sysItem(
				"This room was reached by a one-session invitation, and that reference went with the connection. " +
					"Somebody in it can hand it over again, or share a durable room link.",
			),
		);
	}
	const recoverable = planned.filter(({ reentry }) => reentry.kind !== "lost");
	const nick = store.requestedDirNick(id) || store.reachingNick();
	if (recoverable.length === 0) return false;
	if (!nick) {
		for (const { conv } of recoverable) store.setRoomMembership(conv.key, "unavailable");
		return false;
	}
	store.setDirStatus(
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
				await enterRoom(conv.dir, reentry.name, nick, { publicationId: reentry.publicationId, reentry: true });
				continue;
			}
			if (reentry.kind !== "link") continue;
			const why = await reenterRoomLink(id, reentry.key, reentry.link, reentry.label, nick);
			if (why !== "") {
				store.deliver(reentry.key, store.sysItem(`Could not re-enter this private room: ${why}`));
			}
		}
	};
	void Promise.all(Array.from({ length: Math.min(REENTRY_CONCURRENCY, recoverable.length) }, worker));
	return true;
}

/** The best route this page already has authority to use for a reconnect. A
 * durable room link outranks the concrete address that carried the old session
 * because its host-authored route can survive listener changes. The directory
 * id remains the page's filing identity. */
export function roomReconnectLocator(which: Live): string | null {
	for (const conv of store.joinedRooms(which.id)) {
		if (conv.link === undefined) continue;
		const linked = linkDirectory(conv.link);
		if (linked !== null) return linked.address;
	}
	return which.home ? null : which.locator;
}
