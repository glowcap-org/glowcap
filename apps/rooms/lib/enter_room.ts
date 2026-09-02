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

import { Directory, Room } from "./room/client.ts";
import type { Ref } from "@glowcap/runtime";
import { NO_ROOM_MANAGERS, NO_SUCH_ROOM, ROOM_EXISTS } from "./errors.ts";
import { roomErrorOf } from "./errors.ts";
import { dialDirectory, type RoomsRuntime } from "./locator.ts";

/** Get a reference to `name` on `dir`, opening the room if it does not exist
 * yet. Composes the directory's strict `enter`/`open`; the leniency is here. */
export async function enterOrOpen(dir: Directory, name: string): Promise<Ref> {
	return (await enterOrOpenResult(dir, name)).ref;
}

/** The same friendly lookup, returning newly created room and manager links
 * only to the caller whose managed open succeeded. Losing an `open` race is
 * an ordinary entry and conveys no management authority. */
export async function enterOrOpenResult(
	dir: Directory,
	name: string,
): Promise<{ ref: Ref; opened: boolean; roomLink?: string; managerLink?: string }> {
	try {
		return { ref: await dir.enter(name), opened: false };
	} catch (err) {
		if (roomErrorOf(err)?.code !== NO_SUCH_ROOM) throw err;
	}
	try {
		const managed = await dir.openManaged(name);
		return { ref: managed.room, opened: true, roomLink: managed.roomLink, managerLink: managed.managerLink };
	} catch (err) {
		const code = roomErrorOf(err)?.code;
		// A directory that publishes no room managers still opens rooms; it just
		// has no authority to hand back, which is why the links above are
		// optional. Asking for the managed open first and falling back keeps the
		// authority wherever it exists without making it a condition of entry.
		// The plain open races the same way the managed one does, so it loses
		// the same way: somebody else's room is one to enter, not an error.
		if (code === NO_ROOM_MANAGERS) {
			try {
				return { ref: await dir.open(name), opened: true };
			} catch (raced) {
				if (roomErrorOf(raced)?.code !== ROOM_EXISTS) throw raced;
				return { ref: await dir.enter(name), opened: false };
			}
		}
		if (code !== ROOM_EXISTS) throw err;
		return { ref: await dir.enter(name), opened: false }; // lost the race; the room is there now
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
	runtime: RoomsRuntime,
): Promise<{ dir: Directory; room: Room }> {
	const dir = await Directory.connect(locator, (address) => dialDirectory(address, runtime));
	const reached = await enterOrOpenResult(dir, room);
	const joined = await Room.subscribe(dir.session, reached.ref, nick);
	if (reached.managerLink != null) await joined.takeManager(reached.managerLink);
	return { dir, room: joined };
}
