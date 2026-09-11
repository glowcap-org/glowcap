import { FRAME_BYTES_OFF, FRAME_LEN_OFF } from "../internal/constants.ts";
import { ffi, NULL } from "../internal/ffi/runtime.ts";
import { HostGc } from "../gc.ts";
import { GlowcapError } from "../errors.ts";
import { Host } from "../host.ts";
import {
	AsyncFfiFrame,
	AsyncFfiWriteQueue,
	checkedMaxFrameBytes,
	FrameDescriptorScratch,
} from "../transport/native_frame.ts";
import { deferred } from "../../dogfood/assert.ts";

async function assertRejectsWith(promise: Promise<unknown>, text: string): Promise<void> {
	try {
		await promise;
	} catch (error) {
		if (String(error).includes(text)) return;
		throw new Error(
			`expected rejection containing ${JSON.stringify(text)}, got ${String(error)}`,
		);
	}
	throw new Error(`expected rejection containing ${JSON.stringify(text)}`);
}

Deno.test("AsyncFfiFrame snapshots caller bytes before a queued native write", () => {
	const caller = new Uint8Array([1, 2, 3, 4]);
	const owned = new AsyncFfiFrame(caller, new FrameDescriptorScratch());
	caller.fill(9);

	const argument = owned.argument();
	const view = new DataView(argument.buffer);
	const pointer = view.getBigUint64(FRAME_BYTES_OFF, true);
	const length = Number(view.getBigUint64(FRAME_LEN_OFF, true));
	const bytes = [...new Uint8Array(ffi.readMemory(pointer, length))];
	if (JSON.stringify(bytes) !== JSON.stringify([1, 2, 3, 4])) {
		throw new Error(`expected owned frame bytes, got ${JSON.stringify(bytes)}`);
	}
});

Deno.test("AsyncFfiWriteQueue snapshots before queued execution", async () => {
	const caller = new Uint8Array([1, 2, 3, 4]);
	const queue = new AsyncFfiWriteQueue("test", 4);
	const writing = queue.run(caller, (owned) => {
		const argument = owned.argument();
		const view = new DataView(argument.buffer);
		const pointer = view.getBigUint64(FRAME_BYTES_OFF, true);
		const length = Number(view.getBigUint64(FRAME_LEN_OFF, true));
		const bytes = [...new Uint8Array(ffi.readMemory(pointer, length))];
		if (JSON.stringify(bytes) !== JSON.stringify([1, 2, 3, 4])) {
			throw new Error(`expected queued frame snapshot, got ${JSON.stringify(bytes)}`);
		}
		return Promise.resolve();
	});
	caller.fill(9);
	await writing;
});

Deno.test("AsyncFfiWriteQueue bounds retained payload bytes", async () => {
	const held = deferred();
	const queue = new AsyncFfiWriteQueue("test", 4);
	const first = queue.run(new Uint8Array(3), async () => await held.promise);
	await assertRejectsWith(
		queue.run(new Uint8Array(2), () => Promise.resolve()),
		"glowcap test outbound queue exceeded",
	);
	const filling = queue.run(new Uint8Array(1), () => Promise.resolve());
	held.resolve();
	await Promise.all([first, filling]);
	await queue.run(new Uint8Array(4), () => Promise.resolve());
});

Deno.test("AsyncFfiWriteQueue refuses one frame larger than its byte budget", async () => {
	const queue = new AsyncFfiWriteQueue("test", 4);
	await assertRejectsWith(
		queue.run(new Uint8Array(5), () => Promise.resolve()),
		"glowcap test outbound queue exceeded",
	);
});

Deno.test("AsyncFfiWriteQueue bounds zero-length write closures", async () => {
	const held = deferred();
	const queue = new AsyncFfiWriteQueue("test", 4);
	const admitted = Array.from(
		{ length: 16 },
		() => queue.run(new Uint8Array(0), async () => await held.promise),
	);
	await assertRejectsWith(
		queue.run(new Uint8Array(0), () => Promise.resolve()),
		"glowcap test outbound queue exceeded",
	);
	held.resolve();
	await Promise.all(admitted);
});

Deno.test("AsyncFfiWriteQueue releases admission before starting the next write", async () => {
	const held = deferred();
	const queue = new AsyncFfiWriteQueue("test", 5);
	let nested!: Promise<void>;
	const first = queue.run(new Uint8Array(4), async () => await held.promise);
	const second = queue.run(new Uint8Array(1), () => {
		nested = queue.run(new Uint8Array(1), () => Promise.resolve());
		return Promise.resolve();
	});
	held.resolve();
	await Promise.all([first, second]);
	await nested;
});

Deno.test("checkedMaxFrameBytes refuses values a usize waterline cannot represent", () => {
	for (const invalid of [0, -1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1]) {
		try {
			checkedMaxFrameBytes(invalid);
		} catch (error) {
			if (error instanceof TypeError) continue;
			throw error;
		}
		throw new Error(`expected ${invalid} to be refused`);
	}
});

Deno.test("HostGc retains a release token until the native release commits", () => {
	const gc = new HostGc();
	const abandoned: bigint[] = [];
	gc.bind({
		released: false,
		hostRaw: NULL,
		kick: () => {},
		recordFailure: () => {},
		abandonVow: (vow) => abandoned.push(vow),
		scheduleDrain: () => {},
	});
	gc.pending.push(17n);
	let first: unknown;
	try {
		gc.drainGc();
	} catch (failure) {
		first = failure;
	}
	if (!(first instanceof GlowcapError)) {
		throw new Error(`expected exact null-host refusal, got ${String(first)}`);
	}
	if (gc.pending.length !== 1 || gc.pending[0] !== 17n) {
		throw new Error(`refused release discarded its token: ${gc.pending}`);
	}

	gc.pending.length = 0;
	gc.pendingVows.push(19n);
	try {
		gc.drainGc();
	} catch {
		// The null Host is the deliberate native refusal.
	}
	if (gc.pendingVows.length !== 1 || gc.pendingVows[0] !== 19n) {
		throw new Error(`refused vow release discarded its token: ${gc.pendingVows}`);
	}
	if (abandoned.length !== 1 || abandoned[0] !== 19n) {
		throw new Error(`vow release did not abandon local observation: ${abandoned}`);
	}
});

Deno.test("HostGc retirement discards queues and ignores late finalizers", () => {
	const gc = new HostGc();
	gc.bind({
		released: false,
		hostRaw: NULL,
		kick: () => {},
		recordFailure: () => {},
		abandonVow: () => {
			throw new Error("retired GC touched vow state");
		},
		scheduleDrain: () => {
			throw new Error("retired GC scheduled native work");
		},
	});
	gc.pending.push(17n);
	gc.pendingVows.push(19n);
	gc.retire();
	gc.parkVow(23n);
	if (gc.pending.length !== 0 || gc.pendingVows.length !== 0) {
		throw new Error("retired GC retained finalizer work");
	}
});

Deno.test("HostGc retries scheduler refusal without duplicating a vow release", () => {
	const gc = new HostGc();
	let refuse = true;
	let scheduled = 0;
	gc.bind({
		released: false,
		hostRaw: NULL,
		kick: () => {},
		recordFailure: () => {},
		abandonVow: () => {},
		scheduleDrain: () => {
			if (refuse) {
				refuse = false;
				throw new Error("scheduler refused");
			}
			scheduled += 1;
		},
	});
	try {
		gc.parkVow(29n);
	} catch (failure) {
		if (String(failure).includes("scheduler refused")) {
			gc.parkVow(29n);
		} else {
			throw failure;
		}
	}
	if (gc.pendingVows.length !== 1 || gc.pendingVows[0] !== 29n) {
		throw new Error(`scheduler retry duplicated vow release: ${gc.pendingVows}`);
	}
	if (scheduled !== 1) throw new Error("retained vow release was not rescheduled");
});

Deno.test("Host surfaces one exact detached runtime failure at the next verb head", async () => {
	const host = new Host();
	const failure = new Error("detached task failed");
	try {
		await host.startDialTask(1n, 0n, () => Promise.reject(failure));
		let surfaced: unknown;
		try {
			host.drainGc();
		} catch (error) {
			surfaced = error;
		}
		if (surfaced !== failure) throw new Error(`lost exact detached failure: ${String(surfaced)}`);
		host.drainGc();
	} finally {
		await host.close();
	}
});

Deno.test("Host enliven refuses after native handle retirement", async () => {
	const host = new Host();
	await host.close();
	await assertRejectsWith(host.enliven("ocapn://example.invalid.tcp/s"), "host released");
});
