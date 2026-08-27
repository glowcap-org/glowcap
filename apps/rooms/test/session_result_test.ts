import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { DurableRoomsSessionState } from "../session/state.ts";
import { openEffects, textDigest } from "../session/effects.ts";
import { assertEquals } from "./assert.ts";

function refused(work: () => Promise<unknown>): Promise<boolean> {
	return work().then(() => false, () => true);
}

Deno.test("a result-bearing checkpoint closes initial workspace adoption", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-result-adoption-" });
	try {
		const apply = (
			checkpoint: ReturnType<typeof emptyRoomsSessionState>,
			_kind: string,
			_intent: string,
			result: string,
		) => ({ ...checkpoint, standing: result });
		const state = await DurableRoomsSessionState.open(directory, apply);
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
		const directory = await Deno.makeTempDir({ prefix: `pancake-rooms-result-${stage}-` });
		try {
			const state = await DurableRoomsSessionState.open(directory, apply);
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
			const restored = await DurableRoomsSessionState.open(directory, apply);
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
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-result-abandon-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		await state.prepareResultEffect("private", 0, "private", "private-room", "intent");
		const restored = await DurableRoomsSessionState.open(directory);
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

Deno.test("result effect storage refuses obsolete envelopes, bounds authority, and checks markers", async () => {
	const obsolete = await Deno.makeTempDir({ prefix: "pancake-rooms-result-obsolete-" });
	try {
		await DurableRoomsSessionState.open(obsolete);
		const path = `${obsolete}/effects.json`;
		const prior = JSON.parse(await Deno.readTextFile(path));
		prior.version = 2;
		const encoded = JSON.stringify(prior) + "\n";
		await Deno.writeTextFile(path, encoded);
		assertEquals(await refused(() => openEffects(obsolete, false)), true);
		assertEquals(await Deno.readTextFile(path), encoded);
	} finally {
		await Deno.remove(obsolete, { recursive: true });
	}

	const bounded = await Deno.makeTempDir({ prefix: "pancake-rooms-result-bounded-" });
	try {
		const state = await DurableRoomsSessionState.open(bounded);
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

	const malformed = await Deno.makeTempDir({ prefix: "pancake-rooms-result-marker-" });
	try {
		const state = await DurableRoomsSessionState.open(malformed);
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
		assertEquals(await refused(() => DurableRoomsSessionState.open(malformed)), true);
	} finally {
		await Deno.remove(malformed, { recursive: true });
	}
});
