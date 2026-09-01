// Live room and direct-line actions over one durable runtime's realizations.

import type { Room } from "../lib/room/client.ts";
import type { BridgeForm } from "../lib/bridge/form.ts";
import type { DurableDirectLine } from "./direct_line.ts";
import type { LiveDirectory, LiveRoom } from "./live.ts";
import { durableTypingTarget, type RealizeDirect, waitForLiveRealization } from "./realization.ts";
import type { RoomPolicy } from "../lib/room/policy.ts";

function liveRoomFor(directories: ReadonlyMap<string, LiveDirectory>, conversationId: string): LiveRoom {
	for (const directory of directories.values()) {
		const live = directory.roomRealization.rooms.get(conversationId);
		if (live != null) return live;
	}
	throw new Error("that room is not connected in this Rooms session");
}

function roomFor(directories: ReadonlyMap<string, LiveDirectory>, conversationId: string): Room {
	return liveRoomFor(directories, conversationId).room;
}

export async function openManagedRoom(
	directories: ReadonlyMap<string, LiveDirectory>,
	directoryId: string,
	label: string,
	recoveryKey: string,
	policy: RoomPolicy,
): Promise<{ roomLink: string; managerLink: string }> {
	const held = directories.get(directoryId);
	if (held == null) throw new Error("that directory is not connected in this Rooms session");
	const managed = await held.directory.openManaged(label, { policy, roomId: recoveryKey });
	held.directory.session.release(managed.room);
	return { roomLink: managed.roomLink, managerLink: managed.managerLink };
}

function managedRoomFor(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
): { directoryId: string; room: Room } {
	for (const [directoryId, directory] of directories) {
		const room = directory.roomRealization.rooms.get(conversationId)?.room;
		if (room != null) return { directoryId, room };
	}
	throw new Error("that room is not connected in this Rooms session");
}

export function ensureRoomLink(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
): Promise<string> {
	return roomFor(directories, conversationId).link();
}

/** The declared bridge form for one realized room, or null when its bridge
 * declares none. Asked when a reader opens the surface, so the answer is for
 * the state the bridge is in now. */
export function roomBridgeForm(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
): Promise<BridgeForm | null> {
	return roomFor(directories, conversationId).bridgeForm();
}

export async function takeRoomModerator(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
	stewardLink: string | null,
): Promise<string> {
	const room = roomFor(directories, conversationId);
	if (stewardLink == null) {
		if (!(await room.claimSteward())) throw new Error("this room did not offer its moderator capability");
	} else await room.takeSteward(stewardLink);
	const roomLink = room.roomLink;
	const heldSteward = room.stewardLink;
	if (roomLink == null || heldSteward == null) throw new Error("the room retained incomplete moderator authority");
	return JSON.stringify({ roomLink, stewardLink: heldSteward });
}

export async function takeRoomManager(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
	managerLink: string,
): Promise<string> {
	const room = roomFor(directories, conversationId);
	await room.takeManager(managerLink);
	const roomLink = room.roomLink;
	const heldManager = room.managerLink;
	if (roomLink == null || heldManager == null) throw new Error("the room retained incomplete manager authority");
	return JSON.stringify({ roomLink, managerLink: heldManager });
}

export async function recoverRoomManager(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
	issue: (directoryId: string, identity: string) => Promise<string>,
): Promise<string> {
	const { directoryId, room } = managedRoomFor(directories, conversationId);
	const managerLink = await issue(directoryId, await room.managerIdentity());
	await room.takeManager(managerLink);
	const roomLink = await room.link();
	return JSON.stringify({ roomLink, managerLink });
}

function assertRoomManagerRecoverable(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
): void {
	for (const directory of directories.values()) {
		const live = directory.roomRealization.rooms.get(conversationId);
		if (live == null) continue;
		if (live.source === "local") return;
		if (live.source === "bridge") {
			throw new Error("this room is owned by its IRC bridge; manage it through IRC Operations");
		}
		throw new Error("this room's source owns its management capability");
	}
	throw new Error("that room is not connected in this Rooms session");
}

export async function revokeManagedRoomAuthority(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
	kind: "room" | "steward",
	token: string,
): Promise<void> {
	const room = roomFor(directories, conversationId);
	await room.revokeManagedAuthority(kind, token);
}

export async function unregisterManagedRoom(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
): Promise<void> {
	const live = liveRoomFor(directories, conversationId);
	const answer = await live.room.unregisterManagedRoom();
	live.view.policy = answer.policy;
}

export async function setManagedRoomPolicy(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
	name: string,
	policy: RoomPolicy,
): Promise<void> {
	for (const directory of directories.values()) {
		const live = directory.roomRealization.rooms.get(conversationId);
		if (live == null) continue;
		const answer = await live.room.setPolicy(policy, name);
		live.view.policy = answer.policy;
		return;
	}
	throw new Error("that room is not connected in this Rooms session");
}

export function setRoomTopic(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
	text: string,
): Promise<void> {
	return roomFor(directories, conversationId).setTopic(text);
}

export function kickRoomMember(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
	nick: string,
): Promise<void> {
	return roomFor(directories, conversationId).kick(nick);
}

export async function offerRoom(
	directories: ReadonlyMap<string, LiveDirectory>,
	reconciliation: Promise<void>,
	roomConversationId: string,
	directConversationId: string,
	label: string,
	link: string | null,
	realizeDirect: RealizeDirect,
): Promise<void> {
	await realizeDirect(directConversationId);
	const find = (): { room: Room; direct: DurableDirectLine } | null => {
		for (const directory of directories.values()) {
			const live = directory.roomRealization.rooms.get(roomConversationId);
			const direct = directory.directs.get(directConversationId);
			if (live != null && direct != null) return { room: live.room, direct };
		}
		return null;
	};
	const held = find() ?? await waitForLiveRealization(find, reconciliation);
	if (held != null) {
		// A live capability is the natural invitation: it is already the room's
		// authority, needs no durable publication, and remains live only while its
		// holders keep it. This also works for source-owned rooms such as IRC
		// bridges, which must not be forced through native links.
		await held.direct.line.handRoom(label, held.room.reference);
		return;
	}
	if (link == null) {
		throw new Error("the room is not live and has no durable entry link to offer");
	}
	const direct = [...directories.values()]
		.map((directory) => directory.directs.get(directConversationId))
		.find((candidate): candidate is DurableDirectLine => candidate != null);
	if (direct == null) throw new Error("the direct conversation is not realized in this Rooms session");
	await direct.line.offerRoom(label, link);
}

export function setRoomTyping(
	directories: ReadonlyMap<string, LiveDirectory>,
	conversationId: string,
	on: boolean,
): boolean {
	const target = durableTypingTarget(directories, conversationId);
	if (target == null) return false;
	if ("room" in target) void target.room.setTyping(on);
	else void target.direct.line.typing(on);
	return true;
}

/** The room-shaped operations of one durable runtime, bound once to its live
 * directory inventory and the operator authority that can recover management. */
export class DurableRoomActions {
	constructor(
		readonly directories: ReadonlyMap<string, LiveDirectory>,
		readonly issueManager: (directoryId: string, identity: string) => Promise<string>,
	) {}

	openManaged(directoryId: string, label: string, recoveryKey: string, policy: RoomPolicy) {
		return openManagedRoom(this.directories, directoryId, label, recoveryKey, policy);
	}

	ensureLink(conversationId: string) {
		return ensureRoomLink(this.directories, conversationId);
	}

	bridgeForm(conversationId: string) {
		return roomBridgeForm(this.directories, conversationId);
	}

	takeModerator(conversationId: string, stewardLink: string | null) {
		return takeRoomModerator(this.directories, conversationId, stewardLink);
	}

	takeManager(conversationId: string, managerLink: string) {
		return takeRoomManager(this.directories, conversationId, managerLink);
	}

	recoverManager(conversationId: string) {
		return recoverRoomManager(this.directories, conversationId, this.issueManager);
	}

	assertManagerRecoverable(conversationId: string): void {
		assertRoomManagerRecoverable(this.directories, conversationId);
	}

	revokeAuthority(conversationId: string, kind: "room" | "steward", token: string) {
		return revokeManagedRoomAuthority(this.directories, conversationId, kind, token);
	}

	unregister(conversationId: string) {
		return unregisterManagedRoom(this.directories, conversationId);
	}

	setPolicy(conversationId: string, name: string, policy: RoomPolicy) {
		return setManagedRoomPolicy(this.directories, conversationId, name, policy);
	}

	setTopic(conversationId: string, text: string) {
		return setRoomTopic(this.directories, conversationId, text);
	}

	kick(conversationId: string, nick: string) {
		return kickRoomMember(this.directories, conversationId, nick);
	}

	offer(
		reconciliation: Promise<void>,
		roomConversationId: string,
		directConversationId: string,
		label: string,
		link: string | null,
		realizeDirect: RealizeDirect,
	) {
		return offerRoom(
			this.directories,
			reconciliation,
			roomConversationId,
			directConversationId,
			label,
			link,
			realizeDirect,
		);
	}

	setTyping(conversationId: string, on: boolean): boolean {
		return setRoomTyping(this.directories, conversationId, on);
	}
}
