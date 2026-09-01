// Rooms: getting into one, leaving it, and the ones nobody can look up.
//
// A room reached by name is found by that name; a private room has no name to
// find, so the only way anybody is in one is by holding a reference somebody
// handed them. Both meet at the same subscribe, which is why entering is one
// function taking an optional reference rather than two that would drift apart.
//
// The private half is that same idea one level up: no member list to be on and
// no check to pass, so these verbs are about references rather than names, and
// the privacy is simply that a reference is the only way in.

import * as store from "../store.ts";
import { type Given, implied, named, type Source } from "../intent.ts";
import { type DirId, type DmConv } from "../types.ts";

import { reason } from "./common.ts";
import { convSession, dirAddress, dirSession, isCurrent } from "./live.ts";
import { actLocator } from "./bootstrap.ts";
import type { RoomsPageContext } from "../page.ts";
import { dropDirectRoute, releaseBackChannel } from "./direct.ts";
import { enterRoom } from "./enter.ts";
import { forgetPeeringForSource } from "./peering.ts";
import { closeArchiveGeneration } from "./history.ts";
import { releaseArchiveSharesForConversation } from "./archive_shares.ts";
import type { RoomPolicy } from "../../../lib/room/policy.ts";
export { enterRoom } from "./enter.ts";

// ── Rooms: picking, creating, joining ─────────────────────────────────────
/** Tapping a room in the rail selects its conversation. Joining is a separate
 * act offered inside a selected room whose membership is unavailable.
 *
 * This is the *press*, so it carries the one thing only a press means:
 * pressing the room already on screen is how a reader puts the rail away.
 * Navigation that is not a press — the address bar, a shared link — goes
 * through `showRoom` below, which is the same work without that toggle,
 * because where a reader is standing must not decide whether their rail is
 * open. */
export function pickRoom(page: RoomsPageContext, dir: DirId, name: string, at?: string): void {
	const projection = page.projection;
	const existing = store.existingRoom(projection, dir, name, at);
	if (existing != null && existing.key === projection.get().activeKey) {
		store.showRail(projection, false);
		return;
	}
	showRoom(page, dir, name, "press", at);
}

/** Show a room, getting there if this tab is not in it yet: the same work the
 * rail's press does, minus the press.
 *
 * `from` is how the reader got here, which matters only on the last arm: this
 * may end at the join card, and a card put up by a link has to name what the
 * link was gating rather than offer what somebody typed last.
 *
 * `at` names the conversation for a caller that has one — a row in the rail —
 * because a room reached by a reference has no name to derive a key from, and
 * two of them may be called the same thing. */
export function showRoom(page: RoomsPageContext, dir: DirId, name: string, from: Source, at?: string): void {
	const projection = page.projection;
	const conv = store.existingRoom(projection, dir, name, at);
	// Being in a room is something this tab knows, not something the connection
	// has to confirm: the conversation and its history are already here. So a room
	// already open is shown whatever its directory is doing — including while that
	// directory is reconnecting, which is exactly when a reader goes looking for
	// what was said. Gating this on a live session meant a directory dropping
	// turned every room on it into a join card: the reader was put in front of a
	// form asking them to enter a room they were already in, with the history they
	// wanted sitting behind it. The composer says what the directory is doing, so
	// nothing here has to pretend the room can be written to.
	//
	// Listed rooms are found by name or by publication identity, not only by the
	// caller's key: a bridge retained from a shared session is still that room
	// when the address or live listing spells it the other way.
	if (conv != null) {
		store.switchTo(projection, conv.key);
		return;
	}
	const publication = at === undefined ? store.enteredPublication(projection, dir, name) : null;
	// Entering one is different: that does need a session and a name on it.
	const held = dirSession(page, dir);
	const knownAs = (store.requestedDirNick(projection, dir) || store.reachingNick(projection)) !== "";
	if (knownAs && held !== null) {
		enterPickedRoom(page, dir, name, publication?.id);
		return;
	}
	// No name granted yet, so the card comes up as the gate on this room: the
	// room by name, and the directory it is on, which nobody said out loud but
	// which reaching for a room on it can only mean.
	gateJoin(page, dir, name, from);
}

/** Put the join card up as the gate on this room: the room by name, and either
 * the directory it is on or a room entry link. This tab has no nickname to
 * enter with, and inventing one is not an entry. */
export function gateJoin(
	page: RoomsPageContext,
	dir: DirId,
	name: string,
	from: Source,
	locator?: Given<string>,
): void {
	store.showJoinFor(page.projection, {
		source: from,
		room: named(name),
		locator: actLocator(page, locator ?? implied(dirAddress(page, dir))),
	});
}

function enterPickedRoom(page: RoomsPageContext, dir: DirId, name: string, publicationId?: string): void {
	const projection = page.projection;
	const key = store.resolveRoomKey(projection, dir, name, publicationId);
	store.setRoomMembership(projection, key, "joining");
	// To the directory the work is about, not whichever one is on screen: read
	// from another directory's room, this line landed on that one's foot and
	// stayed, since only the targeted completion write would ever replace it.
	store.setDirStatus(projection, dir, "entering #" + name + "…");
	void enterRoom(
		page,
		dir,
		name,
		store.requestedDirNick(projection, dir) || store.reachingNick(projection),
		{
			publicationId,
			select: true,
		},
	);
}

/** Hold the room a reader asked for until a directory is up to enter it on,
 * and answer when that attempt has settled.
 *
 * One join waits at a time: a second supersedes the first, which is let go with
 * an empty answer rather than left pending on a card that has moved on. */
export function stageJoin(
	page: RoomsPageContext,
	room: string,
	nick: string,
	policy: RoomPolicy,
	signal?: AbortSignal,
): Promise<string> {
	return page.connections.stageJoin(room, nick, policy, signal);
}

/** Take the room a reader asked for before this directory was up, if one is
 * waiting. Read once: whoever takes it owns settling it. */
export function takeStaged(page: RoomsPageContext): {
	room: string;
	nick: string;
	policy: RoomPolicy;
} | null {
	return page.connections.takeStaged();
}

export function settleStaged(page: RoomsPageContext, message: string): void {
	page.connections.settleStaged(message);
}

/** Drop a join that is still waiting on a directory. The card has moved on, so
 * a session that comes up afterwards must not walk into the room it no longer
 * wants. */
export function abandonJoin(page: RoomsPageContext): void {
	page.connections.abandonJoin();
}

// ── Managed room creation ──────────────────────────────────────────────────

/** Create one managed room under its final policy, then enter through the
 * participant entrance returned to its creator. */
export async function openManagedRoom(
	page: RoomsPageContext,
	dir: DirId,
	label: string,
	policy: RoomPolicy,
	asNick?: string,
	signal?: AbortSignal,
): Promise<string> {
	const projection = page.projection;
	if (signal?.aborted) return "";
	const session = dirSession(page, dir);
	if (session === null) return "not connected to the room directory yet";
	const nick = asNick || store.requestedDirNick(projection, dir) || store.reachingNick(projection);
	if (!nick) return "join a room here first, so this directory knows what to call you";
	try {
		const managed = await session.dir.openManaged(label, { policy });
		if (!isCurrent(session) || signal?.aborted) return "";
		const held = policy.visibility === "secret"
			? { key: store.heldRoomKey(projection), room: managed.room }
			: undefined;
		return await enterRoom(page, dir, label, nick, {
			...(held == null ? { room: managed.room } : { held }),
			link: managed.roomLink,
			manager: managed.managerLink,
			requested: nick,
			select: true,
			signal,
		});
	} catch (err) {
		if (signal?.aborted) return "";
		return reason(err);
	}
}

/** Leave one room, keeping every other room and direct line.
 *
 * A room is a capability and leaving it is telling the room so: the membership
 * is released, everyone else sees the departure, and the name frees up if we
 * were the last one in. The directory session stays up, so the live room list
 * keeps arriving and rejoining is one click.
 *
 * Where the reader lands afterwards depends on what they were looking at. Only
 * someone reading the room being left needs moving at all, and they go to
 * whatever else is open rather than back to the card — leaving one of three
 * rooms is not leaving the application. The card comes back only when nothing
 * is left to show, which is the one way back to it in a window with no reload:
 * a kiosk, an installed app, a browser someone handed you.
 */
export function leaveRoom(page: RoomsPageContext, key: string): void {
	const projection = page.projection;
	const owner = convSession(page, key);
	const room = owner?.rooms.get(key) ?? null;
	const conversation = store.getConv(projection, key);
	const name = conversation?.id ?? "";
	if (conversation != null && conversation.type === "room") forgetPeeringForSource(page, conversation.persistId);
	owner?.rooms.delete(key);
	// What that membership was told goes with the membership.
	owner?.standingTold.delete(key);
	// Read what is on screen before anything is cleared: every other conversation
	// stands on its own, so leaving this room should leave a reader where they
	// are unless this room *is* where they are.
	const wasReading = projection.get().activeKey === key;
	store.forgetConv(projection, key);
	if (wasReading) {
		store.closeAboutConv(projection);
		const next = store.nextStandingKey(projection.get().convs);
		if (next === undefined) store.showJoinCard(projection);
		else store.switchTo(projection, next);
	}
	// The leave is over, so the act the foot was narrating is too; an empty
	// status lets the state row fall back to its settled words.
	store.setStatus(projection, "");
	// A leave that fails leaves the room still holding the nick, which the next
	// join will discover as a name already taken, and everyone else still sees
	// this reader present. The conversation is already gone from this tab, so
	// the notice goes on the page rather than into it.
	if (room) {
		void room.leave().catch((err) =>
			store.toast(
				projection,
				"failure",
				`Leaving ${name === "" ? "the room" : "#" + name} did not complete: ${reason(err)}. ` +
					`The room may still list you, and may hold your name for a while.`,
			)
		);
	}
}

/** `/leave` ends whatever is on screen: a room is left, a direct line is
 * closed, a directory view is put away. The title's close asks in that
 * conversation's card instead. */
export function endConversation(page: RoomsPageContext): void {
	const conv = store.activeConv(page.projection);
	if (conv === null) return;
	if (conv.type === "directory") store.dismissDirectoryView(page.projection, conv.key);
	else if (conv.type === "dm") closeDm(page, conv);
	else leaveRoom(page, conv.key);
}

/** Close a direct conversation and go back to whatever is behind it.
 *
 * A direct line is not a room: there is no membership to hand back. Closing one
 * ends the connections this conversation runs on, in both directions, and drops
 * the history. The person stays reachable, and messaging them again opens a
 * fresh line through a fresh introduction.
 *
 * What is behind it is the room you are still in, if you are still in one, and
 * the join card if you are not.
 */
export function closeDm(page: RoomsPageContext, conv: DmConv): void {
	const projection = page.projection;
	const key = conv.key;
	const s = projection.get();
	const owner = dirSession(page, conv.dir);
	releaseArchiveSharesForConversation(page, key);
	store.forgetConv(projection, key);
	closeArchiveGeneration(page, key);
	// Hand the line's own connection back. A redeemed introduction holds one open
	// to the member for as long as the line lives, so forgetting the line here
	// without closing it would leave the connection and the reply inbox on it
	// standing with nothing on this side referring to them.
	if (owner) dropDirectRoute(owner, conv.peerRegistrationId);
	// The back-channel is the other direction: a connection the member opened to
	// us, captured as it arrived. It carries this conversation and nothing else
	// (a cold dial is per-peer), so letting the conversation go lets it go.
	releaseBackChannel(page, key);
	// Only the conversation you are looking at needs somewhere to go. Closing one
	// from the rail while reading something else should leave you reading it, the
	// same as leaving a room you are not currently in.
	if (s.activeKey !== key) return;
	store.closeAboutConv(projection);
	const next = store.nextStandingKey(projection.get().convs);
	if (next === undefined) store.showJoinCard(projection);
	else store.switchTo(projection, next);
}
