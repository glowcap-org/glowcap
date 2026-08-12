import { FRAME_BYTES_OFF, FRAME_LEN_OFF } from "../internal/constants.ts";
import { ffi } from "../internal/ffi/runtime.ts";
import {
	AsyncFfiFrame,
	AsyncFfiWriteQueue,
	checkedMaxFrameBytes,
} from "../transport/native_frame.ts";

function deferred(): { promise: Promise<void>; resolve: () => void } {
	let resolve!: () => void;
	const promise = new Promise<void>((done) => {
		resolve = done;
	});
	return { promise, resolve };
}

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
	const owned = new AsyncFfiFrame(caller);
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
		"pancake test outbound queue exceeded",
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
		"pancake test outbound queue exceeded",
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
		"pancake test outbound queue exceeded",
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
