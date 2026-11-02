// The two directory-and-room moves a rooms test makes over a raw session:
// enter or open a room the way every client does, and read its stream until
// one message matches.

import { Ref } from "@glowcap/runtime";
import type { Session } from "@glowcap/runtime";
import { DIRECTORY, ENTER, OPEN } from "../../lib/protocol.ts";
import { NO_SUCH_ROOM, ROOM_EXISTS, roomsErrorOf } from "../../lib/errors.ts";
import type { Message, Room } from "../../lib/room/client.ts";

/** Enter the named room over `session`, opening it if it does not exist, the
 * directory dance every client does, inlined here so the tests drive the same
 * wire the clients do. */
export async function enterOrOpen(session: Session, room: string): Promise<Ref> {
	const directory = await session.fetch(DIRECTORY);
	try {
		return await session.send(directory, ENTER, [room]) as Ref;
	} catch (err) {
		if (roomsErrorOf(err)?.code !== NO_SUCH_ROOM) throw err;
	}
	try {
		return await session.send(directory, OPEN, [room]) as Ref;
	} catch (err) {
		if (roomsErrorOf(err)?.code !== ROOM_EXISTS) throw err;
		return await session.send(directory, ENTER, [room]) as Ref;
	}
}

/** Pull messages from a room's stream until one matches, reading past the
 * welcome and roster a subscribe always delivers first. Bounded so a test that
 * awaits a message the room never sends fails rather than hangs. */
export async function nextMessage(room: Room, match: (message: Message) => boolean): Promise<Message> {
	const reader = room.messages.getReader();
	// Bounded in time as well as in count: a read blocks until the room speaks, so
	// a regression that stops sending the awaited message would hang here rather
	// than fail. The timeout turns that into a clean failure the way the count
	// bound does for a room that speaks the wrong thing forever.
	let timer: ReturnType<typeof setTimeout> | undefined;
	const deadline = new Promise<never>((_, reject) => {
		timer = setTimeout(() => reject(new Error("the awaited message never arrived")), 5000);
	});
	try {
		for (let i = 0; i < 50; i += 1) {
			const { done, value } = await Promise.race([reader.read(), deadline]);
			if (done) throw new Error("the room stream ended before the awaited message");
			if (match(value)) return value;
		}
		throw new Error("the awaited message never arrived");
	} finally {
		clearTimeout(timer);
		reader.releaseLock();
	}
}
