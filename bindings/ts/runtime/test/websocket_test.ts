import { takeRuntimeFailures } from "../context.ts";
import { secondaryFailures } from "../errors.ts";
import { openWebSocketChannel, webSocketChannel } from "../websocket.ts";

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
	static readonly CONNECTING = 0;
	static readonly OPEN = 1;
	static readonly CLOSING = 2;
	static readonly CLOSED = 3;
	binaryType: BinaryType = "blob";
	readyState: number = WebSocket.OPEN;
	bufferedAmount: number = 0;
	onmessage: ((event: MessageEvent) => void) | null = null;
	onclose: ((event: CloseEvent) => void) | null = null;
	onerror: (() => void) | null = null;
	onopen: (() => void) | null = null;
	closeCode: number | undefined;
	closeReason: string | undefined;
	#listeners: Record<string, Array<() => void>> = {};
	sendBufferedAmount = 0;
	sendCount = 0;
	sentLengths: number[] = [];
	sent: Uint8Array[] = [];
	closeCalls = 0;
	autoClose = true;

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
		this.sent.push(data);
		this.bufferedAmount = this.sendBufferedAmount;
	}

	close(code?: number, reason?: string): void {
		this.closeCalls++;
		this.closeCode = code;
		this.closeReason = reason;
		if (this.autoClose) this.finishClose(true, code ?? 1000, reason ?? "");
	}

	finishClose(wasClean: boolean, code = 1000, reason = ""): void {
		this.readyState = WebSocket.CLOSED;
		this.onclose?.({ wasClean, code, reason } as CloseEvent);
		this.#emit("close");
	}

	error(): void {
		this.onerror?.();
		this.#emit("error");
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

Deno.test("webSocketChannel returns one joined close barrier to every lifecycle owner", async () => {
	const ws = new FakeWebSocket();
	ws.autoClose = false;
	const channel = webSocketChannel(ws as unknown as WebSocket);
	const first = channel.close();
	const second = channel.close();
	assertEquals(first, second);
	assertEquals(ws.closeCalls, 1);
	let settled = false;
	void first.then(() => settled = true);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(settled, false);
	ws.finishClose(true);
	await first;
	assertEquals(settled, true);
});

Deno.test("webSocketChannel rejects an abnormal close through its shared barrier", async () => {
	const ws = new FakeWebSocket();
	ws.autoClose = false;
	const channel = webSocketChannel(ws as unknown as WebSocket);
	const closed = channel.close();
	ws.finishClose(false, 1006, "connection lost");
	try {
		await closed;
	} catch (error) {
		assertIncludes(String(error), "closed abnormally (code 1006): connection lost");
		return;
	}
	throw new Error("expected abnormal close to reject the close barrier");
});

Deno.test("webSocketChannel keeps an I/O error primary while joining physical close", async () => {
	const ws = new FakeWebSocket();
	ws.autoClose = false;
	const channel = webSocketChannel(ws as unknown as WebSocket);
	const read = channel.read();
	ws.error();
	await read.catch((error) => assertIncludes(String(error), "WebSocket error"));
	const closed = channel.close();
	let settled = false;
	void closed.catch(() => settled = true);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(settled, false);
	ws.finishClose(true);
	await closed.catch((error) => assertIncludes(String(error), "WebSocket error"));
	assertEquals(settled, true);
});

Deno.test("webSocketChannel returns a close refusal to its lifecycle owner", async () => {
	const refusal = new Error("close refused");
	class RefusingWebSocket extends FakeWebSocket {
		override close(): void {
			throw refusal;
		}
	}
	const channel = webSocketChannel(new RefusingWebSocket() as unknown as WebSocket);
	try {
		await channel.close();
	} catch (error) {
		assertEquals(error, refusal);
		return;
	}
	throw new Error("expected the close refusal to remain observable");
});

Deno.test("webSocketChannel preserves a non-Error close refusal", async () => {
	const refusal: unknown = null;
	class RefusingWebSocket extends FakeWebSocket {
		override close(): void {
			throw refusal;
		}
	}
	const channel = webSocketChannel(new RefusingWebSocket() as unknown as WebSocket);
	let observed: unknown = undefined;
	await channel.close().catch((error) => observed = error);
	assertEquals(observed, refusal);
});

Deno.test("webSocketChannel bounds a close whose event never arrives", async () => {
	const ws = new FakeWebSocket();
	ws.autoClose = false;
	const channel = webSocketChannel(ws as unknown as WebSocket, { closeTimeoutMs: 5 });
	try {
		await channel.close();
	} catch (error) {
		assertIncludes(String(error), "close timed out after 5ms");
		return;
	}
	throw new Error("expected a missing close event to reject the close barrier");
});

Deno.test("webSocketChannel reports an abnormal close after its barrier timed out", async () => {
	takeRuntimeFailures();
	const ws = new FakeWebSocket();
	ws.autoClose = false;
	const channel = webSocketChannel(ws as unknown as WebSocket, { closeTimeoutMs: 1 });
	await channel.close().catch(() => {});
	ws.finishClose(false, 1006, "late connection loss");
	const failures = takeRuntimeFailures();
	assertEquals(failures.length, 1);
	assertEquals(failures[0].operation, "websocket.close.late-settlement");
	assertIncludes(failures[0].primaryMessage, "late connection loss");
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
	const payload = new Uint8Array((1 << 20) + 7);

	await channel.write(payload);
	assertEquals(ws.sendCount, 2);
	assertEquals(ws.sentLengths[0], 1 << 20);
	assertEquals(ws.sentLengths[1], 7);
	assertEquals(ws.sent[0].buffer, payload.buffer);
	assertEquals(ws.sent[1].buffer, payload.buffer);
	assertEquals(ws.sent[1].byteOffset, 1 << 20);
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

Deno.test("openWebSocketChannel cancellation joins close and detaches callbacks", async () => {
	const sockets: FakeWebSocket[] = [];
	class PendingWebSocket extends FakeWebSocket {
		constructor(_url: string) {
			super();
			this.readyState = WebSocket.CONNECTING;
			this.autoClose = false;
			sockets.push(this);
		}
	}
	try {
		(globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket =
			PendingWebSocket as unknown as typeof WebSocket;
		const controller = new AbortController();
		const opened = openWebSocketChannel("ws://example.invalid", { closeTimeoutMs: 100 }, controller.signal);
		controller.abort();
		assertEquals(sockets[0].closeCalls, 1);
		let settled = false;
		void opened.catch(() => settled = true);
		await new Promise((resolve) => setTimeout(resolve, 0));
		assertEquals(settled, false);
		sockets[0].finishClose(true);
		await opened.catch((error) => assertIncludes(String(error), "host released while dialing"));
		assertEquals(sockets[0].onopen, null);
		assertEquals(sockets[0].onclose, null);
		assertEquals(sockets[0].onerror, null);
	} finally {
		(globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});

Deno.test("openWebSocketChannel attaches a synchronous cancel refusal", async () => {
	const refusal = new Error("pending WebSocket close refused");
	class RefusingPendingWebSocket extends FakeWebSocket {
		constructor(_url: string) {
			super();
			this.readyState = WebSocket.CONNECTING;
		}
		override close(): void {
			throw refusal;
		}
	}
	try {
		(globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket =
			RefusingPendingWebSocket as unknown as typeof WebSocket;
		const controller = new AbortController();
		const opened = openWebSocketChannel("ws://example.invalid", undefined, controller.signal);
		controller.abort();
		let observed: unknown;
		await opened.catch((error) => observed = error);
		assertEquals(secondaryFailures(observed)[0], refusal);
	} finally {
		(globalThis as unknown as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});
