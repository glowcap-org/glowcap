import { parseSturdyRef } from "@pancake/runtime";
import { ALL_ARCHIVE_RECORDS, readArchive } from "../../lib/archive/protocol.ts";
import { roomsAddress, roomsHost } from "../../lib/locator.ts";
import { openRoomsRuntime } from "../../lib/runtime.ts";
import { DurableRoomsArchive } from "../../session/archive.ts";
import { spawnOwned, stopOwned } from "../support/children.ts";
import { assert, dial, freePort, roomsTest, ROOT } from "../support/rooms_server.ts";
import { announcedSturdyref } from "../support/standalone_peer.ts";

const PEER = new URL("../../archive/main.ts", import.meta.url).pathname;

function startPeer(directory: string, port: number): Deno.ChildProcess {
	return spawnOwned("deno", {
		args: [
			"run",
			"--allow-ffi",
			"--unstable-ffi",
			`--allow-read=${ROOT},${directory}`,
			`--allow-write=${directory}`,
			"--allow-net=127.0.0.1",
			"--allow-env=PANCAKE_LIB_DIR",
			PEER,
			`--state=${directory}`,
			"--transport=tcp",
			`--port=${port}`,
		],
		cwd: ROOT,
		stdout: "piped",
		stderr: "piped",
	});
}

roomsTest("durable Rooms archive custody validates, orders, and drains selected authority", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-archive-" });
	const peer = startPeer(directory, freePort());
	try {
		const link = await announcedSturdyref(peer, "ROOMS-ARCHIVE-LISTENING", "archive peer");
		const runtime = await openRoomsRuntime();
		const issues: string[] = [];
		const archive = new DurableRoomsArchive(runtime, "durable-session-source", (error) => {
			if (error != null) issues.push(error instanceof Error ? error.message : String(error));
		});
		await archive.reconcile(link);
		archive.record({
			kind: "line",
			id: "room-line",
			generation: "room-generation",
			conversationKind: "room",
			directory: "directory",
			conversation: "general",
			from: "alice",
			text: "first",
			mine: true,
			at: 1,
			state: "present",
			attachments: [],
		});
		archive.record({
			kind: "line",
			id: "room-line",
			generation: "room-generation",
			conversationKind: "room",
			directory: "directory",
			conversation: "general",
			from: "alice",
			text: "first, revised",
			mine: true,
			at: 3,
			state: "edited",
			attachments: [],
		});
		archive.record({
			kind: "line",
			generation: "direct-generation",
			conversationKind: "direct",
			directory: "directory",
			conversation: "alice-bob",
			from: "bob",
			text: "second",
			mine: false,
			at: 2,
			state: "present",
			attachments: [],
		});
		await archive.close();
		await runtime.close();
		assert(issues.length === 0, `archive custody reported ${JSON.stringify(issues)}`);

		const parsed = parseSturdyRef(link, "v1_0");
		const session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		try {
			const capability = await session.enliven(link);
			const page = await readArchive(session, capability, ALL_ARCHIVE_RECORDS);
			assert(page.records.length === 2, `archive retained ${page.records.length} records`);
			const room = page.records.find((entry) =>
				entry.record.kind === "line" && entry.record.conversation === "general"
			);
			const direct = page.records.find((entry) =>
				entry.record.kind === "line" && entry.record.conversation === "alice-bob"
			);
			assert(
				room?.record.kind === "line" && room.record.text === "first, revised",
				"edited room record did not replace its original",
			);
			assert(
				direct?.record.kind === "line" && direct.record.text === "second",
				"second record moved",
			);
		} finally {
			await session.close();
		}
	} finally {
		await stopOwned(peer);
		await Deno.remove(directory, { recursive: true });
	}
});
