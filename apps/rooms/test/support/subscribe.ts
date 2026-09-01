// Subscribe, watch, and wait helpers the rooms server tests share.

import { Ref } from "@pancake/runtime";
import type { Argument, Session } from "@pancake/runtime";
import {
	DIRECTORY,
	ENTER,
	LIST_PUBLICATIONS,
	NOTIFY,
	OPEN,
	REGISTER,
	SUBSCRIBE,
	WATCH_PUBLICATIONS,
} from "../../lib/protocol.ts";
import { NO_SUCH_ROOM, ROOM_EXISTS, type RoomErrorCode, roomErrorOf } from "../../lib/errors.ts";
import { type Message, Room } from "../../lib/room/client.ts";
import { loopbackTcpDesignator } from "../../lib/locator.ts";
import { assert, delay, dial } from "./rooms_server.ts";

export async function subscribeMembership(
	session: Session,
	room: Ref,
	nick: string,
	inbox: Ref,
): Promise<Ref> {
	const answer = await session.send(room, SUBSCRIBE, [nick, inbox]);
	assert(Array.isArray(answer) && answer[0] instanceof Ref, "subscribe did not answer a membership capability");
	return answer[0];
}

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
): Promise<readonly string[]> {
	session.serve().catch(() => {});
	const roomRef = await enterOrOpen(session, room);
	// The roster arrives as a `notify`, not as the subscribe return. Listed-ness
	// may precede it; this helper waits for the roster tag specifically.
	//
	// It reads the names the room sends beside the line rather than the line
	// itself. That is what those names are for, and a test that read the
	// sentence was a client parsing prose: it made the room's copy part of the
	// contract, so a clearer word for one reader broke a proof about seating.
	let resolveWelcome!: (w: readonly string[]) => void;
	const welcome = new Promise<readonly string[]>((r) => (resolveWelcome = r));
	const inbox = session.spawn((verb, args) => {
		if (verb === NOTIFY && args[2] === "roster") {
			resolveWelcome(args.slice(3).filter((name): name is string => typeof name === "string"));
		}
		return null;
	});
	await subscribeMembership(session, roomRef, nick, inbox);
	const names = await welcome;
	session.close();
	await session.serve().catch(() => {});
	return names;
}

export async function subscribeOnce(
	port: number,
	room: string,
	nick: string,
): Promise<readonly string[]> {
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
): Promise<readonly string[]> {
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
		await subscribeMembership(session, roomRef, nick, inbox);
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
	await subscribeMembership(session, roomRef, "first-a", inbox);
	await subscribeMembership(session, roomRef, "first-b", inbox);
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
	await subscribeMembership(session, roomRef, "first-a", inbox);
	await subscribeMembership(session, roomRef, "first-b", inbox);
	return {
		leave: async () => {
			session.close();
			await session.serve().catch(() => {});
		},
	};
}

/** Whether a room seated exactly these names, in the order it sent them. One
 * comparison, so the waiting form and the asserting form cannot come to differ
 * about what a matching roster is. */
function sameRoster(names: readonly string[], want: readonly string[]): boolean {
	return names.length === want.length && names.every((name, at) => name === want[at]);
}

/** Assert a room seated exactly these names. */
export function assertRoster(names: readonly string[], want: readonly string[]): void {
	if (!sameRoster(names, want)) {
		throw new Error(`expected the roster ${JSON.stringify(names)} to be ${JSON.stringify(want)}`);
	}
}

/** Wait until a room seats exactly these names.
 *
 * The roster's own sibling of `waitForMatch`, because a room frees a name a
 * moment after the connection holding it closes, so the next dialer's first
 * try can still be refused it. */
export async function waitForRoster(
	getNames: () => Promise<readonly string[]>,
	want: readonly string[],
): Promise<readonly string[]> {
	const deadline = Date.now() + 2_000;
	let last: readonly string[] = [];
	while (Date.now() < deadline) {
		last = await getNames();
		if (sameRoster(last, want)) return last;
		await delay(25);
	}
	throw new Error(`expected the roster ${JSON.stringify(last)} to be ${JSON.stringify(want)}`);
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
	await subscribeMembership(session, roomRef, nick, inbox);
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

export interface DirectoryRoomRecord {
	name: string;
	count: number | null;
	id: string;
	kind: "local" | "foreign";
	origin: string;
	proof: "local" | "authenticated" | "session";
	offers: "observer" | "participant" | null;
}

export type DirectoryWatchEvent =
	| { event: "opened" | "closed" | "count"; room: DirectoryRoomRecord }
	| { event: "registered" | "unregistered"; name: string; registrationId: string; count: number }
	| { event: "truncated"; count: number };

function directoryRoomRecord(raw: unknown): DirectoryRoomRecord {
	assert(Array.isArray(raw) && raw.length === 7, "directory room record must have seven fields");
	const [name, countRaw, id, kind, origin, proof, offers] = raw;
	assert(typeof name === "string" && name.length > 0, "directory room record must name a room");
	assert(
		countRaw === null || typeof countRaw === "number" || typeof countRaw === "bigint",
		"directory room count must be natural or null",
	);
	const count = countRaw === null ? null : Number(countRaw);
	assert(
		count === null || (Number.isSafeInteger(count) && count >= 0),
		"directory room count must be natural or null",
	);
	assert(typeof id === "string" && id.length > 0, "directory room record must name its publication");
	assert(kind === "local" || kind === "foreign", "directory room record has invalid kind");
	assert(typeof origin === "string", "directory room record has invalid origin");
	assert(
		proof === "local" || proof === "authenticated" || proof === "session",
		"directory room record has invalid proof",
	);
	assert(
		kind !== "local" || (count !== null && origin === "" && proof === "local"),
		"local room record has foreign provenance",
	);
	assert(
		kind !== "foreign" || (count === null && origin.length > 0 && proof !== "local"),
		"foreign room record has local provenance",
	);
	assert(offers === null || offers === "observer" || offers === "participant", "invalid public membership offer");
	return { name, count, id, kind, origin, proof, offers };
}

/** Decode the directory's canonical room-publication snapshot. */
export async function listRooms(session: Session): Promise<DirectoryRoomRecord[]> {
	const directory = await session.fetch(DIRECTORY);
	const raw = await session.send(directory, LIST_PUBLICATIONS, []) as unknown[];
	return raw.map(directoryRoomRecord);
}

export function recordDirectoryEvent(events: DirectoryWatchEvent[], args: Argument[]): void {
	const event = args[0];
	if (event === "truncated") {
		const count = Number(args[1]);
		assert(args.length === 2 && Number.isSafeInteger(count) && count >= 0, "invalid truncation event");
		events.push({ event, count });
		return;
	}
	if (event === "opened" || event === "closed" || event === "count") {
		events.push({ event, room: directoryRoomRecord(args.slice(1)) });
		return;
	}
	assert(event === "registered" || event === "unregistered", "directory watcher received an invalid event");
	assert(
		args.length === 4 && typeof args[1] === "string" && typeof args[3] === "string",
		"directory member event has invalid fields",
	);
	const count = Number(args[2]);
	assert(Number.isSafeInteger(count) && count >= 0, "directory member event has invalid count");
	events.push({ event, name: args[1], registrationId: args[3], count });
}

/** Register a directory watcher and retain its complete deltas and snapshot. */
export async function watchDirectory(session: Session): Promise<{
	events: DirectoryWatchEvent[];
	snapshot: DirectoryRoomRecord[];
}> {
	session.serve().catch(() => {});
	const directory = await session.fetch(DIRECTORY);
	const events: DirectoryWatchEvent[] = [];
	const observer = session.spawn((_verb, args) => {
		recordDirectoryEvent(events, args);
		return null;
	});
	const raw = await session.send(directory, WATCH_PUBLICATIONS, [observer]) as unknown[];
	assert(raw.length === 3 && Array.isArray(raw[0]) && Array.isArray(raw[1]), "invalid directory watch snapshot");
	for (const row of raw[1]) {
		assert(
			Array.isArray(row) && row.length === 2 && typeof row[0] === "string" && typeof row[1] === "string",
			"invalid directory member snapshot row",
		);
		events.push({ event: "registered", name: row[0], registrationId: row[1], count: 1 });
	}
	const omitted = Number(raw[2]);
	if (omitted > 0) events.push({ event: "truncated", count: omitted });
	return {
		events,
		snapshot: raw[0].map(directoryRoomRecord),
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
): Promise<{ askedFor: string[]; introducible: string[]; registrationId: string }> {
	const askedFor: string[] = [];
	const introducible: string[] = [];
	let acked = false;
	let claim = "";
	const inbox = session.spawn((verb, args) => {
		if (verb !== NOTIFY) return null;
		const peer = typeof args[1] === "string" ? args[1] : "";
		if (args[0] === "registered" && typeof args[2] === "string") {
			claim = args[2];
			acked = true;
		}
		if (args[0] === "mintInboxFor" && peer) askedFor.push(peer);
		if (args[0] === "introducible" && peer) introducible.push(peer);
		return null;
	});
	await session.send(directory, REGISTER, [nick, locator, inbox]);
	const deadline = Date.now() + 3_000;
	while (!acked && Date.now() < deadline) await delay(25);
	assert(acked, `${nick} should be registered`);
	return { askedFor, introducible, registrationId: claim };
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
