import {
	MAX_RELAY_WEBSOCKET_MESSAGE_BYTES,
	RelayDialFailed,
	relayFailureLogger,
	webSocketChannel,
	webSocketRelay,
} from "../ws_relay.ts";
import { Rendezvous } from "../rendezvous.ts";
import { relayBytes } from "../relay.ts";
import { isKeyDesignator, secondaryFailures } from "@glowcap/runtime";
import { assertEquals } from "../../dogfood/assert.ts";

function assertIncludes(actual: string, expected: string): void {
	if (!actual.includes(expected)) {
		throw new Error(`expected "${actual}" to include "${expected}"`);
	}
}

class FakeWebSocket {
	binaryType: BinaryType = "blob";
	readyState: number = WebSocket.OPEN;
	bufferedAmount: number = 0;
	onmessage: ((event: MessageEvent) => void) | null = null;
	onclose: ((event: CloseEvent) => void) | null = null;
	onerror: (() => void) | null = null;
	closeCode: number | undefined;
	closeReason: string | undefined;
	sendBufferedAmount = 0;
	sentLengths: number[] = [];
	#listeners: Record<string, Array<() => void>> = {};

	addEventListener(type: string, listener: () => void): void {
		(this.#listeners[type] ??= []).push(listener);
	}

	removeEventListener(type: string, listener: () => void): void {
		const listeners = this.#listeners[type];
		if (listeners == null) return;
		this.#listeners[type] = listeners.filter((item) => item !== listener);
	}

	#emit(type: string): void {
		for (const listener of this.#listeners[type] ?? []) listener();
	}

	send(data: Uint8Array): void {
		this.sentLengths.push(data.byteLength);
		this.bufferedAmount = this.sendBufferedAmount;
	}

	close(code?: number, reason?: string): void {
		this.closeCode = code;
		this.closeReason = reason;
		this.readyState = WebSocket.CLOSED;
		this.onclose?.({ wasClean: true, code: code ?? 1000, reason: reason ?? "" } as CloseEvent);
		this.#emit("close");
	}

	error(): void {
		this.onerror?.();
		this.#emit("error");
	}

	message(bytes: number): void {
		this.onmessage?.({ data: new ArrayBuffer(bytes) } as MessageEvent);
	}
}

Deno.test("relayBytes rejects with its exact first I/O failure after teardown", async () => {
	const ioFailure = new Error("far read failed");
	const closeFailure = new Error("channel close failed");
	const sourceCloseFailure = new Error("source close failed");
	let sourceClosed = false;
	const source = {
		read: () => Promise.reject(ioFailure),
	};
	const sink = {
		write: (_chunk: Uint8Array) => Promise.resolve(),
	};
	let finishChannelRead!: (value: Uint8Array | null) => void;
	const channel = {
		read: () => new Promise<Uint8Array | null>((resolve) => (finishChannelRead = resolve)),
		write: (_chunk: Uint8Array) => Promise.resolve(),
		close: () => {
			finishChannelRead(null);
			return Promise.reject(closeFailure);
		},
	};
	try {
		await relayBytes(source, sink, channel, {
			idleTimeoutMs: 0,
			maxBytesPerSession: 0,
		}, () => {
			sourceClosed = true;
			return Promise.reject(sourceCloseFailure);
		});
		throw new Error("relay failure disappeared");
	} catch (error) {
		assertEquals(error, ioFailure);
		const cleanup = secondaryFailures(ioFailure);
		assertEquals(cleanup.length, 2);
		assertEquals(cleanup[0], closeFailure);
		assertEquals(cleanup[1], sourceCloseFailure);
		assertEquals(sourceClosed, true);
	}
});

Deno.test("relayBytes does not publish teardown-induced sibling cancellation", async () => {
	const cancelled = new Error("read cancelled by relay teardown");
	let cancelRead!: () => void;
	const source = {
		read: () => Promise.resolve(null),
	};
	const sink = {
		write: (_chunk: Uint8Array) => Promise.resolve(),
	};
	const channel = {
		read: () => new Promise<Uint8Array | null>((_resolve, reject) => (cancelRead = () => reject(cancelled))),
		write: (_chunk: Uint8Array) => Promise.resolve(),
		close: () => {
			cancelRead();
			return Promise.resolve();
		},
	};
	await relayBytes(source, sink, channel, {
		idleTimeoutMs: 0,
		maxBytesPerSession: 0,
	}, async () => {});
});

Deno.test("relayBytes promotes a clean-path close refusal to the result", async () => {
	const closeFailure = new Error("channel close failed");
	let finishChannelRead!: (value: Uint8Array | null) => void;
	try {
		await relayBytes(
			{ read: () => Promise.resolve(null) },
			{ write: () => Promise.resolve() },
			{
				read: () => new Promise((resolve) => finishChannelRead = resolve),
				write: () => Promise.resolve(),
				close: () => {
					finishChannelRead(null);
					return Promise.reject(closeFailure);
				},
			},
			{ idleTimeoutMs: 0, maxBytesPerSession: 0 },
			async () => {},
		);
	} catch (error) {
		assertEquals(error, closeFailure);
		return;
	}
	throw new Error("expected close refusal to become the relay result");
});

Deno.test("relayBytes joins both close barriers before settling", async () => {
	let finishChannelRead!: (value: Uint8Array | null) => void;
	let finishChannelClose!: () => void;
	let finishSourceClose!: () => void;
	const channelClosed = new Promise<void>((resolve) => finishChannelClose = resolve);
	const sourceClosed = new Promise<void>((resolve) => finishSourceClose = resolve);
	const relayed = relayBytes(
		{ read: () => Promise.resolve(null) },
		{ write: () => Promise.resolve() },
		{
			read: () => new Promise((resolve) => finishChannelRead = resolve),
			write: () => Promise.resolve(),
			close: () => {
				finishChannelRead(null);
				return channelClosed;
			},
		},
		{ idleTimeoutMs: 0, maxBytesPerSession: 0 },
		() => sourceClosed,
	);
	let settled = false;
	void relayed.then(() => settled = true);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(settled, false);
	finishChannelClose();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(settled, false);
	finishSourceClose();
	await relayed;
	assertEquals(settled, true);
});

Deno.test("webSocketRelay cancellation joins pair-atomic teardown", async () => {
	const ws = new FakeWebSocket();
	const controller = new AbortController();
	let finishFarRead!: (value: Uint8Array | null) => void;
	let farClosed = false;
	const relayed = webSocketRelay(
		ws as unknown as WebSocket,
		() =>
			Promise.resolve({
				read: () => new Promise<Uint8Array | null>((resolve) => finishFarRead = resolve),
				write: () => Promise.resolve(),
				close: () => {
					farClosed = true;
					finishFarRead(null);
					return Promise.resolve();
				},
			}),
		"dial failed",
		{ idleTimeoutMs: 0, maxBytesPerSession: 0 },
		{ signal: controller.signal },
	);
	await new Promise((resolve) => setTimeout(resolve, 0));
	controller.abort();
	await relayed;
	assertEquals(ws.closeCode, 1001);
	assertEquals(ws.closeReason, "relay stopped");
	assertEquals(farClosed, true);
});

Deno.test("relay webSocketChannel bounds early inbound queue", async () => {
	const ws = new FakeWebSocket();
	const channel = webSocketChannel(ws as unknown as WebSocket, { inboundHighWaterBytes: 10 });

	ws.message(11);
	try {
		await channel.read();
	} catch (err) {
		assertIncludes(String(err), "WebSocket inbound queue exceeded");
		assertEquals(ws.closeCode, 1009);
		assertEquals(ws.closeReason, "inbound queue exceeded");
		return;
	}
	throw new Error("expected bounded relay inbound queue to reject the read");
});

Deno.test("relay webSocketChannel debits inbound queue after reads", async () => {
	const ws = new FakeWebSocket();
	const channel = webSocketChannel(ws as unknown as WebSocket, { inboundHighWaterBytes: 10 });

	ws.message(6);
	const first = await channel.read();
	assertEquals(first?.byteLength, 6);

	ws.message(5);
	const second = await channel.read();
	assertEquals(second?.byteLength, 5);
	assertEquals(ws.closeCode, undefined);
});

Deno.test("relay webSocketChannel accepts binary and rejects text", async () => {
	const ws = new FakeWebSocket();
	const channel = webSocketChannel(ws as unknown as WebSocket);

	ws.message(3);
	assertEquals((await channel.read())?.byteLength, 3);
	ws.onmessage?.({ data: "text is not a byte channel" } as MessageEvent);
	try {
		await channel.read();
	} catch (err) {
		assertIncludes(String(err), "text messages are not CapTP bytes");
		assertEquals(ws.closeCode, 1003);
		return;
	}
	throw new Error("expected text WebSocket messages to be rejected");
});

Deno.test("relay webSocketChannel enforces the named message bound", () => {
	const ws = new FakeWebSocket();
	try {
		webSocketChannel(ws as unknown as WebSocket, {
			inboundHighWaterBytes: MAX_RELAY_WEBSOCKET_MESSAGE_BYTES + 1,
		});
	} catch (err) {
		assertIncludes(String(err), "relay WebSocket message bound");
		return;
	}
	throw new Error("expected an oversized relay message bound to be rejected");
});

Deno.test("relay webSocketChannel splits oversized outbound chunks", async () => {
	const ws = new FakeWebSocket();
	const channel = webSocketChannel(ws as unknown as WebSocket);

	await channel.write(new Uint8Array(MAX_RELAY_WEBSOCKET_MESSAGE_BYTES + 1));
	assertEquals(ws.sentLengths.length, 2);
	assertEquals(ws.sentLengths[0], MAX_RELAY_WEBSOCKET_MESSAGE_BYTES);
	assertEquals(ws.sentLengths[1], 1);
});

Deno.test("relay webSocketChannel rejects throttled write on close", async () => {
	const ws = new FakeWebSocket();
	ws.sendBufferedAmount = 1 << 21;
	const channel = webSocketChannel(ws as unknown as WebSocket);

	const write = channel.write(new Uint8Array([1]));
	ws.close();
	try {
		await write;
	} catch (err) {
		assertIncludes(String(err), "WebSocket closed");
		return;
	}
	throw new Error("expected closed socket to reject the pending write");
});

Deno.test("rendezvous accounts insert, error, take, and close exactly once", async () => {
	const rendezvous = new Rendezvous();
	const alice = "a".repeat(64);
	const bob = "b".repeat(64);
	const first = new FakeWebSocket();
	const second = new FakeWebSocket();
	const third = new FakeWebSocket();

	if (!rendezvous.register(alice, first as unknown as WebSocket)) {
		throw new Error("first registration should be admitted");
	}
	if (!rendezvous.register(alice, second as unknown as WebSocket)) {
		throw new Error("second registration should be admitted");
	}
	if (!rendezvous.register(bob, third as unknown as WebSocket)) {
		throw new Error("third registration should be admitted");
	}
	assertEquals(rendezvous.heldCount(), 3);
	assertEquals(rendezvous.heldFor(alice), 2);

	first.error();
	first.error();
	assertEquals(rendezvous.heldCount(), 2);
	assertEquals(rendezvous.heldFor(alice), 1);
	assertEquals(first.readyState, WebSocket.CLOSED);

	const taken = rendezvous.take(alice);
	if (taken == null) throw new Error("the oldest held socket should be taken");
	assertEquals(rendezvous.heldCount(), 1);
	assertEquals(rendezvous.heldFor(alice), 0);
	second.close(); // taken entries are no longer registry-owned status-allow: lifecycle transition
	assertEquals(rendezvous.heldCount(), 1);

	await rendezvous.close();
	assertEquals(rendezvous.heldCount(), 0);
	assertEquals(rendezvous.registered().length, 0);
	third.close(); // close after shutdown must not underflow accounting
	assertEquals(rendezvous.heldCount(), 0);
	const alreadyClosed = new FakeWebSocket();
	alreadyClosed.close();
	if (rendezvous.register("c".repeat(64), alreadyClosed as unknown as WebSocket)) {
		throw new Error("a closed socket must not become a held registration");
	}
	assertEquals(rendezvous.heldCount(), 0);
	if (rendezvous.register("d".repeat(64), new FakeWebSocket() as unknown as WebSocket)) {
		throw new Error("a closed rendezvous must refuse new registrations");
	}
	taken.close();
});

Deno.test("rendezvous close is one physical-release barrier", async () => {
	class DelayedCloseWebSocket extends FakeWebSocket {
		override close(code?: number, reason?: string): void {
			this.closeCode = code;
			this.closeReason = reason;
			this.readyState = WebSocket.CLOSING;
		}

		finishClose(): void {
			super.close(this.closeCode, this.closeReason);
		}
	}
	const socket = new DelayedCloseWebSocket();
	const rendezvous = new Rendezvous();
	if (!rendezvous.register("a".repeat(64), socket as unknown as WebSocket)) {
		throw new Error("registration should be admitted");
	}
	const first = rendezvous.close();
	assertEquals(first, rendezvous.close());
	let settled = false;
	void first.then(() => settled = true);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(settled, false);
	socket.finishClose();
	await first;
	assertEquals(settled, true);
});

Deno.test("rendezvous close reports a falsy close refusal exactly", async () => {
	for (const refusal of [null, undefined, false, 0, -0, NaN, ""]) {
		class RefusingWebSocket extends FakeWebSocket {
			override close(): void {
				throw refusal;
			}
		}
		const rendezvous = new Rendezvous();
		if (!rendezvous.register("a".repeat(64), new RefusingWebSocket() as unknown as WebSocket)) {
			throw new Error("registration should be admitted");
		}
		let refused = false;
		let reason: unknown;
		try {
			await rendezvous.close();
		} catch (error) {
			refused = true;
			reason = error;
		}
		assertEquals(refused && Object.is(reason, refusal), true);
	}
});

Deno.test("rendezvous accepts only canonical fixed-size key designators", () => {
	assertEquals(isKeyDesignator("a".repeat(64)), true);
	for (const value of ["", "a".repeat(63), "a".repeat(65), "A".repeat(64), "g".repeat(64)]) {
		assertEquals(isKeyDesignator(value), false);
	}
	const rendezvous = new Rendezvous();
	assertEquals(
		rendezvous.register("unbounded map key", new FakeWebSocket() as unknown as WebSocket),
		false,
	);
	assertEquals(rendezvous.heldCount(), 0);
});

Deno.test("a failed far-side dial closes the browser socket honestly and rejects typed", async () => {
	// The browser's socket is the claim: it must hear the dial-fail reason,
	// while the caller's rejection wears the type that says it was handled.
	const ws = new FakeWebSocket();
	const cause = new Error("connect: NetworkUnreachable");
	const rejection = await webSocketRelay(
		ws as unknown as WebSocket,
		() => Promise.reject(cause),
		"iroh relay dial failed",
		{ idleTimeoutMs: 0, maxBytesPerSession: 0 },
	).catch((err) => err);
	if (!(rejection instanceof RelayDialFailed)) {
		throw new Error(`dial failure rejected untyped: ${String(rejection)}`);
	}
	if (rejection.cause !== cause) throw new Error("the dial's own error was not retained as the cause");
	assertEquals(ws.closeCode, 1011);
	assertEquals(ws.closeReason, "iroh relay dial failed");
});

Deno.test("relayFailureLogger widens a continuing outage and keeps unexpected failures loud", async () => {
	const lines: string[] = [];
	const log = relayFailureLogger((line) => lines.push(line), 20, 80);
	const dial = new RelayDialFailed("iroh relay dial failed", new Error("connect: NetworkUnreachable"));
	log(dial);
	log(dial);
	log(dial);
	log(new Error("pump exploded"));
	assertEquals(lines.length, 2);
	if (!lines[0].startsWith("relay: dial failed: iroh relay dial failed")) {
		throw new Error(`dial line reads ${JSON.stringify(lines[0])}`);
	}
	if (!lines[1].startsWith("relay: unexpected error: pump exploded")) {
		throw new Error(`unexpected line reads ${JSON.stringify(lines[1])}`);
	}
	await new Promise((r) => setTimeout(r, 40));
	assertEquals(lines.length, 3);
	assertIncludes(lines[2], "repeated 2 more times");
	log(dial);
	log(dial);
	await new Promise((r) => setTimeout(r, 60));
	assertEquals(lines.length, 4);
	assertIncludes(lines[3], "repeated 2 more times");
	await new Promise((r) => setTimeout(r, 100));
	assertEquals(lines.length, 4);
	log(dial);
	assertEquals(lines.length, 5);
});
