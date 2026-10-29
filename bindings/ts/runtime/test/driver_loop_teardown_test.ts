import { INTERNAL } from "@glowcap/abi";
import { DriverLoop } from "../driver_loop.ts";
import { GlowcapError } from "../errors.ts";
import { Host } from "../host.ts";
import type { Session } from "../session.ts";
import { assert } from "../../dogfood/assert.ts";

Deno.test("close runs each retained release once in order and records a throwing one", async () => {
	const host = new Host();
	const loop = DriverLoop.takeHost(host);
	const ran: string[] = [];
	const refusal = new Error("release refused");
	loop.retainUntilTeardown(() => {
		ran.push("first");
	});
	loop.retainUntilTeardown(() => {
		ran.push("second");
		throw refusal;
	});
	await loop.close();
	assert(ran.join() === "first,second", `releases ran as ${ran.join()}`);
	const retained = host.takeFailures().filter((f) => f.operation === "driver-loop.teardown.release");
	assert(retained.length === 1, `recorded ${retained.length} teardown failures`);
	assert(retained[0].primaryMessage === refusal.message, "the recorded failure is not the throw");
	await loop.close();
	assert(ran.length === 2, "a second close ran the releases again");
});

Deno.test("a background failure runs each retained release once", async () => {
	const host = new Host();
	const loop = DriverLoop.takeHost(host);
	let ran = 0;
	loop.retainUntilTeardown(() => {
		ran++;
	});
	const failure = new GlowcapError(INTERNAL, "driver loop failed");
	(loop as unknown as { _failBackground(error: unknown): void })._failBackground(failure);
	await loop.close().catch(() => {});
	await new Promise((resolve) => setTimeout(resolve, 0));
	assert(ran === 1, `the release ran ${ran} times`);
});

Deno.test("Host retirement invalidates the consumed handle before notifying session wrappers", async () => {
	for (const loopOwned of [false, true]) {
		const host = new Host();
		const owner = loopOwned ? DriverLoop.takeHost(host) : host;
		let notified = false;
		let ownerWasReleased = false;
		// A registry-only wrapper isolates the post-FFI notification boundary.
		// No protocol session is needed to observe the Host's handle validity.
		host.registerSession(host.raw, {
			ffiOwnerDidRelease: () => {
				notified = true;
				ownerWasReleased = host.released;
				return Promise.resolve();
			},
		} as Session);
		try {
			await owner.close();
			assert(notified, "Host teardown skipped its session wrapper");
			assert(
				ownerWasReleased,
				`the ${loopOwned ? "loop" : "Host"} exposed its consumed handle during notification`,
			);
		} finally {
			await owner.close().catch(() => {});
		}
	}
});
