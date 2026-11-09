// What the page does with the outcome Rust reports for a submitted
// acquisition: a refusal is forgotten with its reason, and an outcome nothing
// settled stays listed until it is picked back up or let go.
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { AcquisitionRefused } from "../../web/ui/session/managed/acquisition.ts";
import { openChanges } from "../../web/ui/session/managed/open_changes.ts";

Deno.test("a directory acquisition the session refused is forgotten and its reason reaches the caller", async () => {
	let submissions = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareDirectory: () =>
			Promise.resolve({
				submit: () => {
					submissions++;
					return Promise.resolve({ status: "refused", reason: "glowcap error -12: PromiseBroken" });
				},
				free() {},
			}),
	});
	try {
		const outcome: unknown = await session.actions
			.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true)
			.then(() => null, (error: unknown) => error);
		assert(outcome instanceof AcquisitionRefused, "the session's refusal is the caller's");
		assertEquals(outcome.message, "glowcap error -12: PromiseBroken");
		// Nothing was admitted, so nothing is left to pick back up or finish.
		assertEquals([session.actions.pending, session.actions.recoverable, openChanges(session, [])], [[], [], []]);
		await session.actions.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true).catch(
			() => {},
		);
		assertEquals(submissions, 2, "a fresh press prepares and submits afresh");
	} finally {
		await session.close();
	}
});

Deno.test("a directory acquisition nothing settled is listed with its outcome unknown and can be let go", async () => {
	let submissions = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareDirectory: () =>
			Promise.resolve({
				submit: () => {
					submissions++;
					return Promise.resolve({ status: "uncertain", reason: "the reply never came" });
				},
				free() {},
			}),
	});
	try {
		const outcome: unknown = await session.actions
			.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true)
			.then(() => null, (error: unknown) => error);
		assert(
			outcome instanceof Error && !(outcome instanceof AcquisitionRefused),
			"an unsettled outcome is not a refusal",
		);
		assert(outcome.message.includes("the reply never came"), outcome.message);
		assertEquals(session.actions.pending, ["directory:directory"]);
		assertEquals(session.actions.recoverable, ["directory:directory"]);
		const [row] = openChanges(session, []);
		assertEquals(
			{ status: row.status, state: row.state, act: row.act, letGo: row.letGo },
			{ status: "unknown", state: "unknown", act: "acquire", letGo: true },
		);
		await session.releaseOperation("directory:directory");
		assertEquals([session.actions.pending, openChanges(session, []), submissions], [[], [], 1]);
	} finally {
		await session.close();
	}
});
