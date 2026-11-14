// Read a room's stream until one message matches.

import type { Message, Room } from "../../lib/room/client.ts";

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
