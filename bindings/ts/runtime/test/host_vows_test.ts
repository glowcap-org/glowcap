import { CLOSED, INTERNAL } from "@glowcap/abi";
import { GlowcapError } from "../errors.ts";
import { Host } from "../host.ts";
import { awaitMinted, type PromiseFactoryHandle, promiseFor } from "../promise.ts";
import { type LoopChannel, Session } from "../session.ts";
import { refFromId } from "../value.ts";
import { assert, assertRejects } from "../../test/assert.ts";

async function assertRejectsCode(promise: Promise<unknown>, code: number): Promise<void> {
	const error = await assertRejects(() => promise);
	assert(error instanceof GlowcapError, "rejection was not a GlowcapError");
	assert(error.code === code, `expected ${code}, got ${error.code}`);
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
		const failure = new GlowcapError(INTERNAL, "driver loop failed");

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

Deno.test("promise adoption parks FFI release at every post-mint failure", () => {
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
		assert(parked.length === 1 && parked[0] === 19n, `${failing}: FFI vow was not released`);
	}
});

Deno.test("send admission preserves the exact failure through every dependent handle", async () => {
	const cause = new Error("scheduler refused progress");
	for (const failure of [new Error("admission failed", { cause }), { cause }, null, undefined]) {
		const host = {
			registerSession() {},
			drainGc() {
				throw failure;
			},
		} as unknown as Host;
		const session = Session.adoptLoopSession(1n, host, {} as LoopChannel);
		// Admission must return a handle even for a non-Error raised value. No
		// argument projection or FFI effect can happen after this refusal.
		const pending = session.send(refFromId(1n), "get");
		const dependent = pending.untag("row").index(0).get("value");
		const nextHost = {
			registerSession() {},
			drainGc() {},
			hosted: new Map(),
		} as unknown as Host;
		const next = Session.adoptLoopSession(2n, nextHost, {} as LoopChannel);
		const pipelined = next.send(pending, "get");
		for (const handle of [pending, dependent, pipelined]) {
			const observed = await handle.then(
				() => ({ ok: true as const }),
				(error: unknown) => ({ ok: false as const, error }),
			);
			assert(!observed.ok && observed.error === failure, "send replaced the originating failure");
		}
	}
});

for (const mode of ["minted", "remote"] as const) {
	for (const progress of ["reject", "throw", "late"] as const) {
		Deno.test(`${mode} vow observation owns settlement after progress ${progress}`, async () => {
			const failure = new GlowcapError(CLOSED, "session closing");
			let rejectSettlement!: (failure: unknown) => void;
			const settled = new Promise<null>((_resolve, reject) => rejectSettlement = reject);
			const unhandled: Promise<unknown>[] = [];
			const record = (event: PromiseRejectionEvent) => {
				event.preventDefault();
				unhandled.push(event.promise);
			};
			const parked: bigint[] = [];
			const handle: PromiseFactoryHandle = {
				ptr: 0n,
				hostRaw: 0n,
				hostOwner: {},
				vowMinted() {},
				attend() {},
				awaitVow: () => settled,
				kickActions: () => {
					if (progress === "late") setTimeout(() => rejectSettlement(failure), 0);
					else rejectSettlement(failure);
					if (progress === "throw") throw failure;
					return Promise.reject(failure);
				},
				parkVowRelease: (vow) => parked.push(vow),
				scheduleProgress() {},
				trackVow() {},
				recordBackgroundFailure(error) {
					throw error;
				},
			};
			globalThis.addEventListener("unhandledrejection", record);
			try {
				const observed = mode === "minted" ? awaitMinted(handle, 31n, false) : promiseFor(handle, 31n);
				const failures = await Promise.allSettled([observed, observed.then((value) => value)]);
				assert(
					failures.every((outcome) => outcome.status === "rejected" && outcome.reason === failure),
					`${mode}: observation replaced the primary failure`,
				);
				await new Promise((resolve) => setTimeout(resolve, 0));
				assert(
					!unhandled.includes(settled),
					`${mode}: native vow settlement was orphaned after progress failed`,
				);
				assert(unhandled.length === 0, `${mode}: an internal observation escaped`);
				assert(parked.length === (mode === "minted" ? 1 : 0), `${mode}: vow release ownership changed`);
			} finally {
				globalThis.removeEventListener("unhandledrejection", record);
			}
		});
	}
}

Deno.test("vow observation drives progress before waiting for a successful settlement", async () => {
	let resolveSettlement!: (value: null) => void;
	const settled = new Promise<null>((resolve) => resolveSettlement = resolve);
	let releaseProgress!: () => void;
	const progress = new Promise<void>((resolve) => releaseProgress = resolve);
	let kicked!: () => void;
	const didKick = new Promise<void>((resolve) => kicked = resolve);
	const handle = {
		ptr: 0n,
		vowMinted() {},
		attend() {},
		awaitVow: () => settled,
		kickActions: () => {
			resolveSettlement(null);
			kicked();
			return progress;
		},
		parkVowRelease() {},
	};
	let completed = false;
	const result = awaitMinted(handle, 37n, false).then((value) => {
		completed = true;
		return value;
	});
	await didKick;
	await new Promise((resolve) => setTimeout(resolve, 0));
	assert(!completed, "settlement returned before its required progress completed");
	releaseProgress();
	assert(await result === null, "the driven settlement changed its value");
});

for (const first of ["settlement", "progress"] as const) {
	Deno.test(`vow observation preserves the first ${first} failure`, async () => {
		const settlementFailure = new Error("remote settlement failed");
		const progressFailure = new Error("local progress failed");
		let rejectSettlement!: (error: unknown) => void;
		const settled = new Promise<null>((_resolve, reject) => rejectSettlement = reject);
		let rejectProgress!: (error: unknown) => void;
		const progress = new Promise<void>((_resolve, reject) => rejectProgress = reject);
		const handle = {
			ptr: 0n,
			vowMinted() {},
			attend() {},
			awaitVow: () => settled,
			kickActions: () => progress,
			parkVowRelease() {},
		};
		const observed = Promise.allSettled([awaitMinted(handle, 41n, false)]);
		if (first === "settlement") rejectSettlement(settlementFailure);
		else rejectProgress(progressFailure);
		const [outcome] = await observed;
		const expected = first === "settlement" ? settlementFailure : progressFailure;
		assert(outcome.status === "rejected" && outcome.reason === expected, "first failure identity changed");
		if (first === "settlement") rejectProgress(progressFailure);
		else rejectSettlement(settlementFailure);
		await new Promise((resolve) => setTimeout(resolve, 0));
	});
}
