import {
	PublicationNotFound,
	retainCleanupFailures,
	retainSecondaryFailure,
	secondaryFailureCount,
	secondaryFailures,
	vowFailure,
} from "../errors.ts";
import { assert } from "../../test/assert.ts";
import { withCleanup } from "../cleanup.ts";

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
	await retainCleanupFailures(primary, [
		() => {
			order.push("listener");
			throw listener;
		},
		() => {
			order.push("loop");
			return Promise.reject(loop);
		},
	]);
	assert(order.join(",") === "listener,loop", "rollback skipped or reordered an owner");
	assert(secondaryFailures(primary)[0] === listener, "listener cleanup did not stay first");
	assert(secondaryFailures(primary)[1] === loop, "loop cleanup was not retained");
});

Deno.test("an unknown durable publication is a typed lifecycle failure", () => {
	const missing = vowFailure(-12, "unknown swissnum");
	assert(missing instanceof PublicationNotFound, "unknown swissnum remained protocol text");
	assert(missing.reason === "unknown swissnum", "the canonical wire break changed");
	assert(
		!(vowFailure(-12, "application refusal") instanceof PublicationNotFound),
		"an ordinary break was misclassified",
	);
});

Deno.test("constructor release preserves every primary and runs exactly once", async () => {
	for (const primary of [new Error("installation refused"), null, undefined, 0]) {
		const cleanup = new Error("release failed");
		let releases = 0;
		let caught = false;
		try {
			await withCleanup(() => {
				throw primary;
			}, () => {
				releases++;
				return Promise.reject(cleanup);
			});
		} catch (error) {
			caught = true;
			assert(Object.is(error, primary), "release replaced the installation failure");
		}
		assert(caught, "installation refusal resolved");
		assert(releases === 1, "constructor release was skipped or repeated");
		if (primary instanceof Error) {
			assert(secondaryFailures(primary)[0] === cleanup, "release failure was lost");
		}
	}
});

Deno.test("constructor success waits for release", async () => {
	const order: string[] = [];
	await withCleanup(() => {
		order.push("install");
	}, async () => {
		await Promise.resolve();
		order.push("release");
	});
	assert(order.join(",") === "install,release", "release barrier was not joined");
});

Deno.test("constructor release failure after success is returned without a retry", async () => {
	const cleanup = new Error("release failed");
	let releases = 0;
	let caught = false;
	try {
		await withCleanup(() => {}, () => {
			releases++;
			throw cleanup;
		});
	} catch (error) {
		caught = true;
		assert(error === cleanup, "release-only failure changed");
	}
	assert(caught && releases === 1, "release-only failure was hidden or retried");
});

Deno.test("rollback never assimilates a thrown thenable", async () => {
	let thenCalls = 0;
	const primary = Object.freeze({
		then() {
			thenCalls++;
			throw new Error("thrown reason was awaited");
		},
	});
	const cleanup = new Error("release failed");
	await retainCleanupFailures(primary, []);
	let caught = false;
	try {
		await withCleanup(() => {
			throw primary;
		}, () => Promise.reject(cleanup));
	} catch (error) {
		caught = true;
		assert(error === primary, "thenable reason was replaced");
	}
	assert(caught && thenCalls === 0, "rollback assimilated the primary reason");
	assert(secondaryFailures(primary)[0] === cleanup, "thenable primary lost its cleanup failure");
});
