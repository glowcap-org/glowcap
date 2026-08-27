import { CLOSED, INTERNAL } from "@pancake/abi";
import { PancakeError } from "../errors.ts";
import { Host } from "../host.ts";
import { type PromiseFactoryHandle, promiseFor } from "../promise.ts";
import { assert } from "../../dogfood/assert.ts";

async function assertRejectsCode(promise: Promise<unknown>, code: number): Promise<void> {
	try {
		await promise;
	} catch (error) {
		assert(error instanceof PancakeError, "rejection was not a PancakeError");
		assert(error.code === code, `expected ${code}, got ${error.code}`);
		return;
	}
	throw new Error("promise resolved");
}

Deno.test("Host vow table evicts unobserved outcomes without shifting the FIFO", async () => {
	const host = new Host();
	try {
		for (let vow = 0n; vow < 4096n; vow++) {
			host.vowMinted(vow);
			host.settleVow(vow, { ok: null });
		}
		const fifo = host as unknown as { _unobserved: bigint[]; _unobservedHead: number };

		await assertRejectsCode(host.awaitVow(0n), CLOSED);
		assert(await host.awaitVow(3072n) === null, "newest retained outcome changed");
		assert(fifo._unobserved.length <= 2048, "unobserved FIFO retained more than two windows");
		assert(fifo._unobservedHead < 1024, "unobserved FIFO head was not compacted");
	} finally {
		await host.close();
	}
});

Deno.test("Host vow table keeps terminal failure for late loop observers", async () => {
	const host = new Host();
	try {
		host.vowMinted(7n);
		const failure = new PancakeError(INTERNAL, "driver loop failed");

		host.failPendingVows(failure);

		await assertRejectsCode(host.awaitVow(7n), INTERNAL);
	} finally {
		await host.close();
	}
});

Deno.test("abandoning a public promise drops its pending completion row", async () => {
	const host = new Host();
	try {
		host.vowMinted(11n);
		host.abandonVow(11n);
		await assertRejectsCode(host.awaitVow(11n), CLOSED);
	} finally {
		await host.close();
	}
});

Deno.test("promise adoption parks native release at every post-mint failure", () => {
	for (const failing of ["mint", "attend", "schedule", "track"] as const) {
		const failure = new Error(failing);
		const parked: bigint[] = [];
		const handle = {
			ptr: null,
			hostRaw: null,
			hostOwner: {},
			vowMinted: () => {
				if (failing === "mint") throw failure;
			},
			attend: () => {
				if (failing === "attend") throw failure;
			},
			awaitVow: () => Promise.resolve(null),
			kickActions: () => Promise.resolve(),
			parkVowRelease: (vow: bigint) => parked.push(vow),
			scheduleProgress: () => {
				if (failing === "schedule") throw failure;
			},
			trackVow: () => {
				if (failing === "track") throw failure;
			},
		} as unknown as PromiseFactoryHandle;

		let observed: unknown = null;
		try {
			promiseFor(handle, 19n);
		} catch (error) {
			observed = error;
		}
		assert(observed === failure, `${failing}: adoption replaced its failure`);
		assert(parked.length === 1 && parked[0] === 19n, `${failing}: native vow was not released`);
	}
});
