// What an entrance reference answers before anybody subscribes through it:
// its policy. A room link enlivens to one of these, so a page can describe a
// room before joining it.

import type { Ref, Session } from "@glowcap/runtime";
import { ROOM_POLICY } from "../protocol.ts";
import { ask } from "../ask.ts";
import { parseRoomPolicy, type RoomPolicy } from "./policy.ts";

export async function roomPolicy(session: Session, room: Ref): Promise<RoomPolicy> {
	const answer = await ask(session, room, ROOM_POLICY, [], "the room did not answer its policy");
	const policy = parseRoomPolicy(answer);
	if (policy === null) throw new Error("the room answered an invalid policy");
	return policy;
}
