// What the page does with the outcome Rust reports for a submitted
// acquisition: a refusal is forgotten with its reason, and an outcome nothing
// settled stays listed until it is picked back up or let go.
import { assert, assertEquals } from "../assert.ts";
import { snapshot, viewer } from "../support/managed_viewer.ts";
import { failedOutcome } from "../support/managed_link.ts";
import { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { RoomsManagedApplication, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import { SubmissionRefused } from "../../web/ui/session/managed/acquisition.ts";
import { openChanges } from "../../web/ui/session/managed/open_changes.ts";
import { failureView } from "../../lib/text/failure.ts";
import { managedSessionText } from "../../lib/text/managed_session.ts";

// A reason Rust reports as `refused`: a coded refusal the session is known to
// make before any effect. A bare break stays `uncertain`.
const BUSY = "the session is handling as much work as it can";
const REFUSED = `glowcap error -12: admission-busy: ${BUSY}`;
/** The binding's admission refusal, as Rust projects it beside its text. */
const refusedOutcome = () =>
	failedOutcome("refused", { status: -12, reason: `admission-busy: ${BUSY}`, code: "admission-busy", detail: BUSY });

Deno.test("a directory acquisition the session refused is forgotten and its reason reaches the caller", async () => {
	let submissions = 0;
	const session = viewer({
		snapshot: () => Promise.resolve(snapshot()),
		prepareDirectory: () =>
			Promise.resolve({
				submit: () => {
					submissions++;
					return Promise.resolve(refusedOutcome());
				},
				free() {},
			}),
	});
	try {
		const outcome: unknown = await session.actions
			.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true)
			.then(() => null, (error: unknown) => error);
		assert(outcome instanceof SubmissionRefused, "the session's refusal is the caller's");
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
					return Promise.resolve(
						failedOutcome("uncertain", { status: null, reason: "the reply never came", code: null }),
					);
				},
				free() {},
			}),
	});
	try {
		const outcome: unknown = await session.actions
			.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true)
			.then(() => null, (error: unknown) => error);
		assert(
			outcome instanceof Error && !(outcome instanceof SubmissionRefused),
			"an unsettled outcome is not a refusal",
		);
		assertEquals(outcome.cause, "the reply never came");
		assertEquals(failureView(outcome).code, "local-acquisition-unknown");
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
		assert(outcome instanceof Error && !(outcome instanceof SubmissionRefused), String(outcome));
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

Deno.test("a directory acquisition that went through but could not be shown here is finished, with a notice", async () => {
	let committed = false;
	let reads = 0;
	const notices: { source: string; error: unknown }[] = [];
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
	}, (source, error) => notices.push({ source, error }));
	try {
		await session.actions.directory("directory", "127.0.0.1:1234", { kind: "exact", name: "ada" }, true);
		// The change went through, so the press is done and nothing is held for a
		// repeat. The read that would redraw it is a notice, and the next update
		// redraws.
		assertEquals(reads, 1);
		assertEquals(notices.map((notice) => notice.source), [managedSessionText.changeUnread]);
		assertEquals([session.actions.pending, session.actions.recoverable, openChanges(session, [])], [[], [], []]);
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
						preparations === 1 ? refusedOutcome() : { status: "committed" },
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
		assert(outcome instanceof SubmissionRefused, "the session's refusal is the caller's");
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

Deno.test("an inventory status with no words here reads as unknown, an inherited name included", async () => {
	const session = viewer({ snapshot: () => Promise.resolve(snapshot()) });
	try {
		const rows = ["toString", "later"].map((status) => ({ operation: status, status, resumable: false }));
		assertEquals(openChanges(session, rows).map((row) => row.state), ["unknown", "unknown"]);
	} finally {
		await session.close();
	}
});
