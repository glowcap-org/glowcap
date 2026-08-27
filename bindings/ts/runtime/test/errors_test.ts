import { retainCleanupFailures, retainSecondaryFailure, secondaryFailureCount, secondaryFailures } from "../errors.ts";
import { assert } from "../../dogfood/assert.ts";

Deno.test("secondary failures retain the exact primary, including when frozen", () => {
	const primary = Object.freeze(new Error("primary"));
	const cleanup = new Error("cleanup");
	assert(retainSecondaryFailure(primary, cleanup) === primary, "the primary error identity changed");
	assert(secondaryFailures(primary).length === 1, "the cleanup failure was not retained");
	assert(secondaryFailures(primary)[0] === cleanup, "the exact cleanup error identity changed");
});

Deno.test("secondary failure retention is bounded and reports the full count", () => {
	const primary = new Error("primary");
	for (let index = 0; index < 65; index++) {
		retainSecondaryFailure(primary, new Error(`cleanup ${index}`));
	}
	assert(secondaryFailures(primary).length === 64, "secondary retention exceeded its bound");
	assert(secondaryFailureCount(primary) === 65, "secondary loss was not reported");
	assert((secondaryFailures(primary)[0] as Error).message === "cleanup 0", "the first consequence moved");
});

Deno.test("repeated cleanup failures remain ordered without duplicating the primary", () => {
	const primary = new Error("primary");
	const first = new Error("first cleanup");
	const second = new Error("second cleanup");
	retainSecondaryFailure(primary, primary);
	retainSecondaryFailure(primary, first);
	retainSecondaryFailure(primary, second);
	assert(secondaryFailures(primary).length === 2, "the retained cleanup count is wrong");
	assert(secondaryFailures(primary)[0] === first, "the first cleanup failure moved");
	assert(secondaryFailures(primary)[1] === second, "the second cleanup failure moved");
});

Deno.test("rollback runs every cleanup and preserves construction as primary", async () => {
	const primary = new Error("construction failed");
	const listener = new Error("listener cleanup failed");
	const loop = new Error("loop cleanup failed");
	const order: string[] = [];
	const retained = await retainCleanupFailures(primary, [
		() => {
			order.push("listener");
			throw listener;
		},
		() => {
			order.push("loop");
			return Promise.reject(loop);
		},
	]);
	assert(retained === primary, "rollback replaced the construction failure");
	assert(order.join(",") === "listener,loop", "rollback skipped or reordered an owner");
	assert(secondaryFailures(primary)[0] === listener, "listener cleanup did not stay first");
	assert(secondaryFailures(primary)[1] === loop, "loop cleanup was not retained");
});
