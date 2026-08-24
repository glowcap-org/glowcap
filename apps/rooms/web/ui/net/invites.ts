// Offers into rooms nobody can look up: taking up or letting go an invite,
// redeeming a room link, and minting one. A private room is reached only by
// holding a reference to it — the reader who made it holds one, and `invite`
// hands another to somebody the directory can reach. That is the whole of
// the privacy: there is no member list to be on and no check to pass, which
// is why these verbs are about references rather than names.

import { roomCalledAs } from "../../../lib/room_client.ts";
import { joinedForLink } from "../joining.ts";
import type { Ref } from "@pancake/runtime";
import * as store from "../store.ts";
import type { DirId } from "../types.ts";
import { reason } from "./common.ts";
import { dirAddress, dirSession, isCurrent, type Live } from "./live.ts";
import { FIRST_BACKOFF_MS, linkDirectory, notePickedRoom } from "./bootstrap.ts";
import { leaveDirectory, openDirectory } from "./connection.ts";
import { takeHandedRoom } from "./direct.ts";
import { enterRoom } from "./rooms.ts";

// A private room is not in any list and cannot be entered by name, so the only
// way anybody reaches one is by holding a reference to it: the reader who made
// it holds one, and `invite` hands another to somebody the directory can reach.
// That is the whole of the privacy — there is no member list to be on and no
// check to pass — and it is why these three verbs are about references rather
// than about names. A handed room may still turn out to be listed: subscribe's
// occupancy is the authority for that, and the provisional held conversation
// is moved onto the directory's public key before it becomes visible.

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
	const nick = store.dirNick(invite.dir) || store.reachingNick();
	if (!nick) return "join a room here first, so this directory knows what to call you";
	if (invite.way === "link") {
		// Redeemed where the link says, not where it arrived. A link is data and
		// names its own peer, so an offer that reached this tab over a direct
		// line on one directory may well be for a room on another, and taking it
		// up does not wait on the directory it arrived over.
		store.dropInvite(id);
		notePickedRoom();
		return await takeRoomLink(invite.link, invite.label, nick);
	}
	const session = dirSession(invite.dir);
	// A reconnect does not invalidate a Host-scoped handed reference. Keep the
	// row so the same press can succeed once its directory is back, instead of
	// deleting the only UI path to an occurrence we still own.
	if (session === null) return "not connected to that room directory yet";
	store.dropInvite(id);
	// Taking one up is asking to be in the room, so it opens on screen the way
	// pressing a room in the rail does.
	notePickedRoom();
	// Moved out, never read twice: whatever happens next, this id spends its
	// reference exactly once.
	const handed = takeHandedRoom(id);
	if (handed === null) return "that offer is no longer good";
	// The sender's label proves nothing, so let the room say what it is called
	// when it implements that question. Listed-ness is not asked here: subscribe
	// carries that fact on the arriving occupancy, and enterRoom moves a listed
	// one onto its public key before committing the conversation. Asking a
	// method first aborts against an older or Goblins-shaped room that can seat
	// us perfectly well without implementing pancake's convenience question.
	let roomName = invite.label || "a room";
	try {
		roomName = (await roomCalledAs(session.dir.session, handed.room)) || roomName;
	} catch {
		// An older room, or one that is not this protocol: the offer's label is
		// presentation only, while the reference remains the authority.
	}
	if (!isCurrent(session)) {
		handed.release("session ended under the offer");
		return `the connection to that directory ended. The offer is spent; ask ${invite.from} to offer the room again`;
	}
	// Untrusted: a handed room is a bearer reference from a direct line, and its
	// host is whoever handed it — which may be a peer who spawned an object
	// that only looks like a room. That matters for one thing, the name
	// voucher, which enterRoom must never mint toward it (see the guard).
	const why = await enterRoom(
		session.id,
		roomName,
		nick,
		{
			room: handed.room,
			requested: nick,
			trusted: false,
		},
	);
	if (why === "") return "";
	// The reference did not seat the reader, and there is nothing here that can
	// revive it: the sender holds the room, so another offer is theirs to make.
	// Given back rather than kept, so a live-but-unseated room does not hold an
	// export for a reader who is not coming.
	handed.release("unseated handed room");
	return `${why}. The offer is spent; ask ${invite.from} to offer the room again`;
}

/** Redeem a room link and enter what it opens.
 *
 * A link is a sturdyref, so it names its own directory: the room it reaches is
 * hosted by whatever peer minted it, which need not be a peer this tab has ever
 * spoken to. So the link decides where it is redeemed. A directory this tab
 * already holds is used as it stands, and one it does not is opened first. That
 * is the same act the join card performs, and it grants no more than the card
 * does: a session, a name registered on it, and the rooms reachable through it.
 *
 * Redeeming stays a session-level `enliven` either way, and that is the whole
 * of the trust boundary here. The session-level verb never dials and refuses a
 * sturdyref for another peer, so the room that comes back is provably the
 * directory's own, which is what `enterRoom` is told when it decides whether a
 * name voucher may be presented. `Host.enliven` would dial by itself and answer
 * without saying which session hosts the result, turning a reader's paste into
 * an unbidden dial and leaving the room on a session no directory row owns.
 *
 * `nick` is what the reader would like to be called, used when the directory
 * being entered has granted them nothing yet; a directory that has granted a
 * name is answered by that grant. The label is what they wrote after the
 * locator, or empty so the room can say what it is called. */
export async function takeRoomLink(link: string, label: string, nick: string): Promise<string> {
	const named = linkDirectory(link);
	if (named === null) return "that is not a room link";
	// Whether this tab had anything of that directory before the link named it:
	// a live session, or a row still reconnecting to one. A directory this
	// redeem opened from nothing and did not seat a room in is given back rather
	// than left in the rail as a server the reader never asked to hold; one that
	// was already there is never touched, because it is somebody's home page or
	// it is carrying their other rooms.
	const wasHeld = dirSession(named.id) !== null || store.get().dirs.has(named.id);
	if (dirSession(named.id) === null) {
		const unreachable = await openDirectory(named.address, FIRST_BACKOFF_MS);
		if (unreachable !== "") return unreachable;
	}
	const why = await redeemOn(named.id, link, label, nick);
	if (why !== "" && !wasHeld && store.joinedRooms(named.id).length === 0) leaveDirectory(named.id);
	return why;
}

/** Bring the link to life on the directory it names, and enter the room.
 *
 * The two failures are kept apart on purpose. A directory that will not answer
 * the link is one that does not know the room — a link for a room that has been
 * let go, or a swissnum that is not one this peer ever minted — and there is
 * nothing the reader can do with it. A room that refuses the subscribe is a
 * live room saying no, which is a different sentence and often an actionable
 * one. */
async function redeemOn(dir: DirId, link: string, label: string, nick: string): Promise<string> {
	const session = dirSession(dir);
	if (session === null) return "not connected to the room directory yet";
	let room: Ref;
	try {
		room = await session.dir.session.enliven(link);
	} catch (err) {
		// A session that went away underneath the redeem is a connection ending,
		// not the directory refusing the link, and saying the second about the
		// first would send the reader to fix a link that is perfectly good.
		if (!isCurrent(session)) return "the connection to that directory ended before the link was answered";
		return `that directory has no room by that link: ${reason(err)}`;
	}
	if (!isCurrent(session)) return "";
	const already = (key: string): "" => {
		session.dir.session.release(room);
		store.noteRoomLink(key, link);
		notePickedRoom();
		store.switchTo(key);
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
		// An older room, or a private one restored with no label, has nothing
		// to say. Sitting in it under a placeholder is still being in it.
	}
	if (name === "") name = label.trim();
	if (!isCurrent(session)) return "";
	// Listed-ness arrives on subscribe, not from a method asked first — that
	// method is missing on an older room and was aborting the join. Same-tab
	// `/link` then `/join` still matches the stored locator here.
	const here = joinedForLink(store.joinedRooms(dir), new Set(session.rooms.keys()), link, null);
	if (here !== null) return already(here);
	return await enterRoom(dir, name, store.dirNick(dir) || nick, { room, link });
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
	const minted = await room.link(dirAddress(session.id));
	store.noteRoomLink(key, minted);
	return minted;
}
