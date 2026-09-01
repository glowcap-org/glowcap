// Room invitations received over direct connections.

import * as store from "../store.ts";
import { Ref, type Session } from "@pancake/runtime";
import { MAX_PENDING_INVITES } from "../../../lib/limits.ts";
import { roomLinkDestination } from "../joining.ts";
import type { DirId } from "../types.ts";
import { releaseIncomingRef } from "./direct_custody.ts";
import { isCurrent, type Live } from "./live.ts";
import type { RoomsPageContext } from "../page.ts";

/** Pending handed-room occurrences until exactly one accept or decline. */
export class PageDirectOffers {
	invitationSequence = 0;
	readonly handedRooms = new Map<string, PendingHandedRoom>();
}

export interface PendingHandedRoom {
	room: Ref;
	release(what: string): void;
}

export function takeHandedRoom(page: RoomsPageContext, id: string): PendingHandedRoom | null {
	const room = page.offers.handedRooms.get(id) ?? null;
	page.offers.handedRooms.delete(id);
	return room;
}

function announceOffer(page: RoomsPageContext, from: string, label: string): void {
	store.deliverActive(
		page.projection,
		store.sysItem(page.projection, `${from} offered you ${label || "a room"}. It is in your rooms list.`),
	);
}

/** Retain a handed room occurrence until exactly one accept or decline. */
export function handedRoom(home: Live, owner: Session, label: string, room: Ref, from: string): boolean {
	const page = home.page;
	if (!isCurrent(home) || page.projection.get().invites.length >= MAX_PENDING_INVITES) {
		if (isCurrent(home)) {
			store.deliverActive(
				page.projection,
				store.sysItem(
					page.projection,
					`${from} offered you ${label || "a room"}, but the offers list is full. ` +
						`Take up or decline some in the rooms list first, then ask again.`,
				),
			);
		}
		releaseIncomingRef(page.projection, owner, room, "refused handed room");
		return false;
	}
	home.page.offers.invitationSequence += 1;
	const id = "invite:" + home.page.offers.invitationSequence;
	let stopClose = () => {};
	let released = false;
	const pending: PendingHandedRoom = {
		room,
		release: (what) => {
			if (released) return;
			released = true;
			stopClose();
			releaseIncomingRef(page.projection, owner, room, what);
		},
	};
	stopClose = owner.onClose(() => {
		// Closing the carrying session retires every imported occurrence itself.
		// Remove the pending UI row at the same boundary rather than offering a
		// reference its owner can no longer exercise.
		released = true;
		if (home.page.offers.handedRooms.get(id) === pending) home.page.offers.handedRooms.delete(id);
		store.dropInvite(page.projection, id);
	});
	home.page.offers.handedRooms.set(id, pending);
	store.addInvite(page.projection, { id, dir: home.id, way: "handed", label, from, link: "" });
	announceOffer(page, from, label);
	return true;
}

export function releaseHandedRoomsForDirectory(page: RoomsPageContext, dir: DirId): void {
	for (const invite of page.projection.get().invites) {
		if (invite.dir !== dir) continue;
		const handed = takeHandedRoom(page, invite.id);
		if (handed == null) continue;
		handed.release("abandoned handed room");
		store.dropInvite(page.projection, invite.id);
	}
}

/** Retain a durable room-link invitation independently of its connection. */
export function offeredRoom(home: Live, label: string, link: string, from: string): boolean {
	const page = home.page;
	if (!isCurrent(home)) return false;
	const target = roomLinkDestination(link, label);
	if (target == null) {
		store.deliverActive(
			page.projection,
			store.sysItem(page.projection, `${from} offered a room with an invalid link.`),
		);
		return false;
	}
	if (page.projection.get().invites.length >= MAX_PENDING_INVITES) {
		store.deliverActive(
			page.projection,
			store.sysItem(
				page.projection,
				`${from} offered you ${label || "a room"}, but the offers list is full. ` +
					`Take up or decline some in the rooms list first, then ask again.`,
			),
		);
		return false;
	}
	home.page.offers.invitationSequence += 1;
	store.addInvite(page.projection, {
		id: "invite:" + home.page.offers.invitationSequence,
		dir: target.directory,
		locator: target.address,
		nick: store.dirNick(page.projection, home.id) || store.reachingNick(page.projection),
		way: "link",
		label,
		from,
		link,
	});
	announceOffer(page, from, label);
	return true;
}
