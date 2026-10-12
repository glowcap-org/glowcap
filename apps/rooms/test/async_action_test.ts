// A control's asynchronous work runs once per press, reports its refusal, and
// says nothing after the reader stops it or the control goes away.
import { assertEquals } from "./assert.ts";
import { deferred } from "./support/managed_viewer.ts";
import { ActionRun } from "../web/ui/async_action.ts";

function action(work: (signal: AbortSignal) => Promise<unknown>) {
	let changes = 0;
	const run = new ActionRun(() => work, () => changes++);
	return { run, changes: () => changes };
}

Deno.test("a second press while the work runs is the same press", async () => {
	const done = deferred<void>();
	let started = 0;
	const { run } = action(() => {
		started++;
		return done.promise;
	});
	const first = run.run();
	const second = run.run();
	assertEquals(first === second, true);
	assertEquals([started, run.busy], [1, true]);
	done.resolve();
	await first;
	assertEquals([run.busy, run.why], [false, ""]);
});

Deno.test("a refusal is kept until the next press or an edit clears it", async () => {
	const { run } = action(() => Promise.reject(new Error("the directory refused")));
	await run.run();
	assertEquals(run.why.includes("the directory refused"), true);
	run.clear();
	assertEquals(run.why, "");
});

Deno.test("a stopped run reports nothing", async () => {
	const { run } = action((signal) =>
		new Promise((_, reject) => signal.addEventListener("abort", () => reject(new Error("aborted"))))
	);
	const pending = run.run();
	run.cancel();
	await pending;
	assertEquals([run.busy, run.why], [false, ""]);
});

Deno.test("a closed control aborts its run and repaints nothing after it", async () => {
	let seen: AbortSignal | null = null;
	const done = deferred<void>();
	const { run, changes } = action((signal) => {
		seen = signal;
		return done.promise;
	});
	const pending = run.run();
	const before = changes();
	run.close();
	assertEquals(seen!.aborted, true);
	done.resolve();
	await pending;
	assertEquals(changes(), before);
	await run.run();
	assertEquals(changes(), before);
});

Deno.test("stop and remount retain the worker until it drains", async () => {
	const done = deferred<void>();
	let started = 0;
	const { run } = action(() => {
		started++;
		return done.promise;
	});
	const first = run.run();
	run.cancel();
	assertEquals(run.run() === first, true);
	run.close();
	run.reopen();
	assertEquals(run.run() === first, true);
	assertEquals([started, run.busy], [1, true]);
	done.resolve();
	await first;
	await run.run();
	assertEquals([started, run.busy], [2, false]);
});

Deno.test("a synchronous throw is a refusal, not an escaped exception", async () => {
	const { run } = action(() => {
		throw new Error("no held control");
	});
	await run.run();
	assertEquals(run.why.includes("no held control"), true);
});

import { PRESENTATION, PresentationRun } from "../web/ui/presentation.ts";

for (const delay of [PRESENTATION.busy, PRESENTATION.sending, PRESENTATION.connection]) {
	Deno.test(`progress appears at ${delay}ms and retired timers cannot paint a later run`, () => {
		let now = 0;
		let changes = 0;
		const callbacks: (() => void)[] = [];
		const timers = new Set<symbol>();
		const run = new PresentationRun(() => changes++, {
			now: () => now,
			later: (callback) => {
				const token = Symbol();
				timers.add(token);
				callbacks.push(() => {
					timers.delete(token);
					callback();
				});
				return () => {
					timers.delete(token);
				};
			},
		});
		run.start("first", delay);
		now = delay - 1;
		assertEquals(run.visible("first", delay), false);
		now++;
		assertEquals(run.visible("first", delay), true);
		callbacks.shift()!();
		assertEquals(run.remaining, PRESENTATION.feedback);
		run.start("second", delay);
		assertEquals(run.visible("first", delay), false);
		assertEquals(run.visible("second", delay), false);
		const old = callbacks.shift()!;
		run.close();
		run.start("third", delay);
		const before = changes;
		now += delay * 10;
		old();
		assertEquals(changes, before);
		assertEquals(run.visible("third", delay), true);
		run.close();
		assertEquals(timers.size, 0);
	});
}

Deno.test("background wake starts the feedback slot when progress is actually drawn", () => {
	let now = 0;
	const run = new PresentationRun(() => {}, { now: () => now, later: () => () => {} });
	run.start("sleeping", PRESENTATION.busy);
	now = 10_000;
	assertEquals(run.visible("sleeping", PRESENTATION.busy), true);
	assertEquals(run.remaining, 500);
	now += 499;
	assertEquals(run.remaining, 1);
	run.close();
	assertEquals(run.visible("sleeping", PRESENTATION.busy), false);
	assertEquals(run.remaining, 0);
});
