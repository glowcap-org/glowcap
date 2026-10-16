// What an entrance reference answers before anybody subscribes through it:
// what the room is called, whether it is listed, its policy, and its durable
// link. A room link enlivens to one of these, so a page can describe a room
// before joining it.

import type { Ref, Session } from "@glowcap/runtime";
import { CALLED, PRIVATE, ROOM_POLICY } from "../protocol.ts";
import { ask } from "../ask.ts";
import { parseRoomPolicy, type RoomPolicy } from "./policy.ts";
import { RoomStewardship } from "./stewardship.ts";

/** What a room calls itself, asked of an entrance reference, including one
 * just enlivened from a link before subscribe. Empty when it has no label to
 * give. */
export async function roomCalledAs(session: Session, room: Ref): Promise<string> {
	const said = await ask(session, room, CALLED, [], "the room did not say what it is called");
	return typeof said === "string" ? said : "";
}

/** Create or recover a durable link from a raw room capability without joining it. */
export async function linkRoomReference(session: Session, room: Ref): Promise<string> {
	return await new RoomStewardship(session, room).link();
}

/** Whether an entrance reference names an unlisted room. A public room's link
 * is still that public room. Guessing from the name would open a listed room
 * that shares a private room's label. */
export async function roomIsPrivate(session: Session, room: Ref): Promise<boolean> {
	const said = await ask(session, room, PRIVATE, [], "the room did not say whether it is listed");
	if (said === true || said === "private") return true;
	if (said === false || said === "" || said === "listed") return false;
	throw new Error("the room did not say whether it is listed");
}

export async function roomPolicy(session: Session, room: Ref): Promise<RoomPolicy> {
	const answer = await ask(session, room, ROOM_POLICY, [], "the room did not answer its policy");
	const policy = parseRoomPolicy(answer);
	if (policy === null) throw new Error("the room answered an invalid policy");
	return policy;
}
