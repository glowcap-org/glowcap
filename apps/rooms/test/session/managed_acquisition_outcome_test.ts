// What the page does with the outcome Rust reports for a submitted
// acquisition: a refusal is forgotten with its reason, and an outcome nothing
// settled stays listed until it is picked back up or let go.
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { RoomsManagedApplication, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { AcquisitionRefused } from "../../web/ui/session/managed/acquisition.ts";
import { openChanges } from "../../web/ui/session/managed/open_changes.ts";

// A reason Rust reports as `refused`: a coded refusal the session is known to
// make before any effect. A bare break stays `uncertain`.
const REFUSED = "glowcap error -12: admission-busy: the session is handling as much work as it can";

Deno.test("a directory acquisition the session refused is forgotten and its reason reaches the caller", async () => {
	let submissions = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareDirectory: () =>
			Promise.resolve({
				submit: () => {
					submissions++;
					return Promise.resolve({ status: "refused", reason: REFUSED });
				},
				free() {},
			}),
	});
	try {
		const outcome: unknown = await session.actions
			.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true)
			.then(() => null, (error: unknown) => error);
		assert(outcome instanceof AcquisitionRefused, "the session's refusal is the caller's");
		assertEquals(outcome.message, REFUSED);
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

Deno.test("an outcome Rust did not shape is held as unsettled, never taken as committed", async () => {
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		// The shape before outcomes carried a reason, as a stale bundle would answer.
		prepareDirectory: () => Promise.resolve({ submit: () => Promise.resolve("committed"), free() {} }),
	});
	try {
		const outcome: unknown = await session.actions
			.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true)
			.then(() => null, (error: unknown) => error);
		assert(outcome instanceof Error && !(outcome instanceof AcquisitionRefused), String(outcome));
		assert(outcome.message.includes('unrecognized outcome "committed"'), outcome.message);
		assertEquals(session.actions.recoverable, ["directory:directory"]);
		const [row] = openChanges(session, []);
		assertEquals({ status: row.status, state: row.state, letGo: row.letGo }, {
			status: "unknown",
			state: "unknown",
			letGo: true,
		});
	} finally {
		await session.close();
	}
});

Deno.test("a directory acquisition that went through but could not be shown here can be let go", async () => {
	let committed = false;
	let reads = 0;
	const session = viewer({
		snapshot: () => {
			if (committed) {
				reads++;
				return Promise.reject(new Error("the session did not answer"));
			}
			return Promise.resolve(snapshot());
		},
		prepareDirectory: () =>
			Promise.resolve({
				submit: () => {
					committed = true;
					return Promise.resolve({ status: "committed" });
				},
				free() {},
			}),
	});
	try {
		const outcome: unknown = await session.actions
			.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true)
			.then(() => null, (error: unknown) => error);
		assert(outcome instanceof Error && outcome.message.includes("the session did not answer"), String(outcome));
		const [row] = openChanges(session, []);
		assertEquals(
			{ status: row.status, state: row.state, act: row.act, letGo: row.letGo },
			{ status: "committed", state: "saving", act: "acquire", letGo: true },
		);
		// Finishing reads the session again and fails the same way; letting go
		// is the exit, and the change itself stays saved in the session.
		await session.actions.recoverAcquisition("directory:directory").catch(() => {});
		assertEquals(reads, 2);
		await session.releaseOperation("directory:directory");
		assertEquals([session.actions.pending, openChanges(session, [])], [[], []]);
	} finally {
		await session.close();
	}
});

Deno.test("a workspace selection the session refused is freed and the next selection prepares afresh", async () => {
	let preparations = 0;
	let freed = 0;
	const custody = {
		free() {},
		prepareSelectWorkspace: () => {
			preparations++;
			return Promise.resolve({
				submit: () =>
					Promise.resolve(
						preparations === 1 ? { status: "refused", reason: REFUSED } : { status: "committed" },
					),
				free() {
					freed++;
				},
			});
		},
	} as unknown as RoomsManagedWorkspace;
	const application = {
		attachWorkspace: () => Promise.resolve({ free() {} }),
		close: () => Promise.resolve(),
		free() {},
	} as unknown as RoomsManagedApplication;
	const session = new ManagedRoomsSession(application, custody, custody, () => {});
	try {
		const outcome: unknown = await session.selectWorkspace("original").then(() => null, (error: unknown) => error);
		assert(outcome instanceof AcquisitionRefused, "the session's refusal is the caller's");
		assertEquals(outcome.message, REFUSED);
		assertEquals(freed, 1, "a refused selection is not held");
		// Nothing is held, so a different selection is a fresh gesture, not a
		// replacement the retained one refuses.
		await session.selectWorkspace("replacement");
		assertEquals([preparations, freed], [2, 2]);
	} finally {
		await session.close();
	}
});
