import type { Runtime } from "@pancake/runtime";
import { MemoryArchiveBackend } from "../lib/archive.ts";
import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import type { DurableRoomsArchiveShares } from "../session/archive_shares.ts";
import type { LiveDirectory } from "../session/live.ts";
import { DurableRoomsRuntime } from "../session/runtime.ts";
import { closeRuntimeDirectory } from "../session/runtime_cleanup.ts";
import { assertEquals } from "./assert.ts";

Deno.test("directory cleanup continues after one child owner refuses", async () => {
	const closed: string[] = [];
	const held = {
		id: "directory",
		stopClose: () => {
			closed.push("watch");
			throw new Error("watch refused");
		},
		directIntents: new Map(),
		directConversationByRegistration: new Map(),
		directRouteAttempts: new Map(),
		offerer: {
			close: () => Promise.reject(new Error("offerer refused")),
		},
		directs: new Map([[
			"direct",
			{ close: () => Promise.resolve().then(() => closed.push("direct")) },
		]]),
		roomRealization: {
			rooms: new Map([[
				"room",
				{
					postedLines: new Map(),
					pendingLines: [],
					files: { close: () => closed.push("files") },
					room: { leave: () => Promise.resolve().then(() => closed.push("room")) },
				},
			]]),
		},
		directory: { close: () => Promise.resolve().then(() => closed.push("directory")) },
	} as unknown as LiveDirectory;
	const archiveShares = {
		releaseDirectory: (directory: string) => {
			closed.push(`shares:${directory}`);
			throw new Error("shares refused");
		},
	} as unknown as DurableRoomsArchiveShares;
	let failure: unknown = null;
	try {
		await closeRuntimeDirectory(held, archiveShares);
	} catch (error) {
		failure = error;
	}
	assertEquals(closed, ["watch", "shares:directory", "direct", "files", "room", "directory"]);
	const errors = failure instanceof AggregateError ? failure.errors.map(String).join("\n") : String(failure);
	assertEquals(errors.includes("offerer refused"), true);
	assertEquals(errors.includes("watch refused"), true);
	assertEquals(errors.includes("shares refused"), true);
});

Deno.test("concurrent durable runtime close calls share one lifecycle", async () => {
	const stopped = Promise.withResolvers<void>();
	let closes = 0;
	const runtime = new DurableRoomsRuntime(
		{
			close: () => {
				closes += 1;
				return stopped.promise;
			},
		} as unknown as Runtime,
		"session-source",
		new MemoryArchiveBackend(),
	);
	const first = runtime.close();
	const second = runtime.close();
	assertEquals(first === second, true);
	assertEquals(runtime.reconcile(emptyRoomsSessionState()) === first, true);
	stopped.resolve();
	await first;
	assertEquals(closes, 1);
});
