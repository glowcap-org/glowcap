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

Deno.test("a reopened control's press starts fresh work instead of joining the stopped run", async () => {
	const signals: AbortSignal[] = [];
	const first = deferred<void>();
	const second = deferred<void>();
	const { run, changes } = action((signal) => {
		signals.push(signal);
		return signals.length === 1 ? first.promise : second.promise;
	});
	const stopped = run.run();
	run.close();
	run.reopen();
	const before = changes();
	const fresh = run.run();
	assertEquals([stopped === fresh, signals.length, run.busy], [false, 2, true]);
	assertEquals(signals[1].aborted, false);
	first.resolve();
	await stopped;
	assertEquals(run.busy, true);
	second.resolve();
	await fresh;
	assertEquals([run.busy, changes() > before], [false, true]);
});

Deno.test("a synchronous throw is a refusal, not an escaped exception", async () => {
	const { run } = action(() => {
		throw new Error("no held control");
	});
	await run.run();
	assertEquals(run.why.includes("no held control"), true);
});
