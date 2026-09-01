import { claimRedeemWithin, RedeemRouteCoordinator } from "../lib/redeem_routes.ts";
import { Unanswered } from "../lib/deadline.ts";

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}

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

Deno.test("a redeem answer arriving after its deadline is handed to cleanup", async () => {
	const redemption = Promise.withResolvers<string>();
	const abandoned: string[] = [];
	const failure = await claimRedeemWithin(redemption.promise, "the redeem did not answer", 5, (late) => {
		abandoned.push(late);
	}).then(
		() => null,
		(error) => error,
	);
	assert(failure instanceof Unanswered, `the redeem deadline answered ${failure}`);
	redemption.resolve("late capability");
	await Promise.resolve();
	await Promise.resolve();
	assert(abandoned.join() === "late capability", "the late redeem answer had no cleanup owner");
});
