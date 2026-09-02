// Durable room-topic state and its authority relations.

import { RoomServerState } from "../../server/state.ts";
import { assert, roomsTest } from "../support/rooms_server.ts";
import { MAX_ROOM_LINKS, newManagedRoomId } from "../../lib/limits.ts";

roomsTest("a public room topic survives restart independently of room-link authority", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-topic-state-" });
	try {
		const state = await RoomServerState.open(directory);
		await state.setTopic("General", "the durable subject");
		const restored = await RoomServerState.open(directory);
		assert(restored.topic("GENERAL") === "the durable subject", "the durable room topic did not survive restart");
		await restored.remember("General");
		await restored.revokeRoomLink("general");
		const retained = await RoomServerState.open(directory);
		assert(retained.topic("general") === "the durable subject", "revoking authority erased public room state");
		await retained.setTopic("general", "");
		assert((await RoomServerState.open(directory)).topic("general") === null, "taking down a topic retained state");
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("a private room topic remains coupled to its durable room authority", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-private-topic-state-" });
	try {
		const key = newManagedRoomId();
		const state = await RoomServerState.open(directory);
		await state.setTopic(key, "not durable without authority");
		assert(state.topic(key) === null, "an unlinked private room persisted its topic");
		await state.remember(key, "durable private subject");
		assert(state.topic(key) === "durable private subject", "a linked private room lost its topic");
		await state.revokeRoomLink(key);
		assert(
			(await RoomServerState.open(directory)).topic(key) === null,
			"revoked private authority retained its topic",
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("server state refuses orphan topics and zero durable stewardship generations", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-topic-relations-" });
	try {
		await RoomServerState.open(directory);
		const path = `${directory}/rooms.json`;
		const current = JSON.parse(await Deno.readTextFile(path)) as Record<string, unknown>;
		const refuses = async (malformed: Record<string, unknown>, message: string) => {
			await Deno.writeTextFile(path, JSON.stringify(malformed) + "\n");
			let refused = false;
			try {
				await RoomServerState.open(directory);
			} catch {
				refused = true;
			}
			assert(refused, message);
		};
		await refuses(
			{ ...current, topics: [{ name: newManagedRoomId(), topic: "not owned" }] },
			"orphan durable room topic state was accepted",
		);
		await refuses(
			{
				...current,
				linkedRooms: ["General"],
				stewards: [{ name: "General", generation: 0, issued: true }],
			},
			"generation-zero durable stewardship was accepted",
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

roomsTest("linking a room cannot write one topic beyond the server state bound", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-topic-bound-" });
	try {
		await RoomServerState.open(directory);
		const path = `${directory}/rooms.json`;
		const disk = JSON.parse(await Deno.readTextFile(path));
		disk.topics = Array.from({ length: MAX_ROOM_LINKS }, (_, at) => ({ name: `room-${at}`, topic: "held" }));
		await Deno.writeTextFile(path, JSON.stringify(disk) + "\n");
		const state = await RoomServerState.open(directory);
		let refused = false;
		try {
			await state.remember("new-linked-room", "new topic");
		} catch {
			refused = true;
		}
		assert(refused, "linking wrote a topic beyond the durable state bound");
		await RoomServerState.open(directory);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});
