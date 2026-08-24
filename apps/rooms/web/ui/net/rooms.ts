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
import { implied, named, type Source } from "../intent.ts";
import { type DirId, type DmConv } from "../types.ts";

import { reason } from "./common.ts";
import { convSession, dirAddress, dirSession, isCurrent } from "./live.ts";
import { actLocator, notePickedRoom } from "./bootstrap.ts";
import { dropLine, releaseBackChannel } from "./direct.ts";
import { enterRoom } from "./enter.ts";
export { enterRoom } from "./enter.ts";

// ── Rooms: picking, creating, joining ─────────────────────────────────────
/** Tapping a room in the rail: show it if we are in it, otherwise enter it.
 *
 * Entering is additive, so picking a second room does not give up the first.
 * That is the whole difference multi-room makes here, and it is why this asks
 * whether we hold *that* room rather than whether we hold any.
 *
 * This is the *press*, so it carries the one thing only a press means:
 * pressing the room already on screen is how a reader puts the rail away.
 * Navigation that is not a press — the address bar, a shared link — goes
 * through `showRoom` below, which is the same work without that toggle,
 * because where a reader is standing must not decide whether their rail is
 * open. */
export function pickRoom(dir: DirId, name: string, at?: string): void {
	const s = store.get();
	const publication = at === undefined ? store.enteredPublication(dir, name) : null;
	const key = at ?? (publication === null ? store.roomKey(dir, name) : store.publishedRoomKey(dir, publication.id));
	const conv = store.getConv(key);
	const heldRoom = conv?.type === "room" && conv.held;
	const held = dirSession(dir);
	const knownAs = (store.dirNick(dir) || store.reachingNick()) !== "";
	const open = conv?.type === "room";
	const backIn = !heldRoom && held !== null && knownAs && open && !held.rooms.has(key);
	// Pressing the room being read is how a reader puts the rail away, unless it
	// is the room that has stopped working, in which case they are asking for the
	// one thing that would fix it.
	if (key === s.activeKey && !backIn) {
		store.showRail(false);
		return;
	}
	showRoom(dir, name, "press", at);
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
export function showRoom(dir: DirId, name: string, from: Source, at?: string): void {
	const publication = at === undefined ? store.enteredPublication(dir, name) : null;
	const key = at ?? (publication === null ? store.roomKey(dir, name) : store.publishedRoomKey(dir, publication.id));
	const conv = store.getConv(key);
	const open = conv?.type === "room";
	const heldRoom = conv?.type === "room" && conv.held;
	// Whether reaching this room means asking to be back in it. Being in a room is
	// holding a membership on the live session, and a conversation on screen is not
	// that: a re-entry refused after a reconnect, or a message stream that broke
	// under a live one, leaves the history here and the membership gone. This is
	// the way back, and short of leaving a room they can still read it is the only
	// one. A session that is away keeps the ordinary behaviour, because its own
	// reconnect re-enters every room it holds.
	//
	// Never for a room this tab was handed: the reference it was reached by went
	// with the session that carried it, and there is no name to ask for it back
	// with. Reaching that row shows what was said and nothing else.
	const held = dirSession(dir);
	const knownAs = (store.dirNick(dir) || store.reachingNick()) !== "";
	const backIn = !heldRoom && held !== null && knownAs && open && !held.rooms.has(key);
	if (backIn) {
		enterPickedRoom(dir, name, conv?.type === "room" ? conv.publicationId : publication?.id);
		return;
	}
	// Being in a room is something this tab knows, not something the connection
	// has to confirm: the conversation and its history are already here. So a room
	// already open is shown whatever its directory is doing — including while that
	// directory is reconnecting, which is exactly when a reader goes looking for
	// what was said. Gating this on a live session meant a directory dropping
	// turned every room on it into a join card: the reader was put in front of a
	// form asking them to enter a room they were already in, with the history they
	// wanted sitting behind it. The composer says what the directory is doing, so
	// nothing here has to pretend the room can be written to.
	if (open) {
		store.switchTo(key);
		return;
	}
	// Entering one is different: that does need a session and a name on it.
	if (knownAs && held !== null) {
		enterPickedRoom(dir, name, publication?.id);
		return;
	}
	// No name granted yet, so the card comes up as the gate on this room, and it
	// is filed as exactly that: the room by name, and the directory it is on,
	// which nobody said out loud but which reaching for a room on it can only
	// mean. Naming the room alone was the whole of an old defect — a link to a
	// room here would put up a gate offering to join it somewhere else entirely,
	// because the locator field was still holding the last address anybody had
	// typed and nothing in the act contradicted it.
	store.showJoinFor({
		source: from,
		room: named(name),
		locator: actLocator(implied(dirAddress(dir))),
	});
}

function enterPickedRoom(dir: DirId, name: string, publicationId?: string): void {
	notePickedRoom();
	// To the directory the work is about, not whichever one is on screen: read
	// from another directory's room, this line landed on that one's foot and
	// stayed, since only the targeted completion write would ever replace it.
	store.setDirStatus(dir, "entering #" + name + "…");
	void enterRoom(dir, name, store.dirNick(dir) || store.reachingNick(), { publicationId });
}

/// A join asked for before the peer session was open. The session is fetched,
/// instantiated, and handshaked after the page loads, and a returning visitor's
/// name is prefilled with the Join button focused — so pressing Enter inside
/// that window is the *common* first interaction, not an unusual one. The
/// request is held, and `openSession` replays it the moment it can.
let staged: { room: string; nick: string; hidden: boolean } | null = null;
let stagedSettle: ((message: string) => void) | null = null;

/** Hold the room a reader asked for until a directory is up to enter it on,
 * and answer when that attempt has settled.
 *
 * One join waits at a time: a second supersedes the first, which is let go with
 * an empty answer rather than left pending on a card that has moved on. */
export function stageJoin(room: string, nick: string, hidden = false, signal?: AbortSignal): Promise<string> {
	settleStaged("");
	if (signal?.aborted) return Promise.resolve("");
	staged = { room, nick, hidden };
	return new Promise<string>((resolve) => {
		stagedSettle = resolve;
		signal?.addEventListener("abort", () => abandonJoin(), { once: true });
	});
}

/** Take the room a reader asked for before this directory was up, if one is
 * waiting. Read once: whoever takes it owns settling it. */
export function takeStaged(): { room: string; nick: string; hidden: boolean } | null {
	const wanted = staged;
	staged = null;
	return wanted;
}

export function settleStaged(message: string): void {
	const settle = stagedSettle;
	stagedSettle = null;
	settle?.(message);
}

/** Drop a join that is still waiting on a directory. The card has moved on, so
 * a session that comes up afterwards must not walk into the room it no longer
 * wants. */
export function abandonJoin(): void {
	staged = null;
	settleStaged("");
}

// ── Rooms nobody can look up ───────────────────────────────────────────────

/** Make a room nobody can look up, and enter it.
 *
 * The label is what to call it and nothing more: it is not taken from anybody,
 * two of them may share one, and no name gets anyone in. */
export async function openPrivateRoom(
	dir: DirId,
	label: string,
	asNick?: string,
	signal?: AbortSignal,
): Promise<string> {
	if (signal?.aborted) return "";
	const session = dirSession(dir);
	if (session === null) return "not connected to the room directory yet";
	const nick = asNick || store.dirNick(dir) || store.reachingNick();
	if (!nick) return "join a room here first, so this directory knows what to call you";
	try {
		const room = await session.dir.open(label, true);
		if (!isCurrent(session) || signal?.aborted) return "";
		// Making a room is asking to be in it, the same as naming a public one.
		notePickedRoom();
		return await enterRoom(dir, label, nick, {
			held: { key: store.heldRoomKey(), room },
			requested: nick,
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
export function leaveRoom(key: string): void {
	const owner = convSession(key);
	const room = owner?.rooms.get(key) ?? null;
	const name = store.getConv(key)?.id ?? "";
	owner?.rooms.delete(key);
	// What that membership was told goes with the membership.
	owner?.standingTold.delete(key);
	// Read what is on screen before anything is cleared: every other conversation
	// stands on its own, so leaving this room should leave a reader where they
	// are unless this room *is* where they are.
	const wasReading = store.get().activeKey === key;
	store.forgetConv(key);
	if (wasReading) {
		store.closeAboutConv();
		const next = [...store.get().convs.keys()][0];
		if (next === undefined) store.showJoinCard();
		else store.switchTo(next);
	}
	// The leave is over, so the act the foot was narrating is too; an empty
	// status lets the state row fall back to its settled words.
	store.setStatus("");
	// A leave that fails leaves the room still holding the nick, which the next
	// join will discover as a name already taken, and everyone else still sees
	// this reader present. The conversation is already gone from this tab, so
	// the notice goes on the page rather than into it.
	if (room) {
		void room.leave().catch((err) =>
			store.toast(
				"failure",
				`Leaving ${name === "" ? "the room" : "#" + name} did not complete: ${reason(err)}. ` +
					`The room may still list you, and may hold your name for a while.`,
			)
		);
	}
}

/** The title's mark ends whatever it names: a room is left, a direct line is
 * closed. One control, because from the reader's side it is one gesture. */
export function endConversation(): void {
	const conv = store.activeConv();
	if (conv === null) return;
	if (conv.type === "dm") closeDm(conv);
	else leaveRoom(conv.key);
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
export function closeDm(conv: DmConv): void {
	const key = conv.key;
	const s = store.get();
	const owner = dirSession(conv.dir);
	store.forgetConv(key);
	// Hand the line's own connection back. A redeemed introduction holds one open
	// to the member for as long as the line lives, so forgetting the line here
	// without closing it would leave the connection and the reply inbox on it
	// standing with nothing on this side referring to them.
	if (owner) dropLine(owner, key);
	// The back-channel is the other direction: a connection the member opened to
	// us, captured as it arrived. It carries this conversation and nothing else
	// (a cold dial is per-peer), so letting the conversation go lets it go.
	releaseBackChannel(key);
	// Only the conversation you are looking at needs somewhere to go. Closing one
	// from the rail while reading something else should leave you reading it, the
	// same as leaving a room you are not currently in.
	if (s.activeKey !== key) return;
	store.closeAboutConv();
	const next = [...store.get().convs.keys()][0];
	if (next === undefined) store.showJoinCard();
	else store.switchTo(next);
}
