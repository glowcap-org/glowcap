// Passable authority over one room's durable link and moderator generations.

import { type Argument, type Behavior, currentSession, type Session } from "@glowcap/runtime";
import { releaseUnclaimedCapabilityArguments } from "../lib/argument_custody.ts";
import { GOVERNS, LINK, MANAGED_ROOM_IDENTITY, ROOM_AUTHORITIES } from "../lib/protocol.ts";
import {
	GIVE_STEWARD,
	REVOKE_ROOM_LINK,
	REVOKE_STEWARD,
	SET_ROOM_POLICY,
	UNREGISTER_ROOM,
} from "../lib/protocol_operator.ts";
import type { RoomLinks } from "./room_links.ts";
import { isRoomEntry, isRoomPolicy, isRoomSpeaking, isRoomVisibility, type RoomPolicy } from "../lib/room/policy.ts";

/** A manager retains only a durable room name and the bounded authority store.
 * It never captures RoomState, so possessing it cannot keep an empty room live. */
export function roomManagerBehavior(
	name: string,
	links: () => RoomLinks,
	active: () => boolean,
	sessionFor: () => Session | null = currentSession,
): Behavior {
	return (verb, args) => {
		const arriving = sessionFor();
		if (arriving === null) throw new Error("a room manager call has no arriving session");
		const session: Session = arriving;
		releaseUnclaimedCapabilityArguments(session, args, "a room manager accepts no capability arguments");
		if (!active()) throw new Error("this room manager capability was revoked");
		if (verb === MANAGED_ROOM_IDENTITY || verb === GOVERNS) {
			if (args.length !== 0) throw new Error(`${verb} takes no arguments`);
			return links().managerIdentity(name) as ReturnType<Behavior>;
		}
		if (verb === LINK) {
			if (args.length !== 0) throw new Error("link takes no arguments");
			return links().link(name, session) as ReturnType<Behavior>;
		}
		if (verb === GIVE_STEWARD) {
			if (args.length !== 0) throw new Error("giveSteward takes no arguments");
			return links().steward(name, session).then((grant) =>
				[grant.room, grant.identity, grant.steward] as Argument
			) as ReturnType<Behavior>;
		}
		if (verb === REVOKE_STEWARD || verb === REVOKE_ROOM_LINK) {
			if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
				throw new Error(`${verb} takes one exact authority token`);
			}
			const token = args[0] as string;
			return links().revokeAuthority(verb === REVOKE_STEWARD ? "steward" : "room", token).then(() =>
				null
			) as ReturnType<Behavior>;
		}
		if (verb === UNREGISTER_ROOM) {
			if (args.length !== 1 || typeof args[0] !== "string" || args[0] === "") {
				throw new Error("unregisterRoom takes this manager's exact authority token");
			}
			return links().unregisterRoom(args[0]).then((room) =>
				[room.name, room.policy.visibility, room.policy.entry, room.policy.speaking] as Argument
			) as ReturnType<Behavior>;
		}
		if (verb === SET_ROOM_POLICY) {
			if (
				args.length !== 5 || typeof args[0] !== "string" || args[0] === "" ||
				!isRoomVisibility(args[1]) || !isRoomEntry(args[2]) || !isRoomSpeaking(args[3]) ||
				typeof args[4] !== "string" || args[4] === ""
			) throw new Error("setRoomPolicy takes this manager's token, three policy modes, and a room name");
			const candidate = { visibility: args[1], entry: args[2], speaking: args[3] };
			if (!isRoomPolicy(candidate)) throw new Error("setRoomPolicy names no supported room access state");
			const policy: RoomPolicy = candidate;
			return links().setPolicy(args[0], policy, args[4]).then((room) =>
				[
					room.name,
					room.policy.visibility,
					room.policy.entry,
					room.policy.speaking,
				] as Argument
			) as ReturnType<Behavior>;
		}
		throw new Error(`a room manager has no method ${verb}`);
	};
}

/** Creation authority is a live, passable bootstrap capability, not the
 * opener's session identity. Repeated asks share one idempotent durable issue;
 * the client releases this bootstrap after retaining the returned manager. */
export function roomManagerBootstrapBehavior(
	name: string,
	links: RoomLinks,
	managed?: { policy: RoomPolicy; name: string },
): Behavior {
	return (verb, args) => {
		const session = currentSession();
		if (session === null) throw new Error("a room manager bootstrap call has no arriving session");
		releaseUnclaimedCapabilityArguments(session, args, "room manager bootstrap accepts no capability arguments");
		if (verb !== ROOM_AUTHORITIES || args.length !== 0) {
			throw new Error(`a room manager bootstrap has no method ${verb}`);
		}
		return links.manager(name, session, undefined, managed).then((grant) =>
			[grant.room, grant.manager] as Argument
		) as ReturnType<
			Behavior
		>;
	};
}
