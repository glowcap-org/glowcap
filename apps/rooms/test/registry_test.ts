import type { PartnerIdentity, Ref, Session } from "@pancake/runtime";
import { ROOM_EXISTS, RoomError, TOO_MANY_PEERED_ROOMS } from "../lib/errors.ts";
import { MAX_PEERED_ROOMS, MAX_PEERED_ROOMS_PER_SOURCE } from "../lib/limits.ts";
import {
	cancelForeignRoom,
	commitForeignRoom,
	forgetForeignRoom,
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

/** A session that records every capability it is asked to release, so a test
 * can assert a peered room's capability is handed back exactly once and never
 * twice. */
function countingSession(index: number): { session: Session; released: Ref[] } {
	const released: Ref[] = [];
	const base = fakeSession(index);
	const session = {
		partnerIdentity: base.partnerIdentity.bind(base),
		release: (ref: Ref) => {
			released.push(ref);
		},
	} as unknown as Session;
	return { session, released };
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

Deno.test("a committed peered room is discoverable, and forgetting it releases its capability once and frees the slot", () => {
	const { session, released } = countingSession(40);
	const room = { id: 1n } as unknown as Ref;
	const reservation = reserveForeignRoom("owned-peer", session);
	const entry = commitForeignRoom(reservation, room);
	try {
		assert(publicRoomById(entry.id) === entry, "a committed peered room is not discoverable by id");
		assert(publicRooms.get(reservation.key) === entry, "a committed peered room is not in the public namespace");
		// Snapshot the count into a fresh local each time: asserting on
		// `released.length` directly would narrow it to a literal and hide the
		// mutation that forget performs between the checks.
		const releasedAtCommit = released.length;
		assert(releasedAtCommit === 0, "committing a peered room released its capability early");

		const forgotten = forgetForeignRoom(entry.id);
		assert(forgotten === entry, "forget did not return the committed entry");
		const releasedAtForget = released.length;
		assert(
			releasedAtForget === 1 && released[0] === room,
			"the peered room capability was not released exactly once",
		);
		assert(publicRoomById(entry.id) === null, "a forgotten peered room is still discoverable");

		// Idempotent: a second forget of the same generation finds nothing and
		// releases nothing, so a stale lease cannot double-release.
		assert(forgetForeignRoom(entry.id) === null, "double forget found a ghost entry");
		const releasedAtDoubleForget = released.length;
		assert(releasedAtDoubleForget === 1, "double forget released the capability a second time");

		// The slot the reservation held is free again: the same source can
		// reserve the same name without hitting a phantom collision or quota.
		const again = reserveForeignRoom("owned-peer", session);
		cancelForeignRoom(again);
	} finally {
		// Defensive: if an assertion failed before forget, do not leak the row.
		if (publicRoomById(entry.id) !== null) forgetForeignRoom(entry.id);
	}
});

Deno.test("committing a peered room whose reservation was revoked first is refused", () => {
	const { session } = countingSession(41);
	const reservation = reserveForeignRoom("revoked-early", session);
	assert(cancelForeignRoom(reservation), "a live reservation should cancel");
	let refused = false;
	try {
		commitForeignRoom(reservation, { id: 2n } as unknown as Ref);
	} catch {
		refused = true;
	}
	assert(refused, "committing a capability onto a cancelled reservation must be refused");
	assert(publicRooms.get(reservation.key) === undefined, "a refused commit left a public namespace row");
});
