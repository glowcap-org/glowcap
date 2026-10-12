// The wait that ends.
//
// Every request the rooms client makes to a room, a directory, or a peer goes
// through `answerWithin`. A partner that accepts a request and never answers is
// not a failure anything else can see, the send is in flight, the session is
// open, the promise is pending, so the wait itself is the only thing that can
// end it, and what this pins is that it does end, saying which request it was.
//
// The timer is pinned by hand rather than by the runner: a wait that never puts
// its timer down keeps an event loop scheduled for the full deadline after the
// answer already arrived, and the op sanitiser does not report it.

import { answerWithin, claimWithin, Unanswered } from "../lib/deadline.ts";
import { assertEquals } from "./assert.ts";

Deno.test("an answer that arrives is the answer, deadline or no deadline", async () => {
	const got = await answerWithin(Promise.resolve("here"), "a request nobody had to wait for", 10_000);
	assertEquals(got, "here");
});

Deno.test("a partner that never answers is given up on, and the wait says which request", async () => {
	let failure: unknown = null;
	try {
		await answerWithin(new Promise(() => {}), 'the room did not answer "post"', 20);
	} catch (error) {
		failure = error;
	}
	assertEquals(failure instanceof Unanswered, true, `waiting ended as ${failure}`);
	assertEquals(
		String(failure).includes('did not answer "post"'),
		true,
		`the wait did not say which request it was: ${failure}`,
	);
});

Deno.test("a refusal that arrives first is the refusal, not a deadline", async () => {
	// The reason a room gives for saying no is the one worth showing. Replacing
	// it with "nobody answered" would be a worse answer than the one there was.
	let failure: unknown = null;
	try {
		await answerWithin(Promise.reject(new Error("name is already claimed")), "the room did not answer", 10_000);
	} catch (error) {
		failure = error;
	}
	assertEquals(failure instanceof Unanswered, false, "a refusal was reported as a partner that went quiet");
	assertEquals(String(failure).includes("already claimed"), true, `the room's own reason was lost: ${failure}`);
});

Deno.test("an answer that arrives late, after the wait ended, is not an unhandled rejection", async () => {
	// The abandoned request stays outstanding: there is nothing to cancel it
	// with. Its later failure must stay handled, or a partner answering slowly
	// would take the tab down some time after the row it belonged to gave up.
	let late: (reason: Error) => void = () => {};
	const answer = new Promise<never>((_, reject) => {
		late = reject;
	});
	let failure: unknown = null;
	try {
		await answerWithin(answer, "the room did not answer", 10);
	} catch (error) {
		failure = error;
	}
	assertEquals(failure instanceof Unanswered, true, `waiting ended as ${failure}`);
	late(new Error("answered at last, to nobody"));
	// A tick, so an unhandled rejection would have been reported by now.
	await new Promise((resolve) => setTimeout(resolve, 5));
});

Deno.test("an owned answer that arrives after its deadline is transferred to cleanup", async () => {
	const answer = Promise.withResolvers<string>();
	const abandoned: string[] = [];
	let cancelled = false;
	const failure = await claimWithin(
		(signal) => {
			signal.addEventListener("abort", () => cancelled = true, { once: true });
			return answer.promise;
		},
		"the claimed answer did not arrive",
		5,
		(late) => {
			abandoned.push(late);
		},
	).then(
		() => null,
		(error) => error,
	);
	assertEquals(failure instanceof Unanswered, true, `the claim deadline answered ${failure}`);
	assertEquals(cancelled, true, "the claimed operation was not cancelled at its deadline");
	answer.resolve("late capability");
	await Promise.resolve();
	await Promise.resolve();
	assertEquals(abandoned, ["late capability"], "the late answer had no cleanup owner");
});

Deno.test("a wait that ends puts its timer down", async () => {
	// Every request goes through here, so a timer left armed for the full
	// deadline after its answer arrived is one per request: a CLI that will not
	// exit, and a tab whose event loop is woken for nothing. Counted through the
	// globals because there is nothing else from outside that can see it.
	const realSetTimeout = globalThis.setTimeout;
	const realClearTimeout = globalThis.clearTimeout;
	let armed = 0;
	let cleared = 0;
	globalThis.setTimeout = ((run: () => void, ms: number) => {
		armed += 1;
		return realSetTimeout(run, ms);
		// deno-lint-ignore no-explicit-any
	}) as any;
	globalThis.clearTimeout = ((id: number) => {
		cleared += 1;
		realClearTimeout(id);
		// deno-lint-ignore no-explicit-any
	}) as any;
	try {
		await answerWithin(Promise.resolve("here"), "a request answered at once", 10_000);
	} finally {
		globalThis.setTimeout = realSetTimeout;
		globalThis.clearTimeout = realClearTimeout;
	}
	assertEquals(armed, 1, "the wait did not arm a deadline at all");
	assertEquals(cleared, 1, "the wait left its deadline armed after the answer arrived");
});
