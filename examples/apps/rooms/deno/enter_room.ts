// The lenient way into a room — a CLI convenience, not part of the OCapN layer.
//
// The wire and the `Directory` wrapper stay strict: `open` errors if the room
// exists, `enter` errors if it does not. That distinction is the capability
// lesson, and a programmatic caller wants it. But a person at a terminal (or a
// browser tab) just wants to "be in `general`" without first knowing whether
// anyone has opened it. So the apps reach a room through `enterOrOpen`: try
// `enter`, fall back to `open`, and on a creation race fall back to `enter` once
// more. This leniency lives here, in the app layer, on top of the strict
// `Directory` — never inside it.

import { Directory, Room } from "./room_client.ts";
import { type Ref } from "@pancake/stack";

function isMissingRoom(err: unknown): boolean {
	return err instanceof Error && /no room named/.test(err.message);
}

function isRoomExists(err: unknown): boolean {
	return err instanceof Error && /already exists/.test(err.message);
}

/** Get a reference to `name` on `dir`, opening the room if it does not exist
 * yet. Composes the directory's strict `enter`/`open`; the leniency is here. */
export async function enterOrOpen(dir: Directory, name: string): Promise<Ref> {
	try {
		return await dir.enter(name);
	} catch (err) {
		if (!isMissingRoom(err)) throw err;
	}
	try {
		return await dir.open(name);
	} catch (err) {
		if (!isRoomExists(err)) throw err;
		return await dir.enter(name); // lost the race; the room is there now
	}
}

/** The one-call friendly entry for a single-room session: connect, enter the
 * named room (opening it if new), and subscribe as `nick`. Returns the directory
 * too, since it owns the connection, `room.leave()` drops the room and
 * `dir.close()` ends the session. */
export async function joinRoom(
	locator: string,
	room: string,
	nick: string,
): Promise<{ dir: Directory; room: Room }> {
	const dir = await Directory.connect(locator);
	const roomRef = await enterOrOpen(dir, room);
	return { dir, room: await Room.subscribe(dir.conn, roomRef, nick) };
}
