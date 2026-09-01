// The browser's stewardship lifecycle: explicit claim, durable handover, and
// reconnect restoration for the room capability this tab is already holding.

// One acquisition per conversation generation. Reconnect supersedes an ask
// still settling on the old Room; its completion must never grant the fresh
// membership a capability the old one held.

import * as store from "../store.ts";
import { NOT_STEWARD, roomErrorOf } from "../../../lib/errors.ts";
import { roomAuthorityToken } from "../../../lib/room/authority.ts";
import { reason, trouble } from "./common.ts";
import { convSession, type Live } from "./live.ts";
import { RoomManager } from "../../../lib/room/manager.ts";
import type { RoomPolicy } from "../../../lib/room/policy.ts";
import type { RoomsPageContext } from "../page.ts";
import type { Room } from "../../../lib/room/client.ts";
function begin(owner: Live, key: string): symbol {
	const token = Symbol(key);
	owner.stewardshipPending.set(key, token);
	return token;
}

function finish(owner: Live, key: string, token: symbol): void {
	if (owner.stewardshipPending.get(key) === token) owner.stewardshipPending.delete(key);
}

function isCurrentRoom(owner: Live, key: string, token: symbol, room: Room): boolean {
	return owner.stewardshipPending.get(key) === token && convSession(owner.page, key) === owner &&
		owner.rooms.get(key) === room;
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
function recordLinks(page: RoomsPageContext, key: string, room: Room): void {
	const roomLink = room.roomLink;
	const stewardLink = room.stewardLink;
	if (roomLink === null || stewardLink === null) {
		throw new Error("the room retained an incomplete steward authority");
	}
	store.noteRoomSteward(page.projection, key, roomLink, stewardLink);
}

/** Record possession only for the membership that owns the live reference. */
function record(page: RoomsPageContext, key: string, room: Room): void {
	if (!room.canKick) throw new Error("the room did not retain its live steward authority");
	recordLinks(page, key, room);
	store.setGrants(page.projection, key, heldGrants(room));
}

/** Preserve an authority issued just as its membership was replaced, then
 * take it on the current room generation. */
function carryForward(page: RoomsPageContext, key: string, room: Room): void {
	recordLinks(page, key, room);
	const conv = store.getConv(page.projection, key);
	const current = conv?.type === "room" ? convSession(page, key)?.rooms.get(key) : undefined;
	if (conv?.type !== "room" || current === undefined || current === room) return;
	restoreStewardship(page, key, current, () => convSession(page, key)?.rooms.get(key) === current);
}

/** Restore a steward sturdyref retained by this conversation onto a fresh
 * membership. Failure is visible and leaves the string available for an
 * explicit retry; a transient reconnect must never erase authority. */
export function restoreStewardship(page: RoomsPageContext, key: string, room: Room, current: () => boolean): void {
	const projection = page.projection;
	const conv = store.getConv(projection, key);
	const owner = conv?.type === "room" ? convSession(page, key) : null;
	if (conv?.type !== "room" || conv.steward === undefined || owner === null) return;
	const steward = conv.steward;
	const token = begin(owner, key);
	void room.takeSteward(steward).then(() => {
		if (current() && isCurrentRoom(owner, key, token, room)) record(page, key, room);
	}).catch((error) => {
		if (current() && isCurrentRoom(owner, key, token, room)) {
			if (roomErrorOf(error)?.code === NOT_STEWARD) {
				store.clearRoomAuthority(projection, key, {
					kind: "steward",
					token: roomAuthorityToken(steward),
					claimable: false,
				});
				store.deliver(
					projection,
					key,
					store.sysItem(
						projection,
						"This room's saved moderator capability was retired. Take or request a current one.",
					),
				);
				return;
			}
			store.deliver(
				projection,
				key,
				store.sysItem(projection, `Could not restore this room's moderator capability: ${reason(error)}`),
			);
		}
	}).finally(() => finish(owner, key, token));
}

/** Begin claiming, showing, or taking one exact room's steward capability.
 * Null means there is no live membership to ask. The returned promise settles
 * only after the answer or refusal has reached the store, so an interface can
 * keep the initiating control visibly parked for the whole operation. */
function beginStewardship(page: RoomsPageContext, key: string, pasted = ""): Promise<string> | null {
	const projection = page.projection;
	const conv = store.getConv(projection, key);
	const session = conv === null ? null : convSession(page, key);
	const room = conv === null ? undefined : session?.rooms.get(key);
	if (conv?.type !== "room" || session === null || room === undefined) return null;
	const offered = pasted.trim();

	if (room.canKick && offered === "") {
		record(page, key, room);
		store.deliver(
			projection,
			key,
			store.sysItem(
				projection,
				"This tab holds the room moderator capability. Copy or share it from Details.",
			),
		);
		return Promise.resolve("");
	}
	if (session.stewardshipPending.has(key)) {
		const already = "This tab is already taking the room moderator capability.";
		store.deliver(projection, key, store.sysItem(projection, already));
		return Promise.resolve(already);
	}

	const retained = offered === "" ? conv.steward : undefined;
	const token = begin(session, key);
	const work = offered !== ""
		? room.takeSteward(offered).then(() => true)
		: retained !== undefined
		? room.takeSteward(retained).then(() => true)
		: room.claimSteward();
	// The room's answer goes two places: into the room as a system line, which
	// is the only surface a command has, and back to the caller as the refusal
	// or "", which is what a control in the room's card shows beside itself.
	return work.then((held) => {
		if (!isCurrentRoom(session, key, token, room)) {
			if (held) {
				try {
					carryForward(page, key, room);
				} catch (error) {
					trouble(projection, "could not preserve stewardship across a replaced membership", error);
				}
			}
			return "";
		}
		if (held) {
			record(page, key, room);
			store.deliver(
				projection,
				key,
				store.sysItem(
					projection,
					offered === ""
						? "This tab now holds the room moderator capability. Copy or share it from Details."
						: "This tab took the room moderator capability.",
				),
			);
			return "";
		}
		const refused = "You cannot claim moderation here. Take the room's moderator capability from whoever holds it.";
		store.deliver(projection, key, store.sysItem(projection, refused));
		return refused;
	}).catch((error) => {
		const refused = `Could not take this room's moderator capability: ${reason(error)}`;
		if (isCurrentRoom(session, key, token, room)) {
			store.deliver(projection, key, store.sysItem(projection, refused));
		}
		return refused;
	}).finally(() => finish(session, key, token));
}

/** Fire the stewardship operation from a command. Commands need a synchronous
 * admission answer; the room's eventual answer is delivered as a system line. */
export function steward(page: RoomsPageContext, key: string, pasted = ""): boolean {
	return beginStewardship(page, key, pasted) !== null;
}

/** Run stewardship from an interface control that must remain busy until the
 * capability has either landed or produced its visible refusal, which it
 * resolves with ("" once held) so the control can show it where it stands. */
export function takeStewardship(page: RoomsPageContext, key: string, pasted = ""): Promise<string> | null {
	return beginStewardship(page, key, pasted);
}

export async function takeRoomManager(page: RoomsPageContext, key: string, managerLink: string): Promise<string> {
	const owner = convSession(page, key);
	const room = owner?.rooms.get(key);
	if (owner == null || room == null) return "You are not connected to this room right now.";
	try {
		await room.takeManager(managerLink.trim());
		store.noteRoomManager(page.projection, key, managerLink.trim());
		return "";
	} catch (error) {
		return `Could not take this room's manager capability: ${reason(error)}`;
	}
}

export async function recoverRoomManager(
	page: RoomsPageContext,
	key: string,
	issue: (identity: string) => Promise<{ manager: string } | { refused: string }>,
): Promise<string> {
	const owner = convSession(page, key);
	const room = owner?.rooms.get(key);
	if (owner == null || room == null) return "You are not connected to this room right now.";
	try {
		const issued = await issue(await room.managerIdentity());
		if ("refused" in issued) return issued.refused;
		return await takeRoomManager(page, key, issued.manager);
	} catch (error) {
		return `Could not recover this room's manager capability: ${reason(error)}`;
	}
}

export function dropRoomManager(page: RoomsPageContext, key: string, expectedToken: string): Promise<string> {
	const conv = store.getConv(page.projection, key);
	if (conv?.type !== "room" || conv.manager == null) {
		return Promise.resolve("This browser does not retain room management.");
	}
	if (roomAuthorityToken(conv.manager) !== expectedToken) {
		return Promise.resolve("This room's manager capability changed.");
	}
	convSession(page, key)?.rooms.get(key)?.dropManager();
	store.dropRoomManager(page.projection, key, expectedToken);
	return Promise.resolve("");
}

export async function revokeManagedRoomAuthority(
	page: RoomsPageContext,
	key: string,
	kind: "room" | "steward",
	token: string,
): Promise<string> {
	const conv = store.getConv(page.projection, key);
	const owner = conv?.type === "room" ? convSession(page, key) : null;
	const room = owner?.rooms.get(key);
	if (conv?.type !== "room" || conv.manager == null || owner == null || room == null) {
		return "This room and its manager capability must be connected.";
	}
	try {
		const manager = await RoomManager.take(owner.dir.session, room.reference, conv.manager);
		if (kind === "room") await manager.revokeRoomLink(token);
		else await manager.revokeModerator(token);
		store.clearRoomAuthority(page.projection, key, { kind, token, claimable: false });
		return "";
	} catch (error) {
		return reason(error);
	}
}

export async function unregisterManagedRoom(page: RoomsPageContext, key: string): Promise<string> {
	const conv = store.getConv(page.projection, key);
	const owner = conv?.type === "room" ? convSession(page, key) : null;
	const room = owner?.rooms.get(key);
	if (conv?.type !== "room" || conv.manager == null || owner == null || room == null) {
		return "This room and its manager capability must be connected.";
	}
	try {
		const answer = await room.unregisterManagedRoom();
		store.setRoomPolicy(page.projection, key, answer.policy, answer.name);
		return "";
	} catch (error) {
		return reason(error);
	}
}

export async function setManagedRoomPolicy(page: RoomsPageContext, key: string, policy: RoomPolicy): Promise<string> {
	const conv = store.getConv(page.projection, key);
	const owner = conv?.type === "room" ? convSession(page, key) : null;
	const room = owner?.rooms.get(key);
	if (conv?.type !== "room" || conv.manager == null || owner == null || room == null) {
		return "This room and its manager capability must be connected.";
	}
	try {
		const answer = await room.setPolicy(policy, conv.id);
		store.setRoomPolicy(page.projection, key, answer.policy, answer.name);
		return "";
	} catch (error) {
		return reason(error);
	}
}

/** Stop retaining this browser's moderator occurrence without revoking the
 * durable generation for anybody else. The saved intent is authoritative even
 * while its directory is offline; a live room is released first when present. */
export function dropStewardship(page: RoomsPageContext, key: string, expectedToken: string): Promise<string> {
	const projection = page.projection;
	const conv = store.getConv(projection, key);
	if (conv?.type !== "room" || conv.steward === undefined) {
		return Promise.resolve("This browser does not retain this room's moderator capability.");
	}
	if (roomAuthorityToken(conv.steward) !== expectedToken) {
		return Promise.resolve("This room's retained moderator capability changed before it could be discarded.");
	}
	const owner = convSession(page, key);
	const room = owner?.rooms.get(key);
	try {
		if (room?.stewardLink != null) room.dropSteward();
		store.clearRoomAuthority(projection, key, {
			kind: "steward",
			token: roomAuthorityToken(conv.steward),
			claimable: false,
		});
		store.deliver(
			projection,
			key,
			store.sysItem(projection, "This browser no longer retains the room moderator capability."),
		);
		return Promise.resolve("");
	} catch (error) {
		return Promise.resolve(`Could not discard this room's moderator capability: ${reason(error)}`);
	}
}

/** Begin asking a member out through one exact room capability. The room
 * broadcasts the departure to everybody, this tab included, so success needs
 * no local echo; settlement still matters to the control that initiated it. */
export function askMemberOutSettled(page: RoomsPageContext, key: string, who: string): Promise<string> | null {
	const projection = page.projection;
	const conv = store.getConv(projection, key);
	const room = conv?.type === "room" ? convSession(page, key)?.rooms.get(key) : undefined;
	if (conv?.type !== "room" || room === undefined || !room.canKick) return null;
	return room.kick(who).then(() => "", (error) => {
		const refused = `Could not ask ${who} to leave: ${reason(error)}`;
		store.deliver(projection, key, store.sysItem(projection, refused));
		return refused;
	});
}

/** Fire moderation from a command, preserving its synchronous authority test. */
export function askMemberOut(page: RoomsPageContext, key: string, who: string): boolean {
	return askMemberOutSettled(page, key, who) !== null;
}
