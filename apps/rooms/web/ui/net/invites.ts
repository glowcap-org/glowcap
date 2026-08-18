// Offers into rooms nobody can look up: taking up or letting go an invite,
// redeeming a room link, and minting one. A private room is reached only by
// holding a reference to it — the reader who made it holds one, and `invite`
// hands another to somebody the directory can reach. That is the whole of
// the privacy: there is no member list to be on and no check to pass, which
// is why these verbs are about references rather than names.

import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { reason } from "./common.ts";
import { dirAddress, dirSession, isCurrent, type Live } from "./live.ts";
import { notePickedRoom } from "./bootstrap.ts";
import { takeHandedRoom } from "./direct.ts";
import { enterRoom } from "./rooms.ts";

// A private room is not in any list and cannot be entered by name, so the only
// way anybody reaches one is by holding a reference to it: the reader who made
// it holds one, and `invite` hands another to somebody the directory can reach.
// That is the whole of the privacy — there is no member list to be on and no
// check to pass — and it is why these three verbs are about references rather
// than about names.

/** Take up an offer: enter the handed room, or redeem the link.
 *
 * The row is off the list before the attempt either way, so a slow join cannot
 * invite a second press that would spend the offer twice. A handed room that
 * fails to seat is gone for good — the reference was the offer, and its
 * sessions decide its life — so the failure says to ask for another rather
 * than promising a retry that cannot work. */
export async function acceptInvite(id: string): Promise<string> {
	const invite = store.get().invites.find((row) => row.id === id);
	if (invite === undefined) return "that offer is no longer good";
	const session = dirSession(invite.dir);
	// A reconnect does not invalidate a Host-scoped handed reference. Keep the
	// row so the same press can succeed once its directory is back, instead of
	// deleting the only UI path to an occurrence we still own.
	if (session === null) return "not connected to that room directory yet";
	const nick = store.dirNick(session.id) || store.reachingNick();
	if (!nick) return "join a room here first, so this directory knows what to call you";
	store.dropInvite(id);
	// Taking one up is asking to be in the room, so it opens on screen the way
	// pressing a room in the rail does.
	notePickedRoom();
	if (invite.way === "link") {
		return await takeRoomLink(session.id, invite.link, invite.label, nick);
	}
	// Moved out, never read twice: whatever happens next, this id spends its
	// reference exactly once.
	const handed = takeHandedRoom(id);
	if (handed === null) return "that offer is no longer good";
	// Untrusted: a handed room is a bearer reference from a direct line, and its
	// host is whoever handed it — which may be a peer who spawned an object
	// that only looks like a room. That matters for one thing, the name
	// voucher, which enterRoom must never mint toward it (see the guard).
	const why = await enterRoom(
		session.id,
		invite.label || "a room",
		nick,
		0,
		{ key: store.heldRoomKey(), room: handed.room },
		undefined,
		nick,
		false,
	);
	if (why === "") return "";
	// The reference did not seat the reader, and there is nothing here that can
	// revive it: the sender holds the room, so another offer is theirs to make.
	// Given back rather than kept, so a live-but-unseated room does not hold an
	// export for a reader who is not coming.
	handed.release("unseated handed room");
	return `${why}. The offer is spent; ask ${invite.from} to offer the room again`;
}

/** Redeem a room link on one directory's session and enter what it opens.
 *
 * The link is the authority and the label is the reader's own word for the
 * room, which is why the label is passed rather than asked for: a private room
 * restored from a link has none to give. */
export async function takeRoomLink(dir: DirId, link: string, label: string, nick: string): Promise<string> {
	const session = dirSession(dir);
	if (session === null) return "not connected to the room directory yet";
	try {
		const room = await session.dir.session.enliven(link);
		if (!isCurrent(session)) return "";
		return await enterRoom(dir, label || "a room", nick, 0, { key: store.heldRoomKey(), room });
	} catch (err) {
		return reason(err);
	}
}

/** Let an offer go.
 *
 * A link is forgotten — it was a string, and the room was never told there was
 * an offer. A handed room is given back: the reference is released, so the
 * server stops holding an export for a reader who is not coming. */
export function declineInvite(id: string): void {
	const room = takeHandedRoom(id);
	store.dropInvite(id);
	if (room === null) return;
	room.release("declined handed room");
}

/** A link to one room this tab is in: the durable authority whoever holds it
 * can redeem, composed with the address this directory was reached at.
 *
 * The address is the route this tab actually used rather than the directory's
 * authority alone, because a link is for somebody else to dial and a route is
 * what they will need. */
export async function mintRoomLink(session: Live, key: string): Promise<string> {
	const room = session.rooms.get(key);
	if (room === undefined) throw new Error("this tab is not in that room");
	return await room.link(dirAddress(session.id));
}
