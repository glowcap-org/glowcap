import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { openEffects, textDigest } from "../../session/effects.ts";
import { assertEquals } from "../assert.ts";
import { performResultCommand, ResultEffectCoordinator, resumeResultEffect } from "../../session/result_effect.ts";
import type { DurableRoomsRuntime } from "../../session/runtime.ts";
import type { DurableRoomsSessionState } from "../../session/state.ts";
import { ROOM_RETIRED, RoomError } from "../../lib/errors.ts";
import { workspaceFixture } from "../support/workspace.ts";
import { DurableRoomActions } from "../../session/runtime_room_actions.ts";
import type { LiveDirectory } from "../../session/live.ts";
import { fileSessionDocuments } from "../../session/file_documents.ts";
import { openSessionState } from "../support/session_disk.ts";

function refused(work: () => Promise<unknown>): Promise<boolean> {
	return work().then(() => false, () => true);
}

Deno.test("live result retries join one executor without re-entering its Host", async () => {
	const coordinator = new ResultEffectCoordinator();
	const finish = Promise.withResolvers<number>();
	let executions = 0;
	const first = coordinator.run("room-link", "same plan", () => {
		executions += 1;
		return finish.promise;
	});
	const joined = coordinator.run("room-link", null, () => {
		executions += 1;
		return Promise.resolve(99);
	});
	assertEquals(executions, 0);
	await Promise.resolve();
	assertEquals(executions, 1);
	assertEquals(await refused(() => coordinator.run("room-link", "different plan", () => Promise.resolve(2))), true);
	finish.resolve(7);
	assertEquals(await first, 7);
	assertEquals(await joined, 7);
	await Promise.resolve();
	assertEquals(await coordinator.run("room-link", "next plan", () => Promise.resolve(8)), 8);
});

Deno.test("a result-bearing checkpoint closes initial workspace adoption", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-result-adoption-" });
	try {
		const apply = (
			checkpoint: ReturnType<typeof emptyRoomsSessionState>,
			_kind: string,
			_intent: string,
			result: string,
		) => ({ ...checkpoint, standing: result });
		const state = await openSessionState(directory, apply);
		await state.prepareResultEffect("first-result", 0, "first-result", "private-room", "intent");
		assertEquals(await state.commitPendingResultEffect("first-result", "authority", apply), 1);
		assertEquals(state.workspaceAdoption, "closed");
		assertEquals(
			await refused(() => state.adoptWorkspace("late-adoption", 1, emptyRoomsSessionState())),
			true,
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("a result-bearing effect preserves concurrent state and replays each crash boundary once", async () => {
	const apply = (
		checkpoint: ReturnType<typeof emptyRoomsSessionState>,
		kind: string,
		intent: string,
		result: string,
	) => {
		if (kind !== "private-room" || intent !== "private intent") throw new Error("unknown result plan");
		const standing = `applied ${result}`;
		if (checkpoint.standing === standing) return checkpoint;
		if (checkpoint.standing !== "") throw new Error("result conflicts with checkpoint");
		return { ...checkpoint, standing };
	};
	const prepare = (state: DurableRoomsSessionState, id: string) =>
		state.prepareResultEffect(id, 0, `["private","${id}"]`, "private-room", "private intent");
	const injectResult = async (directory: string, marker: boolean) => {
		const path = `${directory}/effects.json`;
		const effects = JSON.parse(await Deno.readTextFile(path));
		effects.pending[0].result = "room authority";
		if (marker) {
			effects.pending[0].marker = {
				revision: 2,
				applyKind: "private-room",
				resultDigest: await textDigest("room authority"),
			};
		}
		await Deno.writeTextFile(path, JSON.stringify(effects) + "\n");
	};

	for (const stage of ["result", "marker", "checkpoint"] as const) {
		const directory = await Deno.makeTempDir({ prefix: `glowcap-rooms-result-${stage}-` });
		try {
			const state = await openSessionState(directory, apply);
			assertEquals((await prepare(state, `result-${stage}`)).kind, "prepared");
			assertEquals(
				await state.mutate({
					operationId: "concurrent",
					baseRevision: 0,
					material: "concurrent",
					impact: "presentation",
					change: (checkpoint) => ({ ...checkpoint, keepHistory: false }),
				}),
				1,
			);
			assertEquals(
				await refused(() => state.prepareResultEffect("second", 1, "second", "private-room", "private intent")),
				true,
			);
			await injectResult(directory, stage !== "result");
			if (stage === "checkpoint") {
				const path = `${directory}/session.json`;
				const disk = JSON.parse(await Deno.readTextFile(path));
				disk.revision = 2;
				disk.workspaceAdoption = "closed";
				disk.checkpoint = apply(disk.checkpoint, "private-room", "private intent", "room authority");
				await Deno.writeTextFile(path, JSON.stringify(disk) + "\n");
			}
			const restored = await openSessionState(directory, apply);
			assertEquals(restored.snapshot().revision, 2);
			assertEquals(restored.snapshot().checkpoint.standing, "applied room authority");
			assertEquals(restored.snapshot().checkpoint.keepHistory, false);
			assertEquals(restored.pendingEffectIds(), []);
			const repeated = await restored.prepareResultEffect(
				`result-${stage}`,
				0,
				`["private","result-${stage}"]`,
				"private-room",
				"private intent",
			);
			assertEquals(repeated.kind, "committed");
			assertEquals(repeated.kind === "committed" ? repeated.result : "", "room authority");
		} finally {
			await Deno.remove(directory, { recursive: true });
		}
	}
});

Deno.test("a prepared result may be abandoned before it returns authority", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-result-abandon-" });
	try {
		const state = await openSessionState(directory);
		await state.prepareResultEffect("private", 0, "private", "private-room", "intent");
		const restored = await openSessionState(directory);
		assertEquals(restored.pendingEffectIds(), ["private"]);
		await restored.resolveEffect("private", "abandoned");
		assertEquals(
			await restored.mutate({
				operationId: "after",
				baseRevision: 0,
				material: "after",
				impact: "presentation",
				change: (checkpoint) => checkpoint,
			}),
			1,
		);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("foreign room-manager recovery refuses before durable effect admission", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-result-foreign-manager-" });
	try {
		const state = await openSessionState(directory);
		const checkpoint = workspaceFixture().session;
		await state.mutate({
			operationId: "install-room",
			baseRevision: 0,
			material: "install-room",
			impact: "realization",
			change: () => checkpoint,
		});
		const directories = new Map([
			["directory", { roomRealization: { rooms: new Map([["room-id", { source: "bridge" }]]) } }],
		]) as unknown as ReadonlyMap<string, LiveDirectory>;
		const runtime = {
			roomActions: new DurableRoomActions(directories, () => Promise.resolve("unused")),
		} as DurableRoomsRuntime;
		assertEquals(
			await refused(() =>
				performResultCommand(
					state,
					runtime,
					"recover-bridge",
					1,
					"recoverRoomManager",
					["room-id"],
					"recover bridge",
				)
			),
			true,
		);
		assertEquals(state.pendingEffectIds(), []);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("a retired bridge abandons its stale capability effect when resumed", async () => {
	const directory = await Deno.makeTempDir({ prefix: "glowcap-rooms-result-retired-bridge-" });
	try {
		const state = await openSessionState(directory);
		const conversation = workspaceFixture().session.conversations[0];
		const checkpoint = workspaceFixture().session;
		await state.mutate({
			operationId: "install-room",
			baseRevision: 0,
			material: "install-room",
			impact: "realization",
			change: () => checkpoint,
		});
		await state.prepareResultEffect(
			"retired-bridge",
			1,
			"recover bridge",
			"room-manager",
			JSON.stringify({ conversation }),
		);
		const runtime = {
			roomActions: {
				recoverManager: () => Promise.reject(new RoomError(ROOM_RETIRED, "this IRC bridge has been parted")),
			},
		} as unknown as DurableRoomsRuntime;
		assertEquals(await resumeResultEffect(state, runtime, "retired-bridge"), 1);
		assertEquals(state.pendingEffectIds(), []);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("result effect storage refuses obsolete envelopes, bounds authority, and checks markers", async () => {
	const obsolete = await Deno.makeTempDir({ prefix: "glowcap-rooms-result-obsolete-" });
	try {
		await openSessionState(obsolete);
		const path = `${obsolete}/effects.json`;
		const prior = JSON.parse(await Deno.readTextFile(path));
		prior.version = 2;
		const encoded = JSON.stringify(prior) + "\n";
		await Deno.writeTextFile(path, encoded);
		assertEquals(await refused(() => openEffects(fileSessionDocuments(obsolete), false)), true);
		assertEquals(await Deno.readTextFile(path), encoded);
	} finally {
		await Deno.remove(obsolete, { recursive: true });
	}

	const bounded = await Deno.makeTempDir({ prefix: "glowcap-rooms-result-bounded-" });
	try {
		const state = await openSessionState(bounded);
		await state.prepareResultEffect("bounded", 0, "bounded", "private-room", "intent");
		assertEquals(
			await refused(() => state.prepareResultEffect("bounded", 0, "different", "private-room", "intent")),
			true,
		);
		assertEquals(
			await refused(() =>
				state.commitPendingResultEffect("bounded", "x".repeat(32 * 1024 + 1), (checkpoint) => checkpoint)
			),
			true,
		);
		await state.resolveEffect("bounded", "abandoned");
	} finally {
		await Deno.remove(bounded, { recursive: true });
	}

	const malformed = await Deno.makeTempDir({ prefix: "glowcap-rooms-result-marker-" });
	try {
		const state = await openSessionState(malformed);
		await state.prepareResultEffect("marker", 0, "marker", "private-room", "intent");
		const path = `${malformed}/effects.json`;
		const effects = JSON.parse(await Deno.readTextFile(path));
		effects.pending[0].result = "authority";
		effects.pending[0].marker = {
			revision: 1,
			applyKind: "private-room",
			resultDigest: await textDigest("different authority"),
		};
		await Deno.writeTextFile(path, JSON.stringify(effects) + "\n");
		assertEquals(await refused(() => openSessionState(malformed)), true);
	} finally {
		await Deno.remove(malformed, { recursive: true });
	}
});
