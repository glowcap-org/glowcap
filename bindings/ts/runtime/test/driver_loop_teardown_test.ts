import { INTERNAL } from "@glowcap/abi";
import { DriverLoop } from "../driver_loop.ts";
import { GlowcapError, secondaryFailures } from "../errors.ts";
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

Deno.test("Host and loop close report failures raised during wrapper retirement", async () => {
	for (const loopOwned of [false, true]) {
		for (
			const failure of [
				new GlowcapError(INTERNAL, "wrapper retirement callback sentinel"),
				new Error("callback sentinel"),
				null,
				undefined,
				false,
				0,
				-0,
				NaN,
				"",
			]
		) {
			const host = new Host();
			const owner = loopOwned ? DriverLoop.takeHost(host) : host;
			host.registerSession(host.raw, {
				ffiOwnerDidRelease: () => {
					host.recordBackgroundFailure(failure);
					return Promise.resolve();
				},
			} as Session);
			try {
				let caught = false;
				let observed: unknown;
				try {
					await owner.close();
				} catch (error) {
					caught = true;
					observed = error;
				}
				assert(host.released, "the callback failure interrupted Host release");
				assert(caught && Object.is(observed, failure), "the close barrier lost its callback failure");
				let repeatedCaught = false;
				let repeated: unknown;
				try {
					await owner.close();
				} catch (error) {
					repeatedCaught = true;
					repeated = error;
				}
				assert(repeatedCaught && Object.is(repeated, failure), "repeated close changed its callback failure");
			} finally {
				await owner.close().catch(() => {});
			}
		}
	}
});

Deno.test("Host and loop close retain callback and transport consequences", async () => {
	for (const loopOwned of [false, true]) {
		const host = new Host();
		const owner = loopOwned ? DriverLoop.takeHost(host) : host;
		const primary = new Error("retained writer sentinel");
		const callback = new Error("retirement callback sentinel");
		const transport = new Error("transport close sentinel");
		host.recordBackgroundFailure(primary);
		host.registerSession(host.raw, {
			ffiOwnerDidRelease: () => {
				host.recordBackgroundFailure(callback);
				return Promise.reject(transport);
			},
		} as Session);
		try {
			let observed: unknown;
			try {
				await owner.close();
			} catch (error) {
				observed = error;
			}
			assert(host.released && observed === primary, "close replaced its primary failure");
			const secondary = secondaryFailures(primary);
			assert(
				secondary.length === 2 && secondary.includes(callback) && secondary.includes(transport),
				"close lost a callback or transport consequence",
			);
		} finally {
			await owner.close().catch(() => {});
		}
	}
});

Deno.test("Host and loop close join a channel unregistered during progress", async () => {
	for (const loopOwned of [false, true]) {
		const host = new Host();
		const owner = loopOwned ? DriverLoop.takeHost(host) : host;
		const raw = host.raw;
		const wrapper = { ffiOwnerDidRelease: () => Promise.resolve() } as Session;
		host.registerSession(raw, wrapper);
		const failure = new Error("unregistered channel retirement sentinel");
		const retirement = Promise.reject(failure);
		void retirement.catch(() => {});
		try {
			const closing = owner.close();
			// Model a wrapper retiring while the close driver awaits progress.
			// Its physical close still needs an observer after leaving the registry.
			host.unregisterSession(raw, wrapper);
			host.trackSessionRetirement(retirement);
			let observed: unknown;
			try {
				await closing;
			} catch (error) {
				observed = error;
			}
			assert(host.released && observed === failure, "close lost the unregistered channel's outcome");
		} finally {
			await owner.close().catch(() => {});
		}
	}
});
