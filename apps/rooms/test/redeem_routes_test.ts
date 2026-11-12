// Redeem-route scheduling bounds active and queued work while giving each directory a turn.
import { RedeemRouteCoordinator } from "../lib/redeem_routes.ts";
import { Directory } from "../lib/directory.ts";
import { Ref } from "@glowcap/runtime";
import { Unanswered } from "../lib/deadline.ts";
import { assert } from "./assert.ts";

Deno.test("redeem routes batch one directory and give the next directory its turn", async () => {
	const routes = new RedeemRouteCoordinator<object>(4, 1_000);
	const first = {};
	const second = {};
	const one = Promise.withResolvers<void>();
	const two = Promise.withResolvers<void>();
	const later = Promise.withResolvers<void>();
	const running: string[] = [];
	const firstOne = routes.run(first, new AbortController().signal, async () => {
		running.push("first-one");
		await one.promise;
	});
	const firstTwo = routes.run(first, new AbortController().signal, async () => {
		running.push("first-two");
		await two.promise;
	});
	const secondOne = routes.run(second, new AbortController().signal, async () => {
		running.push("second");
		await later.promise;
	});
	await Promise.resolve();
	assert(running.join() === "first-one,first-two", `a second route entered the active batch: ${running}`);
	assert(routes.current() === first, "the coordinator did not name the active redeem route");
	one.resolve();
	await firstOne;
	await Promise.resolve();
	assert(running.length === 2, "a second route entered before the active batch drained");
	two.resolve();
	await firstTwo;
	await Promise.resolve();
	assert(running.at(-1) === "second", "the next directory never received the redeem route");
	assert(routes.current() === second, "the coordinator did not rotate to the waiting route");
	later.resolve();
	await secondOne;
	assert(routes.current() === null, "the coordinator retained a drained route");
});

Deno.test("redeem routes bound active and waiting work together", async () => {
	const routes = new RedeemRouteCoordinator<object>(2, 1_000);
	const route = {};
	const first = Promise.withResolvers<void>();
	const second = Promise.withResolvers<void>();
	const a = routes.run(route, new AbortController().signal, () => first.promise);
	const b = routes.run(route, new AbortController().signal, () => second.promise);
	await Promise.resolve();
	const refusal = await routes.run(route, new AbortController().signal, () => Promise.resolve()).then(
		() => "",
		(error) => error instanceof Error ? error.message : String(error),
	);
	assert(refusal.includes("at most 2"), `redeem overflow answered ${refusal || "success"}`);
	first.resolve();
	second.resolve();
	await Promise.all([a, b]);
});

Deno.test("a queued redeem times out or aborts without retaining its seat", async () => {
	const routes = new RedeemRouteCoordinator<object>(3, 5);
	const activeRoute = {};
	const waitingRoute = {};
	const active = Promise.withResolvers<void>();
	const running = routes.run(activeRoute, new AbortController().signal, () => active.promise);
	await Promise.resolve();
	const timedOut = await routes.run(waitingRoute, new AbortController().signal, () => Promise.resolve()).then(
		() => null,
		(error) => error,
	);
	assert(timedOut instanceof Unanswered, `a queued redeem timed out as ${timedOut}`);
	const closing = new AbortController();
	const aborted = routes.run(waitingRoute, closing.signal, () => Promise.resolve()).then(
		() => "",
		(error) => error instanceof Error ? error.message : String(error),
	);
	closing.abort(new Error("directory connection ended"));
	assert((await aborted) === "directory connection ended", "directory close did not cancel its queued redeem");
	active.resolve();
	await running;
	assert(routes.current() === null, "timed-out or aborted work retained a redeem route");
});

Deno.test("a queued introduction retains its server-wait and redeem budgets after admission", async () => {
	const { INTRODUCTION_TIMEOUT_MS, REQUEST_TIMEOUT_MS } = await import("../lib/limits.ts");
	const realTimeout = globalThis.setTimeout;
	const realClear = globalThis.clearTimeout;
	let now = 0;
	let sequence = 0;
	const timers = new Map<number, { due: number; fire: () => void }>();
	globalThis.setTimeout = ((handler: TimerHandler, delay = 0, ...args: unknown[]) => {
		assert(typeof handler === "function", "the fixture schedules functions");
		const id = ++sequence;
		timers.set(id, { due: now + delay, fire: () => handler(...args) });
		return id;
	}) as typeof setTimeout;
	globalThis.clearTimeout = (id) => {
		if (typeof id === "number") timers.delete(id);
		else realClear(id);
	};
	const advance = async (elapsed: number) => {
		now += elapsed;
		for (const [id, timer] of timers) {
			if (timer.due <= now) {
				timers.delete(id);
				timer.fire();
			}
		}
		await new Promise<void>((resolve) => realTimeout(resolve, 0));
	};
	const fixtures: { directory: Directory; finish: () => void; started: Promise<void> }[] = [];
	const pending: Promise<unknown>[] = [];
	try {
		for (let i = 0; i < 2; i++) {
			const inbox = Object.create(Ref.prototype) as Ref;
			const started = Promise.withResolvers<void>();
			const answer = Promise.withResolvers<{ reply: Ref; via: null }>();
			const session = {
				serve: () => Promise.resolve(),
				fetch: () => Promise.resolve(inbox),
				sendRedeeming: () => {
					started.resolve();
					return answer.promise;
				},
				release() {},
				close: () => Promise.resolve(),
			} as unknown as import("@glowcap/runtime").Session;
			fixtures.push({
				directory: await Directory.connect("ocapn://fixture.tcp", () => Promise.resolve(session)),
				finish: () => answer.resolve({ reply: inbox, via: null }),
				started: started.promise,
			});
		}
		const opening = (index: number) =>
			fixtures[index].directory.introduceVia("bob", "11111111-1111-4111-8111-111111111111")
				.then(() => "complete", (error) => error);
		const first = opening(0);
		pending.push(first);
		await fixtures[0].started;
		const second = opening(1);
		pending.push(second);
		await advance(REQUEST_TIMEOUT_MS - 1);
		fixtures[0].finish();
		assert(await first === "complete", "the active introduction must finish before queue admission expires");
		await fixtures[1].started;
		await advance(INTRODUCTION_TIMEOUT_MS - 1);
		fixtures[1].finish();
		assert(await second === "complete", "queue residence and server waiting must not consume the redeem budget");
	} finally {
		for (const fixture of fixtures) fixture.finish();
		await Promise.allSettled(pending);
		for (const fixture of fixtures) await fixture.directory.close();
		globalThis.setTimeout = realTimeout;
		globalThis.clearTimeout = realClear;
	}
});

Deno.test("an expired claim keeps its signaling route until the late redeem settles", async () => {
	const routes = new RedeemRouteCoordinator<object>(2, 1_000);
	const first = {};
	const second = {};
	const answer = Promise.withResolvers<string>();
	const abandoned: string[] = [];
	const result = await routes.claim(first, new AbortController().signal, () => answer.promise, {
		what: "held redeem",
		timeoutMs: 1,
		abandon: (late) => {
			abandoned.push(late);
		},
	}).catch((error) => error);
	assert(result instanceof Unanswered, "the caller's claim expires");
	assert(routes.current() === first, "an unsettled redeem still owns its signaling route");
	let entered = false;
	const later = routes.run(second, new AbortController().signal, () => {
		entered = true;
		return Promise.resolve();
	});
	await Promise.resolve();
	assert(!entered, "another directory must not supply authority to the late redeem");
	answer.resolve("late capability");
	await later;
	assert(entered && abandoned.join() === "late capability", "the late result has one cleanup owner");
	assert(routes.current() === null, "both route reservations retire");
});
