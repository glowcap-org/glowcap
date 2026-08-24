import type { PartnerIdentity, Session } from "@pancake/runtime";
import { ROOM_EXISTS, RoomError, TOO_MANY_PEERED_ROOMS } from "../lib/errors.ts";
import { MAX_PEERED_ROOMS, MAX_PEERED_ROOMS_PER_SOURCE } from "../lib/limits.ts";
import {
	cancelForeignRoom,
	forgetRoom,
	makeRoomState,
	publicRoomById,
	publicRooms,
	registerRoom,
	reserveForeignRoom,
	rooms,
} from "../server/registry.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

function fakeSession(index: number, authenticated = false): Session {
	const sessionKey = new Uint8Array(32);
	new DataView(sessionKey.buffer).setUint32(0, index, true);
	const identity: PartnerIdentity = {
		sessionKey,
		designator: authenticated ? index.toString(16).padStart(64, "0") : `session-${index}`,
		locatorRecord: new Uint8Array(),
		provenance: authenticated ? "authenticated-transport" : "unauthenticated",
	};
	return {
		partnerIdentity: () => identity,
		release: () => {},
	} as unknown as Session;
}

function expectRoomError(action: () => unknown, code: string): void {
	try {
		action();
	} catch (error) {
		assert(error instanceof RoomError, `expected RoomError, got ${error}`);
		assert(error.code === code, `expected ${code}, got ${error.code}`);
		return;
	}
	throw new Error(`expected ${code}`);
}

Deno.test("pending peering reservations occupy the one public namespace without becoming discoverable", () => {
	const source = fakeSession(1);
	const reservation = reserveForeignRoom("Shared", source);
	try {
		assert(publicRoomById(reservation.id) === null, "a pending reservation became enterable");
		assert(!publicRooms.has(reservation.key), "a pending reservation became discoverable");
		expectRoomError(() => reserveForeignRoom("shared", fakeSession(2)), ROOM_EXISTS);

		const local = makeRoomState("SHARED", fakeSession(3));
		expectRoomError(() => registerRoom(local), ROOM_EXISTS);
	} finally {
		cancelForeignRoom(reservation);
	}

	const local = makeRoomState("shared", fakeSession(4));
	registerRoom(local);
	try {
		expectRoomError(() => reserveForeignRoom("Shared", source), ROOM_EXISTS);
	} finally {
		forgetRoom(local);
	}
});

Deno.test("pending peering reservations consume and release the exact per-source quota", () => {
	const source = fakeSession(10);
	const reservations = Array.from(
		{ length: MAX_PEERED_ROOMS_PER_SOURCE },
		(_, index) => reserveForeignRoom(`source-${index}`, source),
	);
	try {
		expectRoomError(
			() => reserveForeignRoom("source-overflow", source),
			TOO_MANY_PEERED_ROOMS,
		);
		assert(cancelForeignRoom(reservations.pop()!), "the last reservation was not live");
		const replacement = reserveForeignRoom("source-replacement", source);
		reservations.push(replacement);
	} finally {
		for (const reservation of reservations) cancelForeignRoom(reservation);
	}
});

Deno.test("pending peering reservations consume and release the exact directory quota", () => {
	const sources = Array.from(
		{ length: Math.ceil(MAX_PEERED_ROOMS / MAX_PEERED_ROOMS_PER_SOURCE) + 1 },
		(_, index) => fakeSession(100 + index),
	);
	const reservations = Array.from(
		{ length: MAX_PEERED_ROOMS },
		(_, index) => reserveForeignRoom(`global-${index}`, sources[Math.floor(index / MAX_PEERED_ROOMS_PER_SOURCE)]),
	);
	try {
		expectRoomError(
			() => reserveForeignRoom("global-overflow", sources.at(-1)!),
			TOO_MANY_PEERED_ROOMS,
		);
		assert(cancelForeignRoom(reservations.pop()!), "the last reservation was not live");
		const replacement = reserveForeignRoom("global-replacement", sources.at(-1)!);
		reservations.push(replacement);
	} finally {
		for (const reservation of reservations) cancelForeignRoom(reservation);
	}
});

Deno.test("peering origin claims only the durable identity proved by the channel", () => {
	const authenticated = fakeSession(7, true);
	const proved = reserveForeignRoom("proved", authenticated);
	try {
		assert(proved.proof === "authenticated", "authenticated transport proof was discarded");
		assert(proved.origin === "0".repeat(63) + "7", "the proved durable designator changed");
	} finally {
		cancelForeignRoom(proved);
	}

	const unproved = reserveForeignRoom("unproved", fakeSession(8));
	try {
		assert(unproved.proof === "session", "an unproved locator was called authenticated");
		assert(!unproved.origin.startsWith("session-"), "an unproved durable claim was exposed as origin");
	} finally {
		cancelForeignRoom(unproved);
	}
});

Deno.test("stale local cleanup cannot remove a replacement room generation", () => {
	const first = makeRoomState("replaceable", fakeSession(20));
	registerRoom(first);
	forgetRoom(first);

	const replacement = makeRoomState("REPLACEABLE", fakeSession(21));
	registerRoom(replacement);
	try {
		forgetRoom(first);
		assert(rooms.get(replacement.key) === replacement, "stale cleanup removed the live room");
		assert(publicRooms.get(replacement.key)?.id === replacement.entryId, "public index lost the live generation");
	} finally {
		forgetRoom(replacement);
	}
});
