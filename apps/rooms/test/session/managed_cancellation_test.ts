// A cancelled gesture already supplies its decision, including after a lost reply.
import { assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { ConversationOpening } from "../../web/ui/session/managed/openings.ts";
import { OPEN_ROOM_POLICY } from "../../lib/room/policy.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

for (const timing of ["before failure", "after failure"] as const) {
	Deno.test(`cancelled room acquisition continues its exact receipt automatically: ${timing}`, async () => {
		const current = snapshot();
		current.intent.directories.push({
			id: "dir",
			access: "access",
			home: true,
			nick: "ada",
			nickAllocation: "exact",
			standing: null,
		});
		const submitted = deferred<void>(), release = deferred<void>(), cleaned = deferred<void>();
		let prepared = 0, attempts = 0, freed = 0;
		const session = viewer({
			snapshot: () => Promise.resolve(current),
			preparePublicRoom: (_revision: string, raw: string) => {
				prepared++;
				const row = JSON.parse(raw);
				return Promise.resolve({
					submit: async () => {
						if (++attempts === 1) {
							submitted.resolve();
							await release.promise;
							throw new Error("lost admission reply");
						}
						current.intent.conversations.push({ kind: "room", ...row, draft: "" });
						return "committed";
					},
					free: () => freed++,
				});
			},
			prepareCommand: (id: string, revision: string, name: string, args: string[]) =>
				Promise.resolve({
					originalIntent: () => [id, Number(revision), name, args],
					submit: () => Promise.resolve("committed"),
					status: () => Promise.resolve("committed"),
					free() {},
				}),
		});
		session.completeResult = (operation) => {
			const args = operation.request.originalIntent()[3];
			current.intent.conversations = current.intent.conversations.filter((row) => row.id !== args[0]);
			session.finish(operation);
			cleaned.resolve();
			return Promise.resolve();
		};
		const cancel = new AbortController();
		const decisions: string[][] = [];
		const stop = session.subscribe(() => decisions.push([...session.actions.recoverable]));
		try {
			const outcome = Promise.allSettled([session.actions.publicRoom(
				"dir",
				"garden",
				"publication",
				new ConversationOpening(session, () => {}, cancel.signal),
			)]);
			await submitted.promise;
			if (timing === "before failure") cancel.abort();
			release.resolve();
			await outcome;
			if (timing === "after failure") cancel.abort();
			await cleaned.promise;
			if (session.actions.pending.length) await session.actions.recoverAcquisition(session.actions.pending[0]);
			assertEquals([prepared, attempts, freed], [1, 2, 1]);
			assertEquals(current.intent.conversations, []);
			assertEquals(session.actions.pending, []);
			if (timing === "before failure") assertEquals(decisions.every((row) => row.length === 0), true);
		} finally {
			stop();
			await session.close();
		}
	});
}

Deno.test("automatic cancellation recovery stops after a refusal and retains the exact failure", async () => {
	let submissions = 0;
	const session = viewer({
		prepareDirectory: () =>
			Promise.resolve({
				submit: () => {
					submissions++;
					return Promise.reject(new Error("directory unavailable"));
				},
				free() {},
			}),
	});
	const cancel = new AbortController();
	const failed = Promise.allSettled([
		session.actions.directory("dir", "route", { kind: "exact", name: "ada" }, false, cancel.signal),
	]);
	await failed;
	cancel.abort();
	await Promise.allSettled([session.actions.recoverAcquisition("directory:dir")]);
	assertEquals(submissions, 2);
	assertEquals(session.actions.recoverable, ["directory:dir"]);
	assertEquals((session.actions.diagnostics[0] as { needsDecision: boolean }).needsDecision, true);
	await session.close();
});

for (const failure of ["admission", "cleanup"] as const) {
	Deno.test(`cancelled creation automatically recovers its ${failure}, without a second upstream command`, async () => {
		const current = snapshot();
		current.intent.directories.push({
			id: "dir",
			access: "access",
			home: true,
			nick: "ada",
			nickAllocation: "exact",
			standing: null,
		});
		const admitted = deferred<void>(), release = deferred<void>(), cleaned = deferred<void>();
		const prepared: string[] = [];
		let original = "";
		const cancel = new AbortController();
		const session = viewer({
			snapshot: () => Promise.resolve(current),
			prepareCommand: (id: string, revision: string, name: string, args: string[]) => {
				prepared.push(name);
				if (name === "openManagedRoom") original = id;
				return Promise.resolve({
					originalIntent: () => [id, Number(revision), name, args],
					submit: async () => {
						if (name === "openManagedRoom") {
							admitted.resolve();
							await release.promise;
						}
						if (name === (failure === "admission" ? "openManagedRoom" : "leaveConversation")) {
							throw new Error("lost reply");
						}
						return "committed";
					},
					status: () => {
						if (name === "leaveConversation") {
							current.intent.conversations = current.intent.conversations.filter((row) =>
								row.id !== args[0]
							);
							cleaned.resolve();
						}
						return Promise.resolve("committed");
					},
					result: () => Promise.resolve(null),
					adopted: () => Promise.resolve(true),
					free() {},
				} as unknown as RoomsManagedCommand);
			},
		});
		session.completeResult = (operation) => {
			const [, , name, args] = operation.request.originalIntent();
			if (name === "openManagedRoom") {
				current.intent.conversations.push({
					kind: "room",
					id: operation.id,
					directory: "dir",
					name: "garden",
					access: "entry",
					control: null,
					reconnect: "requested",
					standing: null,
					draft: "",
				});
			} else {
				current.intent.conversations = current.intent.conversations.filter((row) => row.id !== args[0]);
				cleaned.resolve();
			}
			session.finish(operation);
			return Promise.resolve();
		};
		try {
			const outcome = Promise.allSettled([session.actions.createRoom(
				"dir",
				"garden",
				OPEN_ROOM_POLICY,
				new ConversationOpening(session, () => {}, cancel.signal),
			)]);
			await admitted.promise;
			cancel.abort();
			release.resolve();
			await outcome;
			await cleaned.promise;
			// Join the automatic worker through its existing public owner.
			if (session.pending.includes(original)) await session.completeOperation(original);
			assertEquals(prepared, ["openManagedRoom", "leaveConversation"]);
			assertEquals(current.intent.conversations, []);
			assertEquals([session.pending, session.recoverable], [[], []]);
		} finally {
			await session.close();
		}
	});
}
