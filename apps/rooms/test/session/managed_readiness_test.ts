// Direct readiness preserves early notices and refuses cancelled, closed or expired waits.
import { assert, assertEquals } from "../assert.ts";
import { viewer } from "../support/managed_viewer.ts";
import { READINESS_WAIT_MS, ReadinessNotices } from "../../web/ui/session/managed/readiness.ts";
import type { ReadinessNotice } from "../../web/ui/session/managed/readiness.ts";
import { Unanswered } from "../../lib/answer_within.ts";

const event: ReadinessNotice = {
	target: { kind: "directory", id: "directory" },
	notice: { kind: "introducible", registration: "peer", opening: "opening" },
};

Deno.test("closing a managed viewer refuses its pending readiness wait", async () => {
	const session = viewer({});
	const wait = session.waitNotice(() => true);
	const result = Promise.allSettled([wait.ready]);
	await session.close();
	assertEquals((await result)[0].status, "rejected");
});

Deno.test("readiness cancellation and closure refuse both active and unused waits", async () => {
	for (const closing of [false, true]) {
		for (const active of [false, true]) {
			const notices = new ReadinessNotices();
			const wait = notices.wait(() => true);
			const result = active ? Promise.allSettled([wait.ready]) : undefined;
			if (closing) notices.close();
			else wait.cancel();
			// An unused wait has no rejecting promise until its caller asks for it.
			await new Promise<void>((resolve) => setTimeout(resolve, 0));
			const outcome = (await (result ?? Promise.allSettled([wait.ready])))[0];
			assert(outcome.status === "rejected", "ending a wait must not report readiness");
			assertEquals(
				outcome.reason.message,
				closing ? "This workspace is closed" : "The readiness wait was cancelled",
			);
			notices.close();
		}
	}
});

Deno.test("only matching readiness settles a wait and an early match survives closure", async () => {
	const notices = new ReadinessNotices();
	const wait = notices.wait((notice) => notice.target.id === "directory");
	let ready = false;
	const result = wait.ready.then(() => ready = true);
	assert(wait.ready === wait.ready, "reading ready twice must share the wait");
	notices.notify({ ...event, target: { kind: "directory", id: "sibling" } });
	await Promise.resolve();
	assertEquals(ready, false);
	notices.notify(event);
	await result;

	const early = notices.wait(() => true);
	notices.notify(event);
	early.cancel();
	notices.close();
	await early.ready;
});

Deno.test("readiness admission is bounded and completed registrations release their slots", async () => {
	const notices = new ReadinessNotices();
	const waits = Array.from({ length: 32 }, () => notices.wait(() => true));
	let failure: unknown;
	try {
		notices.wait(() => true);
	} catch (error) {
		failure = error;
	}
	assert(failure instanceof Error, "the thirty-third wait must be refused");
	assertEquals(failure.message, "Too many retained protocol readiness waits");
	waits[0].cancel();
	const replacement = notices.wait(() => true);
	notices.notify(event);
	await Promise.all([...waits.slice(1), replacement].map((wait) => wait.ready));
	const next = Array.from({ length: 32 }, () => notices.wait(() => true));
	notices.close();
	assertEquals(
		(await Promise.allSettled(next.map((wait) => wait.ready))).map((result) => result.status),
		Array(32).fill("rejected"),
	);
	failure = undefined;
	try {
		notices.wait(() => true);
	} catch (error) {
		failure = error;
	}
	assert(failure instanceof Error, "a closed owner must refuse new waits");
	assertEquals(failure.message, "This workspace is closed");
});

Deno.test("readiness deadline begins when awaited and releases its registration on expiry", async () => {
	const realSetTimeout = globalThis.setTimeout;
	const realClearTimeout = globalThis.clearTimeout;
	let expire = () => {};
	let armed = 0;
	let cleared = 0;
	globalThis.setTimeout = ((run: () => void, ms: number) => {
		assertEquals(ms, READINESS_WAIT_MS);
		armed += 1;
		expire = run;
		return 1;
	}) as unknown as typeof setTimeout;
	globalThis.clearTimeout = ((id: number) => {
		assertEquals(id, 1);
		cleared += 1;
	}) as typeof clearTimeout;
	const notices = new ReadinessNotices();
	try {
		const waits = Array.from({ length: 32 }, () => notices.wait(() => true));
		assertEquals(armed, 0);
		const result = Promise.allSettled([waits[0].ready]);
		assertEquals(armed, 1);
		expire();
		const outcome = (await result)[0];
		assert(outcome.status === "rejected" && outcome.reason instanceof Unanswered, "expiry must report a deadline");
		assertEquals(cleared, 1);
		const replacement = notices.wait(() => true);
		notices.notify(event);
		await replacement.ready;
		assertEquals(cleared, 2);
	} finally {
		notices.close();
		globalThis.setTimeout = realSetTimeout;
		globalThis.clearTimeout = realClearTimeout;
	}
});
