// Session writes over bounded channels, retirement callbacks, and task failures.
import { CLOSED, CODEC, DESIGNATOR_SCHEME_ADDRESS, DESIGNATOR_SCHEME_KEY, FRAME_TOO_LARGE } from "@glowcap/abi";
import { GlowcapError, secondaryFailures } from "../errors.ts";
import { Host } from "../host.ts";
import { bareLocator } from "../locator.ts";
import { type Channel, Session } from "../session.ts";
import { assert } from "../../dogfood/assert.ts";

/** One direction of an in-memory stream that holds at most `capacity` bytes,
 * so a writer waits until the reader takes what is buffered. */
class Pipe {
	readonly #capacity: number;
	#chunks: Uint8Array[] = [];
	#size = 0;
	#closed = false;
	#waiters: Array<() => void> = [];

	constructor(capacity: number) {
		this.#capacity = capacity;
	}

	async write(data: Uint8Array): Promise<void> {
		let offset = 0;
		while (offset < data.length) {
			if (this.#closed) throw new Error("pipe closed");
			const room = this.#capacity - this.#size;
			if (room === 0) {
				await this.#changed();
				continue;
			}
			const end = Math.min(data.length, offset + room);
			this.#chunks.push(data.slice(offset, end));
			this.#size += end - offset;
			offset = end;
			this.#wake();
		}
	}

	async read(): Promise<Uint8Array | null> {
		while (true) {
			const chunk = this.#chunks.shift();
			if (chunk != null) {
				this.#size -= chunk.length;
				this.#wake();
				return chunk;
			}
			if (this.#closed) return null;
			await this.#changed();
		}
	}

	close(): void {
		this.#closed = true;
		this.#wake();
	}

	#changed(): Promise<void> {
		return new Promise((resolve) => this.#waiters.push(resolve));
	}

	#wake(): void {
		const waiters = this.#waiters;
		this.#waiters = [];
		for (const resolve of waiters) resolve();
	}
}

function channelPair(capacity: number): [Channel, Channel] {
	const forward = new Pipe(capacity);
	const backward = new Pipe(capacity);
	const end = (inbound: Pipe, outbound: Pipe): Channel => ({
		read: () => inbound.read(),
		write: (data) => outbound.write(data),
		close: () => {
			inbound.close();
			outbound.close();
		},
	});
	return [end(backward, forward), end(forward, backward)];
}

async function within<T>(promise: Promise<T>, milliseconds: number, label: string): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	try {
		return await Promise.race([
			promise,
			new Promise<T>((_resolve, reject) => {
				timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds);
			}),
		]);
	} finally {
		clearTimeout(timer);
	}
}

Deno.test("graceful finishing preserves a new sealed-channel failure", async () => {
	const exporter = new Host();
	const dialer = new Host();
	let releaseTurn = () => {};
	try {
		const turn = new Promise<null>((resolve) => releaseTurn = () => resolve(null));
		let entered = () => {};
		const called = new Promise<void>((resolve) => entered = resolve);
		exporter.publish("hold", () => {
			entered();
			return turn;
		});
		const [dialSide, acceptSide] = channelPair(4096);
		const designator = exporter.designator();
		exporter.setAdvertisedLocator(bareLocator("noise-tcp", designator));
		dialer.setAdvertisedLocator(bareLocator("noise-tcp", dialer.designator()));
		const [accepted, dialed] = await Promise.all([
			Session.establishAccepted(exporter, {
				transport: "noise-tcp",
				designatorScheme: DESIGNATOR_SCHEME_KEY,
				serverDesignator: designator,
				channel: acceptSide,
			}, 5_000),
			Session.establishDialedLocator(dialer, bareLocator("noise-tcp", designator), dialSide, 5_000),
		]);
		const acceptedServing = accepted.serve().catch(() => {});
		const hold = await dialed.fetch("hold");
		const pending = dialed.send(hold, "wait", []).catch(() => {});
		await within(called, 1_000, "pending call admitted");
		const finishing = dialed.close({ pending: "finish", graceMs: null });
		const observed = Promise.allSettled([finishing]);
		// One complete record with an invalid authentication tag.
		await acceptSide.write(Uint8Array.of(0, 16, ...new Uint8Array(16)));
		const [result] = await within(observed, 1_000, "sealed failure during finish");
		assert(
			result.status === "rejected" && result.reason instanceof GlowcapError,
			"graceful finishing hid a new sealed-channel failure",
		);
		assert(
			result.reason.code === CLOSED && result.reason.message.includes("DecryptFailed"),
			"finish lost the native sealed-channel cause",
		);
		await pending;
		releaseTurn();
		await accepted.close().catch(() => {});
		await acceptedServing;
	} finally {
		releaseTurn();
		await dialer.close().catch(() => {});
		await exporter.close().catch(() => {});
	}
});

Deno.test("local cancellation before the reader starts remains a clean close", async () => {
	const exporter = new Host();
	const dialer = new Host();
	try {
		const [dialSide, acceptSide] = channelPair(4096);
		const designator = "127.0.0.1:9011";
		const [accepted, dialed] = await Promise.all([
			Session.establishAccepted(exporter, {
				transport: "tcp",
				designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
				serverDesignator: designator,
				channel: acceptSide,
			}, 5_000),
			Session.establishDialedLocator(dialer, bareLocator("tcp", designator), dialSide, 5_000),
		]);
		const acceptedServing = accepted.serve().catch(() => {});
		const closing = dialed.close();
		await within(Promise.all([closing, dialed.serve()]), 1_000, "local close with a late reader");
		await dialed.close();
		await accepted.close();
		await acceptedServing;
	} finally {
		await dialer.close();
		await exporter.close();
	}
});

Deno.test("a feed refusal precedes failure to deliver its abort", async () => {
	for (const [chunk, code] of [["this is not a frame", CODEC], ["2000000:", FRAME_TOO_LARGE]] as const) {
		for (const failWrite of [false, true]) {
			const exporter = new Host();
			const dialer = new Host();
			try {
				const [dialSide, acceptSide] = channelPair(4096);
				const designator = "127.0.0.1:9011";
				const [accepted, dialed] = await Promise.all([
					Session.establishAccepted(exporter, {
						transport: "tcp",
						designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
						serverDesignator: designator,
						channel: acceptSide,
					}, 5_000),
					Session.establishDialedLocator(dialer, bareLocator("tcp", designator), dialSide, 5_000),
				]);
				const acceptedServing = accepted.serve().catch(() => {});
				const writeFailure = new Error("abort delivery failed");
				dialSide.read = () => Promise.resolve(new TextEncoder().encode(chunk));
				if (failWrite) dialSide.write = () => Promise.reject(writeFailure);
				const serving = await Promise.allSettled([within(dialed.serve(), 1_000, "refused feed")]);
				const result = serving[0];
				assert(
					result.status === "rejected" && result.reason instanceof GlowcapError,
					"feed refusal lost its type",
				);
				const refusal = result.reason;
				assert(refusal.code === code, "abort delivery replaced the refused feed");
				if (code === CODEC) assert(refusal.abort?.errorName === "MalformedFrame", "typed abort disappeared");
				for (let repeat = 0; repeat < 2; repeat++) {
					const [closed] = await Promise.allSettled([within(dialed.close(), 1_000, "terminal close")]);
					assert(
						closed.status === "rejected" && closed.reason === refusal,
						"close lost the exact feed refusal",
					);
				}
				const secondary = secondaryFailures(refusal);
				if (failWrite) assert(secondary[0] === writeFailure, "exact abort delivery failure disappeared");
				else assert(secondary.length === 0, "successful abort delivery acquired a failure");
				await accepted.close().catch(() => {});
				await acceptedServing;
			} finally {
				await dialer.close().catch(() => {});
				await exporter.close().catch(() => {});
			}
		}
	}
});

Deno.test("a pipe smaller than a frame carries both directions at once", async () => {
	const exporter = new Host();
	const dialer = new Host();
	const serving: Promise<void>[] = [];
	try {
		exporter.publish("echo", (_verb, args) => args[0]);
		const [dialSide, acceptSide] = channelPair(64);
		const designator = "127.0.0.1:9011";
		const [accepted, dialed] = await Promise.all([
			Session.establishAccepted(exporter, {
				transport: "tcp",
				designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
				serverDesignator: designator,
				channel: acceptSide,
			}, 5_000),
			Session.establishDialedLocator(dialer, bareLocator("tcp", designator), dialSide, 5_000),
		]);
		serving.push(accepted.serve().catch(() => {}), dialed.serve().catch(() => {}));
		const echo = await dialed.fetch("echo");
		const exchange = Promise.all([0, 1, 2, 3].map(async (index) => {
			const reply = await dialed.send(echo, "echo", [new Uint8Array(4096).fill(index)]);
			assert(
				reply instanceof Uint8Array && reply.length === 4096 && reply.every((byte) => byte === index),
				`echo ${index} returned other bytes`,
			);
		}));
		await within(exchange, 10_000, "both peers kept reading while their writes waited");
	} finally {
		await dialer.close();
		await exporter.close();
		await Promise.all(serving);
	}
});

Deno.test("a throwing close listener cannot strand a bounded channel or skip another listener", async () => {
	const exporter = new Host();
	const dialer = new Host();
	const serving: Promise<void>[] = [];
	let removeListener = () => {};
	try {
		const [dialSide, acceptSide] = channelPair(64);
		let retired = 0;
		const closeChannel = dialSide.close;
		dialSide.close = () => {
			retired++;
			return closeChannel();
		};
		const designator = "127.0.0.1:9011";
		const [accepted, dialed] = await Promise.all([
			Session.establishAccepted(exporter, {
				transport: "tcp",
				designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
				serverDesignator: designator,
				channel: acceptSide,
			}, 5_000),
			Session.establishDialedLocator(dialer, bareLocator("tcp", designator), dialSide, 5_000),
		]);
		serving.push(accepted.serve().catch(() => {}), dialed.serve().catch(() => {}));
		const failure = new Error("close listener sentinel");
		let first = 0;
		let later = 0;
		removeListener = dialed.onClose(() => {
			first++;
			throw failure;
		});
		dialed.onClose(() => later++);
		let observed: unknown;
		try {
			await within(dialed.close(), 1_000, "session retirement");
		} catch (error) {
			observed = error;
		}
		try {
			dialer.drainGc();
		} catch (error) {
			observed = error;
		}
		assert(first === 1 && later === 1, `close listeners ran ${first} and ${later} times`);
		assert(retired === 1, "the listener prevented channel retirement");
		assert(observed === failure, "the exact listener failure was lost");
		await dialed.close();
		assert(first === 1 && later === 1, "repeated close reran listeners");
		assert(retired === 1, "repeated close retired the channel again");
	} finally {
		removeListener();
		await dialer.close().catch(() => {});
		await exporter.close().catch(() => {});
		await Promise.all(serving);
	}
});

Deno.test("the Host retains an unexpected writer task failure", async () => {
	for (const closeHost of [false, true]) {
		for (const failure of [new Error("unexpected writer sentinel"), null, undefined, false, 0, -0, NaN, ""]) {
			const host = new Host();
			try {
				const writer = Promise.reject(failure);
				host.trackSessionWriter(writer);
				await writer.catch(() => {});
				let caught = false;
				let observed: unknown;
				try {
					if (closeHost) await host.close();
					else host.drainGc();
				} catch (error) {
					caught = true;
					observed = error;
				}
				assert(caught && Object.is(observed, failure), `the writer failure ${String(failure)} was lost`);
				if (closeHost) {
					assert(host.released, "the writer failure interrupted Host release");
					let repeated: unknown;
					let repeatedCaught = false;
					try {
						await host.close();
					} catch (error) {
						repeatedCaught = true;
						repeated = error;
					}
					assert(repeatedCaught && Object.is(repeated, failure), "repeated Host close lost its outcome");
				}
			} finally {
				await host.close().catch(() => {});
			}
		}
	}
});

Deno.test("Host close retains a falsy transport retirement failure", async () => {
	for (const failure of [null, undefined, false, 0, -0, NaN, ""]) {
		const host = new Host();
		try {
			const closing = host.close();
			host.trackSessionRetirement(Promise.reject(failure));
			let caught = false;
			let observed: unknown;
			try {
				await closing;
			} catch (error) {
				caught = true;
				observed = error;
			}
			assert(caught && Object.is(observed, failure), `the retirement failure ${String(failure)} was lost`);
		} finally {
			await host.close().catch(() => {});
		}
	}
});

Deno.test("a close listener failure cannot interrupt Host teardown", async () => {
	const exporter = new Host();
	const dialer = new Host();
	const serving: Promise<void>[] = [];
	try {
		const [dialSide, acceptSide] = channelPair(64);
		const designator = "127.0.0.1:9011";
		const [accepted, dialed] = await Promise.all([
			Session.establishAccepted(exporter, {
				transport: "tcp",
				designatorScheme: DESIGNATOR_SCHEME_ADDRESS,
				serverDesignator: designator,
				channel: acceptSide,
			}, 5_000),
			Session.establishDialedLocator(dialer, bareLocator("tcp", designator), dialSide, 5_000),
		]);
		serving.push(accepted.serve().catch(() => {}), dialed.serve().catch(() => {}));
		const failure = new Error("Host close listener sentinel");
		dialed.onClose(() => {
			throw failure;
		});
		let observed: unknown;
		try {
			await within(dialer.close(), 1_000, "Host retirement despite callback failure");
		} catch (error) {
			observed = error;
		}
		assert(dialer.released, "the callback failure interrupted FFI Host retirement");
		assert(observed === failure, "Host close did not report the exact callback failure");
	} finally {
		await dialer.close().catch(() => {});
		await exporter.close().catch(() => {});
		await Promise.all(serving);
	}
});
