// Two peers over a channel smaller than one frame. Each must keep reading
// while its own write waits, or each waits for the other to read.
import { DESIGNATOR_SCHEME_ADDRESS } from "@glowcap/abi";
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
