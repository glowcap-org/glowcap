// Subscribe, watch, and wait helpers the rooms server tests share.

import { Ref } from "@pancake/runtime";
import type { Session } from "@pancake/runtime";
import { DIRECTORY, ENTER, LIST, NOTIFY, OPEN, REGISTER, SUBSCRIBE, WATCH } from "../../lib/protocol.ts";
import { NO_SUCH_ROOM, ROOM_EXISTS, type RoomErrorCode, roomErrorOf } from "../../lib/errors.ts";
import { type Message, Room } from "../../lib/room_client.ts";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { assert, delay, dial } from "./rooms_server.ts";

/** Enter the named room over `session`, opening it if it does not exist, the
 * directory dance every client does, inlined here so the tests drive the same
 * wire the clients do. */
export async function enterOrOpen(session: Session, room: string): Promise<Ref> {
	const directory = await session.fetch(DIRECTORY);
	try {
		return await session.send(directory, ENTER, [room]) as Ref;
	} catch (err) {
		if (roomErrorOf(err)?.code !== NO_SUCH_ROOM) throw err;
	}
	try {
		return await session.send(directory, OPEN, [room]) as Ref;
	} catch (err) {
		if (roomErrorOf(err)?.code !== ROOM_EXISTS) throw err;
		return await session.send(directory, ENTER, [room]) as Ref;
	}
}

/** Subscribe one member to a room over an already-dialed connection, return its
 * welcome, and close. The transport (TCP or iroh) is whatever the connection
 * rides. */
export async function subscribeOnceConn(
	session: Session,
	room: string,
	nick: string,
): Promise<string> {
	session.serve().catch(() => {});
	const roomRef = await enterOrOpen(session, room);
	// The welcome + roster arrive as the first `notify` (a "roster" line), not as the
	// subscribe return, so capture it off the inbox.
	let resolveWelcome!: (w: string) => void;
	const welcome = new Promise<string>((r) => (resolveWelcome = r));
	const inbox = session.spawn((verb, args) => {
		if (verb === NOTIFY && args[2] === "roster" && typeof args[1] === "string") {
			resolveWelcome(args[1]);
		}
		return null;
	});
	await session.send(roomRef, SUBSCRIBE, [nick, inbox]);
	const text = await welcome;
	session.close();
	await session.serve().catch(() => {});
	return text;
}

export async function subscribeOnce(
	port: number,
	room: string,
	nick: string,
): Promise<string> {
	return subscribeOnceConn(
		await dial(loopbackTcpDesignator(port)),
		room,
		nick,
	);
}

export async function subscribeOnceIroh(
	uri: string,
	room: string,
	nick: string,
): Promise<string> {
	return subscribeOnceConn(await dial(uri), room, nick);
}

export async function trySubscribe(port: number, room: string, nick: string): Promise<{
	ok: boolean;
	code?: RoomErrorCode | null;
	leave: () => Promise<void>;
}> {
	const session = await dial(loopbackTcpDesignator(port));
	session.serve().catch(() => {});
	try {
		const roomRef = await enterOrOpen(session, room);
		const inbox = session.spawn(() => null);
		await session.send(roomRef, SUBSCRIBE, [nick, inbox]);
		return {
			ok: true,
			leave: async () => {
				session.close();
				await session.serve().catch(() => {});
			},
		};
	} catch (err) {
		session.close();
		await session.serve().catch(() => {});
		return {
			ok: false,
			code: roomErrorOf(err)?.code ?? null,
			leave: async () => {},
		};
	}
}

export async function subscribeTwiceAndClose(
	port: number,
	room: string,
): Promise<void> {
	const session = await dial(loopbackTcpDesignator(port));
	session.serve().catch(() => {});
	const roomRef = await enterOrOpen(session, room);
	const inbox = session.spawn(() => null);
	await session.send(roomRef, SUBSCRIBE, ["first-a", inbox]);
	await session.send(roomRef, SUBSCRIBE, ["first-b", inbox]);
	session.close();
	await session.serve().catch(() => {});
}

export async function resubscribeAndHold(port: number, room: string): Promise<{
	leave: () => Promise<void>;
}> {
	const session = await dial(loopbackTcpDesignator(port));
	session.serve().catch(() => {});
	const roomRef = await enterOrOpen(session, room);
	const inbox = session.spawn(() => null);
	await session.send(roomRef, SUBSCRIBE, ["first-a", inbox]);
	await session.send(roomRef, SUBSCRIBE, ["first-b", inbox]);
	return {
		leave: async () => {
			session.close();
			await session.serve().catch(() => {});
		},
	};
}

export async function waitForMatch(
	getValue: () => Promise<string>,
	pattern: RegExp,
): Promise<string> {
	const deadline = Date.now() + 2_000;
	let last = "";
	while (Date.now() < deadline) {
		last = await getValue();
		if (pattern.test(last)) return last;
		await delay(25);
	}
	throw new Error(`expected ${JSON.stringify(last)} to match ${pattern}`);
}

export async function watchRoomConn(
	session: Session,
	room: string,
	nick: string,
): Promise<{
	lines: string[];
	leave: () => Promise<void>;
}> {
	session.serve().catch(() => {});
	const lines: string[] = [];
	const roomRef = await enterOrOpen(session, room);
	const inbox = session.spawn((_verb, args) => {
		const from = typeof args[0] === "string" ? args[0] : "?";
		const text = typeof args[1] === "string" ? args[1] : "";
		lines.push(`${from}: ${text}`);
		return null;
	});
	await session.send(roomRef, SUBSCRIBE, [nick, inbox]);
	return {
		lines,
		leave: async () => {
			session.close();
			await session.serve().catch(() => {});
		},
	};
}

export async function watchRoom(port: number, room: string, nick: string) {
	return watchRoomConn(
		await dial(loopbackTcpDesignator(port)),
		room,
		nick,
	);
}

export async function watchRoomIroh(uri: string, room: string, nick: string) {
	return watchRoomConn(await dial(uri), room, nick);
}

export async function waitForLine(lines: string[], pattern: RegExp): Promise<string> {
	const deadline = Date.now() + 2_000;
	while (Date.now() < deadline) {
		const found = lines.find((line) => pattern.test(line));
		if (found) return found;
		await delay(25);
	}
	throw new Error(`expected ${JSON.stringify(lines)} to contain ${pattern}`);
}

/** Accumulate a `Room`'s lines into the same `string[]` shape `watchRoomConn`
 * hands back, so a test holding the client class reads them with the same
 * `waitForLine` vocabulary as one holding a raw inbox.
 *
 * Start it before the line you are waiting for can arrive. The stream queues
 * what it is given, so attaching at subscribe time cannot miss the welcome, but
 * attaching after one is already delivered can. */
export function roomLines(room: Room): string[] {
	const lines: string[] = [];
	void (async () => {
		try {
			for await (const message of room.messages) lines.push(`${message.from}: ${message.text}`);
		} catch {
			// The stream ends with the membership, so a read that rejects while the
			// room is being left is the ordinary end of this pump, not a failure.
		}
	})();
	return lines;
}

export async function until(
	condition: () => boolean,
	message: string,
	timeoutMs = 3_000,
): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!condition()) {
		if (Date.now() >= deadline) throw new Error(message);
		await delay(10);
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

/** The directory's live room list as `[name, count]` pairs (counts arrive as
 * bigint), over an already-serving connection. */
export async function listRooms(session: Session): Promise<Array<[string, number]>> {
	const directory = await session.fetch(DIRECTORY);
	const raw = await session.send(directory, LIST, []) as unknown[];
	return raw.map((pair) => {
		const p = pair as unknown[];
		return [String(p[0]), Number(p[1])];
	});
}

/** Register a directory watcher over `session` and collect its `notify(event, name,
 * count)` deltas as `"event name count"` strings, returning the baseline
 * snapshot too. */
export async function watchDirectory(session: Session): Promise<{
	events: string[];
	snapshot: Array<[string, number]>;
}> {
	session.serve().catch(() => {});
	const directory = await session.fetch(DIRECTORY);
	const events: string[] = [];
	const observer = session.spawn((_verb, args) => {
		events.push(`${args[0]} ${args[1]} ${Number(args[2])}`);
		return null;
	});
	const raw = await session.send(directory, WATCH, [observer]) as unknown[];
	return {
		events,
		snapshot: raw.map((pair) => {
			const p = pair as unknown[];
			return [String(p[0]), Number(p[1])];
		}),
	};
}

/** Register `nick` and wait for the directory's ack, returning the reg-inbox
 * observations a DM test cares about: who the directory asked us to mint for, and
 * which peers it said were introducible. */
export async function registerAndWatch(
	session: Session,
	directory: Ref,
	nick: string,
	locator: string,
): Promise<{ askedFor: string[]; introducible: string[] }> {
	const askedFor: string[] = [];
	const introducible: string[] = [];
	let acked = false;
	const inbox = session.spawn((verb, args) => {
		if (verb !== NOTIFY) return null;
		const peer = typeof args[1] === "string" ? args[1] : "";
		if (args[0] === "registered") acked = true;
		if (args[0] === "mintInboxFor" && peer) askedFor.push(peer);
		if (args[0] === "introducible" && peer) introducible.push(peer);
		return null;
	});
	await session.send(directory, REGISTER, [nick, locator, inbox]);
	const deadline = Date.now() + 3_000;
	while (!acked && Date.now() < deadline) await delay(25);
	assert(acked, `${nick} should be registered`);
	return { askedFor, introducible };
}

/** The room code a verb refused with, or null when it did not refuse. */
export async function refusalCode(send: () => Promise<unknown>): Promise<string | null> {
	try {
		await send();
		return null;
	} catch (err) {
		return roomErrorOf(err)?.code ?? "untyped";
	}
}
