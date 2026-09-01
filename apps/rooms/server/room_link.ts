// Durable room entrances: reconstruct the live room lazily, without making
// the published capability retain an empty membership aggregate.

import { type Argument, type Behavior, currentSession, type Session } from "@pancake/runtime";
import { NO_SUCH_ROOM, RoomError } from "../lib/errors.ts";
import { isManagedRoomId } from "../lib/limits.ts";
import { OPEN_ROOM_POLICY, PRIVATE_ROOM_POLICY } from "../lib/room/policy.ts";
import { CALLED, PRIVATE, ROOM_POLICY, SUBSCRIBE } from "../lib/protocol.ts";
import { hasCapabilityArguments, throwAfterReleasingCapabilities } from "../lib/argument_custody.ts";
import type { RoomHistory } from "./history.ts";
import type { RoomServerContext } from "./context.ts";
import { findBySession, roomKey } from "./registry.ts";
import { roomBehavior } from "./room.ts";
import type { RoomLinks } from "./room_links.ts";
import type { RoomMembershipKind } from "../lib/room/membership.ts";

/** A durable entrance is stable across sessions while membership stays live.
 * It rebuilds an empty room only when its first subscriber arrives. */
export function linkedRoomBehavior(
	ctx: RoomServerContext,
	durable: string,
	roomLinks: () => RoomLinks,
	history: RoomHistory,
	options: {
		active?: () => boolean;
		sessionFor?: () => Session | null;
		membershipKind?: RoomMembershipKind;
	} = {},
): Behavior {
	const active = options.active ?? (() => true);
	const sessionFor = options.sessionFor ?? currentSession;
	const membershipKind = options.membershipKind ?? "participant";
	const opaque = isManagedRoomId(durable);
	const key = opaque ? durable : roomKey(durable);
	return (verb, args) => {
		const session = sessionFor();
		if (session == null) throw new Error("a room link is reachable only over a session");
		let state = ctx.live.rooms.get(key);
		if (!active() && (state == null || findBySession(state, session) == null)) {
			throwAfterReleasingCapabilities(
				session,
				args,
				new RoomError(NO_SUCH_ROOM, "this room link was revoked"),
			);
		}
		if (verb !== SUBSCRIBE && hasCapabilityArguments(args)) {
			throwAfterReleasingCapabilities(
				session,
				args,
				new Error(`room ${verb} does not take capability arguments`),
			);
		}
		if (state === undefined) {
			const managed = roomLinks().managedRoom(durable);
			if (verb === CALLED) {
				if (args.length !== 0) throw new Error("called takes no arguments");
				return managed?.name ?? (opaque ? "" : durable);
			}
			if (verb === PRIVATE) {
				if (args.length !== 0) throw new Error("private takes no arguments");
				return managed?.policy.visibility === "secret" || (managed == null && opaque) ? "private" : "listed";
			}
			if (verb === ROOM_POLICY) {
				if (args.length !== 0) throw new Error("roomPolicy takes no arguments");
				const policy = managed?.policy ?? (opaque ? PRIVATE_ROOM_POLICY : OPEN_ROOM_POLICY);
				return [policy.visibility, policy.entry, policy.speaking] as Argument;
			}
			if (verb !== SUBSCRIBE) throw new Error("subscribe to this room before using it");
			state = ctx.live.makeRoomState(managed?.name ?? (opaque ? "" : durable), session, {
				policy: managed?.policy ?? (opaque ? PRIVATE_ROOM_POLICY : OPEN_ROOM_POLICY),
				key,
				topic: roomLinks().topic(durable) ?? "",
			});
			ctx.live.registerRoom(state);
			try {
				return roomBehavior(ctx, state, history, roomLinks(), { membershipKind })(verb, args);
			} catch (error) {
				if (state.members.length === 0) ctx.live.forgetRoom(state);
				throw error;
			}
		}
		return roomBehavior(ctx, state, history, roomLinks(), { membershipKind })(verb, args);
	};
}
