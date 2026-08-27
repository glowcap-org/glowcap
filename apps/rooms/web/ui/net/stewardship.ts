// The browser's stewardship lifecycle: explicit claim, durable handover, and
// reconnect restoration for the room capability this tab is already holding.

import type { Room } from "../../../lib/room_client.ts";
import * as store from "../store.ts";
import { reason, trouble } from "./common.ts";
import { convSession } from "./live.ts";

// One acquisition per conversation generation. Reconnect supersedes an ask
// still settling on the old Room; its completion must never grant the fresh
// membership a capability the old one held.
const pending = new Map<string, symbol>();

function begin(key: string): symbol {
	const token = Symbol(key);
	pending.set(key, token);
	return token;
}

function finish(key: string, token: symbol): void {
	if (pending.get(key) === token) pending.delete(key);
}

function isCurrentRoom(key: string, token: symbol, room: Room): boolean {
	return pending.get(key) === token && convSession(key)?.rooms.get(key) === room;
}

function heldGrants(room: Room): ReadonlySet<string> {
	return new Set([
		...(room.canSetTopic ? ["topic"] : []),
		"steward",
	]);
}

/** Retain the durable half of one successfully validated acquisition. This is
 * safe even if its membership was replaced while the answer was in flight: a
 * fresh membership can take the sturdyref, while discarding it could orphan a
 * steward the server has already issued. */
function recordLinks(key: string, room: Room): void {
	const roomLink = room.roomLink;
	const stewardLink = room.stewardLink;
	if (roomLink === null || stewardLink === null) {
		throw new Error("the room retained an incomplete steward authority");
	}
	store.noteRoomSteward(key, roomLink, stewardLink);
	convSession(key)?.stewardClaimable.delete(key);
}

/** Record possession only for the membership that owns the live reference. */
function record(key: string, room: Room): void {
	if (!room.canKick) throw new Error("the room did not retain its live steward authority");
	recordLinks(key, room);
	store.setGrants(key, heldGrants(room));
}

/** Preserve an authority issued just as its membership was replaced, then
 * take it on the current room generation. */
function carryForward(key: string, room: Room): void {
	recordLinks(key, room);
	const conv = store.getConv(key);
	const current = conv?.type === "room" ? convSession(key)?.rooms.get(key) : undefined;
	if (conv?.type !== "room" || current === undefined || current === room) return;
	restoreStewardship(
		key,
		current,
		() => convSession(key)?.rooms.get(key) === current,
	);
}

/** Restore a steward sturdyref retained by this conversation onto a fresh
 * membership. Failure is visible and leaves the string available for an
 * explicit retry; a transient reconnect must never erase authority. */
export function restoreStewardship(
	key: string,
	room: Room,
	current: () => boolean,
): void {
	const conv = store.getConv(key);
	if (conv?.type !== "room" || conv.steward === undefined) return;
	const token = begin(key);
	void room.takeSteward(conv.steward).then(() => {
		if (current() && isCurrentRoom(key, token, room)) record(key, room);
	}).catch((error) => {
		if (current() && isCurrentRoom(key, token, room)) {
			store.deliver(
				key,
				store.sysItem(`Could not restore this room's moderator capability: ${reason(error)}`),
			);
		}
	}).finally(() => finish(key, token));
}

/** Begin claiming, showing, or taking one exact room's steward capability.
 * Null means there is no live membership to ask. The returned promise settles
 * only after the answer or refusal has reached the store, so an interface can
 * keep the initiating control visibly parked for the whole operation. */
function beginStewardship(key: string, pasted = ""): Promise<string> | null {
	const conv = store.getConv(key);
	const session = conv === null ? null : convSession(key);
	const room = conv === null ? undefined : session?.rooms.get(key);
	if (conv?.type !== "room" || session === null || room === undefined) return null;
	const offered = pasted.trim();

	if (room.canKick && offered === "") {
		record(key, room);
		store.deliver(
			key,
			store.sysItem("This tab holds the room moderator capability. Copy or share it from Details."),
		);
		return Promise.resolve("");
	}
	if (pending.has(key)) {
		const already = "This tab is already taking the room moderator capability.";
		store.deliver(key, store.sysItem(already));
		return Promise.resolve(already);
	}

	const retained = offered === "" ? conv.steward : undefined;
	const token = begin(key);
	const work = offered !== ""
		? room.takeSteward(offered).then(() => true)
		: retained !== undefined
		? room.takeSteward(retained).then(() => true)
		: room.claimSteward();
	// The room's answer goes two places: into the room as a system line, which
	// is the only surface a command has, and back to the caller as the refusal
	// or "", which is what a control in the room's card shows beside itself.
	return work.then((held) => {
		if (!isCurrentRoom(key, token, room)) {
			if (held) {
				try {
					carryForward(key, room);
				} catch (error) {
					trouble("could not preserve stewardship across a replaced membership", error);
				}
			}
			return "";
		}
		if (held) {
			record(key, room);
			store.deliver(
				key,
				store.sysItem(
					offered === ""
						? "This tab now holds the room moderator capability. Copy or share it from Details."
						: "This tab took the room moderator capability.",
				),
			);
			return "";
		}
		store.clearRoomStewardClaim(key);
		convSession(key)?.stewardClaimable.delete(key);
		const refused =
			"This membership cannot claim moderation. Take the room moderator capability from its current holder.";
		store.deliver(key, store.sysItem(refused));
		return refused;
	}).catch((error) => {
		const refused = `Could not take this room's moderator capability: ${reason(error)}`;
		if (isCurrentRoom(key, token, room)) store.deliver(key, store.sysItem(refused));
		return refused;
	}).finally(() => finish(key, token));
}

/** Fire the stewardship operation from a command. Commands need a synchronous
 * admission answer; the room's eventual answer is delivered as a system line. */
export function steward(key: string, pasted = ""): boolean {
	return beginStewardship(key, pasted) !== null;
}

/** Run stewardship from an interface control that must remain busy until the
 * capability has either landed or produced its visible refusal, which it
 * resolves with ("" once held) so the control can show it where it stands. */
export function takeStewardship(key: string, pasted = ""): Promise<string> | null {
	return beginStewardship(key, pasted);
}

/** Begin asking a member out through one exact room capability. The room
 * broadcasts the departure to everybody, this tab included, so success needs
 * no local echo; settlement still matters to the control that initiated it. */
export function askMemberOutSettled(key: string, who: string): Promise<string> | null {
	const conv = store.getConv(key);
	const room = conv?.type === "room" ? convSession(key)?.rooms.get(key) : undefined;
	if (conv?.type !== "room" || room === undefined || !room.canKick) return null;
	return room.kick(who).then(() => "", (error) => {
		const refused = `Could not ask ${who} to leave: ${reason(error)}`;
		store.deliver(key, store.sysItem(refused));
		return refused;
	});
}

/** Fire moderation from a command, preserving its synchronous authority test. */
export function askMemberOut(key: string, who: string): boolean {
	return askMemberOutSettled(key, who) !== null;
}
