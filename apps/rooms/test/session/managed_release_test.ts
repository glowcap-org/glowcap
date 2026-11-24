// Letting a change go: the session answers each release with one word, and a
// change whose job still runs is asked again until the job ends or its bound
// passes.
import { assert, assertEquals } from "../assert.ts";
import { settle, until } from "../support/wait.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { closed, FakeClock, fakeHandle, linkedWorkspace } from "../support/managed_link.ts";
import { failureView } from "../../lib/text/failure.ts";
import { RUNNING_BOUND_MS } from "../../lib/limits.ts";
import { RELEASE_ASK_MS } from "../../web/ui/session/managed/release.ts";
import type { RoomsManagedCommand } from "../../../../zig-out/wasm/rooms/rooms_browser.js";

/** A page whose session answers each release of a receipt with the next of
 * `answers`, repeating the last, and counts the asks in `asks`. */
function releasing(answers: unknown[], clock = new FakeClock()) {
	const asks: string[] = [];
	const session = viewer(
		{
			snapshot: () => Promise.resolve(snapshot()),
			recoverEffect: (id: string) =>
				Promise.resolve({
					release: () => {
						asks.push(id);
						return Promise.resolve(answers[Math.min(asks.length, answers.length) - 1]);
					},
					free() {},
				}),
		},
		undefined,
		{},
		true,
		clock,
	);
	return { session, asks, clock };
}

/** Hold `id` as a change whose outcome the page could not confirm, so the
 * person can let it go. */
async function unconfirmed(session: ReturnType<typeof viewer>, id: string): Promise<void> {
	const submitted = deferred<{ status: string }>();
	const request = fakeHandle<RoomsManagedCommand>({
		submit: () => submitted.promise,
		status: () => Promise.resolve("failed"),
		free() {},
	});
	const uncertain = Promise.allSettled([session.perform(id, () => Promise.resolve(request))]);
	submitted.resolve({ status: "unknown" });
	await uncertain;
	assertEquals(session.recoverable, [id]);
}

/** `work`'s outcome, read without waiting, or null while it runs. */
function watched<T>(work: Promise<T>) {
	const state: { outcome: PromiseSettledResult<T> | null } = { outcome: null };
	work.then(
		(value) => {
			state.outcome = { status: "fulfilled", value };
		},
		(reason: unknown) => {
			state.outcome = { status: "rejected", reason };
		},
	);
	return state;
}

Deno.test("a change whose job still runs is let go once the job ends", async () => {
	const { session, asks, clock } = releasing(["running", "running", "released"]);
	try {
		await unconfirmed(session, "abandoned");
		const letting = watched(session.releaseOperation("abandoned"));
		await settle();
		assertEquals([asks.length, letting.outcome, session.recoverable], [1, null, ["abandoned"]]);
		clock.advance(RELEASE_ASK_MS);
		await settle();
		assertEquals([asks.length, letting.outcome, session.recoverable], [2, null, ["abandoned"]]);
		clock.advance(RELEASE_ASK_MS);
		await until(() => letting.outcome != null, "the release");
		assertEquals([asks.length, letting.outcome?.status, session.recoverable], [3, "fulfilled", []]);
	} finally {
		await session.close();
	}
});

// The session answers kept once the receipt's source adopted its result, as
// another page of the same access does after the job ends.
Deno.test("a change whose result was kept meanwhile is let go as kept once its job ends", async () => {
	const { session, asks, clock } = releasing(["running", "kept"]);
	try {
		await unconfirmed(session, "abandoned");
		const letting = watched(session.releaseOperation("abandoned"));
		await settle();
		assertEquals([asks.length, letting.outcome], [1, null]);
		clock.advance(RELEASE_ASK_MS);
		await until(() => letting.outcome != null, "the release");
		assertEquals([asks.length, letting.outcome, session.recoverable], [
			2,
			{ status: "fulfilled", value: "kept" },
			[],
		]);
	} finally {
		await session.close();
	}
});

Deno.test("a change whose job runs past its bound stays to let go, saying it is still running", async () => {
	const { session, asks, clock } = releasing(["running"]);
	try {
		await unconfirmed(session, "abandoned");
		const letting = watched(session.releaseOperation("abandoned"));
		for (let waited = 0; waited < RUNNING_BOUND_MS && letting.outcome == null; waited += RELEASE_ASK_MS) {
			await settle();
			clock.advance(RELEASE_ASK_MS);
		}
		await until(() => letting.outcome != null, "the release");
		const outcome = letting.outcome;
		assert(outcome?.status === "rejected", "a release past the bound was taken as released");
		const view = failureView(outcome.reason);
		assertEquals([view.code, view.retry], ["local-change-busy", "soon"]);
		assert(view.detail.includes(`${RUNNING_BOUND_MS} ms`), view.detail);
		assertEquals(asks.length, RUNNING_BOUND_MS / RELEASE_ASK_MS + 1);
		assertEquals(session.recoverable, ["abandoned"]);
	} finally {
		await session.close();
	}
});

for (const answer of ["paused", undefined, null, 1]) {
	Deno.test(`a release answered with ${JSON.stringify(answer) ?? "nothing"} fails with that answer`, async () => {
		const { session, asks } = releasing([answer]);
		try {
			await unconfirmed(session, "abandoned");
			const [outcome] = await Promise.allSettled([session.releaseOperation("abandoned")]);
			assert(outcome.status === "rejected", "an unknown release answer was taken as released");
			const view = failureView(outcome.reason);
			assertEquals(view.code, "local-release-unconfirmed");
			const shown = typeof answer === "string" ? `"${answer}"` : String(answer);
			assert(view.detail.includes(`a release with ${shown}`), view.detail);
			assertEquals([asks.length, session.recoverable], [1, ["abandoned"]]);
		} finally {
			await session.close();
		}
	});
}

Deno.test("closing the page ends a release waiting on a running job", async () => {
	const { session, asks, clock } = releasing(["running"]);
	const letting = watched(session.releaseOperation("abandoned"));
	await settle();
	assertEquals([asks.length, letting.outcome], [1, null]);
	await session.close();
	await until(() => letting.outcome != null, "the release");
	const outcome = letting.outcome;
	assert(outcome?.status === "rejected", "a closed page reported the change let go");
	assertEquals(failureView(outcome.reason).code, "local-session-closed");
	clock.advance(RUNNING_BOUND_MS);
	await settle();
	assertEquals(asks.length, 1);
});

/** A page whose first link answers each release `running`, and whose second
 * link answers each release with the next of `then`, repeating the last.
 * `asks` counts the asks on each link. */
function relinking(then: unknown[]) {
	const log: string[] = [];
	const asks: string[] = [];
	const over = (name: string, answer: () => unknown) => ({
		recoverEffect: (id: string) =>
			Promise.resolve({
				release: () => {
					asks.push(`${name} ${id}`);
					return Promise.resolve(answer());
				},
				free() {},
			}),
	});
	const first = linkedWorkspace("first", log, over("first", () => "running"));
	let later = 0;
	const second = linkedWorkspace(
		"second",
		log,
		over("second", () => then[Math.min(later++, then.length - 1)]),
	);
	const clock = new FakeClock();
	const session = viewer(
		first.workspace,
		undefined,
		{ relink: () => Promise.resolve(second.workspace) },
		false,
		clock,
	);
	return { session, first, asks, clock };
}

Deno.test("a newer link asks a release waiting on a running job again over that link", async () => {
	const { session, first, asks, clock } = relinking(["released"]);
	try {
		await session.start();
		const generation = session.link?.generation;
		const letting = watched(session.releaseOperation("abandoned"));
		await settle();
		assertEquals([asks, letting.outcome], [["first abandoned"], null]);
		first.lose(closed());
		await until(() => session.link?.live === true && session.link.generation !== generation, "the new link");
		await until(() => letting.outcome != null, "the release");
		assertEquals([letting.outcome?.status, asks], ["fulfilled", ["first abandoned", "second abandoned"]]);
		clock.advance(RELEASE_ASK_MS);
		await settle();
		assertEquals(asks.length, 2, "the replaced link is asked nothing more");
	} finally {
		await session.close();
	}
});

Deno.test("a release asked again over a newer link keeps the bound its first running answer began", async () => {
	const { session, first, asks, clock } = relinking(["running"]);
	try {
		await session.start();
		const generation = session.link?.generation;
		const letting = watched(session.releaseOperation("abandoned"));
		await settle();
		// The job still runs most of its bound before the link drops.
		const before = RUNNING_BOUND_MS / RELEASE_ASK_MS - 1;
		for (let tick = 0; tick < before; tick++) {
			clock.advance(RELEASE_ASK_MS);
			await settle();
		}
		assertEquals([asks.length, letting.outcome], [before + 1, null]);
		first.lose(closed());
		await until(() => session.link?.live === true && session.link.generation !== generation, "the new link");
		for (let tick = 0; tick < 4 && letting.outcome == null; tick++) {
			await settle();
			clock.advance(RELEASE_ASK_MS);
		}
		await until(() => letting.outcome != null, "the release");
		const outcome = letting.outcome;
		assert(outcome?.status === "rejected", "a release past its bound was taken as released");
		assertEquals(failureView(outcome.reason).code, "local-change-busy");
		// The new link is asked at once and again at the deadline, as one link
		// is, and never after it.
		assertEquals(
			asks.filter((ask) => ask.startsWith("second")).length,
			2,
			"the new link is asked within the bound",
		);
	} finally {
		await session.close();
	}
});

Deno.test("each ask of a running release leaves no page waiter behind", async () => {
	const { session, asks, clock } = releasing(["running"]);
	try {
		await unconfirmed(session, "abandoned");
		await settle();
		const before = session.resources.waiters;
		const letting = watched(session.releaseOperation("abandoned"));
		const seen: number[] = [];
		for (let tick = 1; tick <= 4; tick++) {
			await settle();
			seen.push(session.resources.waiters - before);
			clock.advance(RELEASE_ASK_MS);
		}
		await settle();
		assertEquals([asks.length, letting.outcome], [5, null]);
		assertEquals(seen, [1, 1, 1, 1]);
	} finally {
		await session.close();
	}
});
