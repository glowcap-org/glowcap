// Attached join admission waits for authoritative settlement and releases its observer on cancellation.
/// <reference lib="dom" />

import type { RoomsSessionSnapshot } from "../../lib/session/client.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { waitForRoomAdmission } from "../../web/ui/session/join_admission.ts";
import { assertEquals } from "../assert.ts";
import { roomsSessionSnapshot } from "../support/session_snapshot.ts";

class Feed {
	current: RoomsSessionSnapshot | null = null;
	readonly listeners = new Set<(snapshot: RoomsSessionSnapshot) => void>();

	onSnapshot(listener: (snapshot: RoomsSessionSnapshot) => void): () => void {
		this.listeners.add(listener);
		if (this.current !== null) listener(this.current);
		return () => this.listeners.delete(listener);
	}

	publish(snapshot: RoomsSessionSnapshot): void {
		this.current = snapshot;
		for (const listener of this.listeners) listener(snapshot);
	}
}

const checkpoint = {
	...emptyRoomsSessionState(),
	directories: [{ id: "directory", locator: "ocapn://directory.iroh", home: true, nick: "alice", standing: null }],
	conversations: [{
		kind: "room" as const,
		id: "joining-room",
		directory: "directory",
		name: "general",
		held: false,
		standing: null,
		draft: "",
	}],
	active: "joining-room",
};

Deno.test("join admission waits past committed intent and intermediate issues", async () => {
	const feed = new Feed();
	const committed = roomsSessionSnapshot({ revision: 2, checkpoint });
	let settled = false;
	const joining = waitForRoomAdmission(feed, committed).finally(() => settled = true);
	await Promise.resolve();
	assertEquals(settled, false, "committing the join intent was mistaken for room admission");
	feed.publish(roomsSessionSnapshot({
		revision: 3,
		checkpoint,
		pendingEffects: ["join-effect"],
		pendingEffectDetails: [{
			id: "join-effect",
			kind: "room",
			subject: "room:directory:joining-room",
			phase: "prepared",
		}],
		issues: [{ subject: "room:directory:joining-room", reason: "that directory is not connected" }],
	}));
	await Promise.resolve();
	assertEquals(settled, false, "an intermediate issue was mistaken for the retained effect's final answer");
	feed.publish(roomsSessionSnapshot({
		revision: 4,
		checkpoint,
		issues: [{ subject: "room:directory:joining-room", reason: "nick-taken: name is claimed" }],
	}));
	await joining.then(
		() => {
			throw new Error("a refused room effect was reported as admitted");
		},
		(error) => assertEquals(error instanceof Error ? error.message : String(error), "nick-taken: name is claimed"),
	);
	assertEquals(feed.listeners.size, 0, "a final room answer retained its snapshot listener");
});

Deno.test("join admission cancellation removes its snapshot listener", async () => {
	const feed = new Feed();
	const stop = new AbortController();
	const joining = waitForRoomAdmission(feed, roomsSessionSnapshot({ checkpoint }), stop.signal);
	stop.abort();
	await joining.then(
		() => {
			throw new Error("a cancelled join was reported as admitted");
		},
		(error) => assertEquals(error instanceof Error ? error.message : String(error), "Rooms join cancelled"),
	);
	assertEquals(feed.listeners.size, 0, "a cancelled join retained its snapshot listener");
});
