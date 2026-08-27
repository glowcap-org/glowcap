// Room invitations received over direct connections.

import { Ref, type Session } from "@pancake/runtime";
import { MAX_PENDING_INVITES } from "../../../lib/limits.ts";
import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { linkDirectory } from "./bootstrap.ts";
import { releaseIncomingRef } from "./direct_custody.ts";
import { isCurrent, type Live } from "./live.ts";

let invitationSequence = 0;

export interface PendingHandedRoom {
	room: Ref;
	release(what: string): void;
}

const handedRooms = new Map<string, PendingHandedRoom>();

export function takeHandedRoom(id: string): PendingHandedRoom | null {
	const room = handedRooms.get(id) ?? null;
	handedRooms.delete(id);
	return room;
}

function announceOffer(from: string, label: string): void {
	store.deliverActive(store.sysItem(`${from} offered you ${label || "a room"}. It is in your rooms list.`));
}

/** Retain a handed room occurrence until exactly one accept or decline. */
export function handedRoom(home: Live, owner: Session, label: string, room: Ref, from: string): boolean {
	if (!isCurrent(home) || store.get().invites.length >= MAX_PENDING_INVITES) {
		if (isCurrent(home)) {
			store.deliverActive(
				store.sysItem(
					`${from} offered you ${label || "a room"}, but the offers list is full. ` +
						`Take up or decline some in the rooms list first, then ask again.`,
				),
			);
		}
		releaseIncomingRef(owner, room, "refused handed room");
		return false;
	}
	invitationSequence += 1;
	const id = "invite:" + invitationSequence;
	handedRooms.set(id, {
		room,
		release: (what) => releaseIncomingRef(owner, room, what),
	});
	store.addInvite({ id, dir: home.id, way: "handed", label, from, link: "" });
	announceOffer(from, label);
	return true;
}

export function releaseHandedRoomsForDirectory(dir: DirId): void {
	for (const invite of store.get().invites) {
		if (invite.dir !== dir) continue;
		const handed = takeHandedRoom(invite.id);
		if (handed == null) continue;
		handed.release("abandoned handed room");
		store.dropInvite(invite.id);
	}
}

/** Retain a durable room-link invitation independently of its connection. */
export function offeredRoom(home: Live, label: string, link: string, from: string): boolean {
	if (!isCurrent(home)) return false;
	const target = linkDirectory(link);
	if (target == null) {
		store.deliverActive(store.sysItem(`${from} offered a room with an invalid link.`));
		return false;
	}
	if (store.get().invites.length >= MAX_PENDING_INVITES) {
		store.deliverActive(
			store.sysItem(
				`${from} offered you ${label || "a room"}, but the offers list is full. ` +
					`Take up or decline some in the rooms list first, then ask again.`,
			),
		);
		return false;
	}
	invitationSequence += 1;
	store.addInvite({
		id: "invite:" + invitationSequence,
		dir: target.id,
		locator: target.address,
		nick: store.dirNick(home.id) || store.reachingNick(),
		way: "link",
		label,
		from,
		link,
	});
	announceOffer(from, label);
	return true;
}
