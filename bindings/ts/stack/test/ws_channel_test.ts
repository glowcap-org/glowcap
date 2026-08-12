import { openWebSocketChannel, webSocketChannel } from "../ws_channel.ts";

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
	#listeners: Record<string, Array<() => void>> = {};
	sendBufferedAmount = 0;
	sendCount = 0;
	sentLengths: number[] = [];

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
		this.sendCount++;
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

	message(bytes: number): void {
		this.onmessage?.({ data: new ArrayBuffer(bytes) } as MessageEvent);
	}

	text(value: string): void {
		this.onmessage?.({ data: value } as MessageEvent);
	}
}

const realWebSocket = globalThis.WebSocket;

Deno.test("webSocketChannel bounds unpausable browser inbound queue", async () => {
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
	throw new Error("expected bounded inbound queue to reject the read");
});

Deno.test("webSocketChannel debits inbound queue after each read", async () => {
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

Deno.test("webSocketChannel does not confuse coalesced transport chunks with CapTP frames", async () => {
	const ws = new FakeWebSocket();
	const channel = webSocketChannel(ws as unknown as WebSocket);

	ws.message(16 * 1024);
	const chunk = await channel.read();
	assertEquals(chunk?.byteLength, 16 * 1024);
	assertEquals(ws.closeCode, undefined);
});

Deno.test("webSocketChannel rejects text instead of reinterpreting it as CapTP bytes", async () => {
	const ws = new FakeWebSocket();
	const channel = webSocketChannel(ws as unknown as WebSocket);

	ws.text("not binary");
	try {
		await channel.read();
	} catch (err) {
		assertIncludes(String(err), "text messages are not CapTP bytes");
		assertEquals(ws.closeCode, 1003);
		assertEquals(ws.closeReason, "binary messages required");
		return;
	}
	throw new Error("expected a text WebSocket message to reject the byte channel");
});

Deno.test("webSocketChannel rejects a throttled write when the socket closes", async () => {
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

Deno.test("webSocketChannel serializes concurrent writers behind backpressure", async () => {
	const ws = new FakeWebSocket();
	ws.sendBufferedAmount = 1 << 21;
	const channel = webSocketChannel(ws as unknown as WebSocket);

	const first = channel.write(new Uint8Array([1]));
	const second = channel.write(new Uint8Array([2]));
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(ws.sendCount, 1);
	ws.close();
	await Promise.allSettled([first, second]);
	assertEquals(ws.sendCount, 1);
});

Deno.test("webSocketChannel bounds the retained concurrent write backlog", async () => {
	const ws = new FakeWebSocket();
	ws.sendBufferedAmount = 1 << 21;
	const channel = webSocketChannel(ws as unknown as WebSocket);

	const admitted = channel.write(new Uint8Array(1 << 20));
	const refused = channel.write(new Uint8Array([2]));
	try {
		await refused;
	} catch (err) {
		assertIncludes(String(err), "WebSocket outbound queue exceeded");
		ws.close();
		await Promise.allSettled([admitted]);
		return;
	}
	throw new Error("expected the retained write backlog to be bounded");
});

Deno.test("webSocketChannel splits one oversized write into bounded transport chunks", async () => {
	const ws = new FakeWebSocket();
	const channel = webSocketChannel(ws as unknown as WebSocket);

	await channel.write(new Uint8Array((1 << 20) + 7));
	assertEquals(ws.sendCount, 2);
	assertEquals(ws.sentLengths[0], 1 << 20);
	assertEquals(ws.sentLengths[1], 7);
});

Deno.test("webSocketChannel observes an open transition during listener installation", async () => {
	class SilentlyOpeningWebSocket extends FakeWebSocket {
		constructor() {
			super();
			this.readyState = WebSocket.CONNECTING;
		}

		override addEventListener(type: string, listener: () => void): void {
			if (type === "open") this.readyState = WebSocket.OPEN;
			super.addEventListener(type, listener);
		}
	}
	const ws = new SilentlyOpeningWebSocket();
	const channel = webSocketChannel(ws as unknown as WebSocket);

	await channel.write(new Uint8Array([1]));
	assertEquals(ws.sendCount, 1);
});

Deno.test("openWebSocketChannel rejects invalid bounds before opening a socket", async () => {
	let constructed = 0;
	class CountingWebSocket extends FakeWebSocket {
		constructor(_url: string) {
			super();
			constructed++;
		}
	}
	try {
		(globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket =
			CountingWebSocket as unknown as typeof WebSocket;
		try {
			await openWebSocketChannel("ws://example.invalid", { inboundHighWaterBytes: 0 });
		} catch (err) {
			assertIncludes(String(err), "positive safe integer");
			assertEquals(constructed, 0);
			return;
		}
		throw new Error("expected invalid inbound bound to reject");
	} finally {
		(globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});

Deno.test("openWebSocketChannel rejects when the socket closes before open", async () => {
	class ClosingWebSocket extends FakeWebSocket {
		constructor(_url: string) {
			super();
			queueMicrotask(() => this.close());
		}
	}
	try {
		(globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket =
			ClosingWebSocket as unknown as typeof WebSocket;
		const opened = openWebSocketChannel("ws://example.invalid");
		try {
			await opened;
		} catch (err) {
			assertIncludes(String(err), "closed before open");
			return;
		}
		throw new Error("expected pre-open close to reject");
	} finally {
		(globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});
