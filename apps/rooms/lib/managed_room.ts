// Two-stage managed-room creation and its capability-occurrence custody.

import { Ref, retainCleanupFailures, type Session } from "@glowcap/runtime";
import { ask } from "./ask.ts";
import { parseRoomsSturdyref } from "./locator.ts";
import { isManagedRoomId, newManagedRoomId } from "./limits.ts";
import { OPEN_MANAGED, ROOM_AUTHORITIES } from "./protocol.ts";
import { OPEN_ROOM_POLICY, type RoomPolicy } from "./room/policy.ts";

export interface ManagedRoomAnswer {
	room: Ref;
	roomLink: string;
	managerLink: string;
}

export async function openManagedRoom(
	session: Session,
	directory: Ref,
	name: string,
	options: { policy?: RoomPolicy; roomId?: string } = {},
): Promise<ManagedRoomAnswer> {
	const policy = options.policy ?? OPEN_ROOM_POLICY;
	const roomId = options.roomId ?? newManagedRoomId();
	if (!isManagedRoomId(roomId)) {
		throw new Error("a managed room id is invalid");
	}
	const answer = await ask(
		session,
		directory,
		OPEN_MANAGED,
		[name, policy.visibility, policy.entry, policy.speaking, roomId],
		`the directory did not answer opening managed room "${name}"`,
	);
	if (!Array.isArray(answer) || answer.length !== 2 || !(answer[0] instanceof Ref) || !(answer[1] instanceof Ref)) {
		throw new Error("the directory answered managed room creation without room and bootstrap capabilities");
	}
	const room = answer[0];
	const bootstrap = answer[1];
	let authority: unknown;
	try {
		authority = await ask(
			session,
			bootstrap,
			ROOM_AUTHORITIES,
			[],
			"the room manager bootstrap did not answer its authorities",
		);
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.release(bootstrap), () => session.release(room)]);
	}
	if (
		!Array.isArray(authority) || authority.length !== 2 || typeof authority[0] !== "string" ||
		authority[0] === "" || typeof authority[1] !== "string" || authority[1] === ""
	) {
		const error = new Error("the room manager bootstrap answered incomplete authority");
		throw await retainCleanupFailures(error, [() => session.release(bootstrap), () => session.release(room)]);
	}
	try {
		if (
			parseRoomsSturdyref(authority[0]).swissnum.length === 0 ||
			parseRoomsSturdyref(authority[1]).swissnum.length === 0
		) throw new Error("the room manager bootstrap answered empty authority");
	} catch (error) {
		throw await retainCleanupFailures(error, [() => session.release(bootstrap), () => session.release(room)]);
	}
	try {
		session.release(bootstrap);
	} catch (error) {
		// A release can fail after consuming its occurrence. Never attempt it a
		// second time; only retire the room that cannot be returned safely.
		throw await retainCleanupFailures(error, [() => session.release(room)]);
	}
	return { room, roomLink: authority[0], managerLink: authority[1] };
}
