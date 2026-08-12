import { MAX_RELAY_WEBSOCKET_MESSAGE_BYTES, webSocketChannel } from "../ws_relay.ts";
import { isRendezvousDesignator, Rendezvous } from "../rendezvous.ts";

function assertEquals(actual: unknown, expected: unknown): void {
	if (actual !== expected) {
		throw new Error(`expected ${String(expected)}, got ${String(actual)}`);
	}
}

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
	onclose: (() => void) | null = null;
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
		this.onclose?.();
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

Deno.test("rendezvous accounts insert, error, take, and close exactly once", () => {
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
	second.close(); // taken entries are no longer registry-owned
	assertEquals(rendezvous.heldCount(), 1);

	rendezvous.close();
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

Deno.test("rendezvous accepts only canonical fixed-size key designators", () => {
	assertEquals(isRendezvousDesignator("a".repeat(64)), true);
	for (const value of ["", "a".repeat(63), "a".repeat(65), "A".repeat(64), "g".repeat(64)]) {
		assertEquals(isRendezvousDesignator(value), false);
	}
	const rendezvous = new Rendezvous();
	assertEquals(
		rendezvous.register("unbounded attacker key", new FakeWebSocket() as unknown as WebSocket),
		false,
	);
	assertEquals(rendezvous.heldCount(), 0);
});
