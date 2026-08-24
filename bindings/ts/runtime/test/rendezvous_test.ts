import { serveRendezvous } from "../rendezvous.ts";
import { TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY } from "../locator.ts";
import type { Host } from "../host.ts";
import type { Locator } from "../locator.ts";
import { Session } from "../session.ts";
import { secondaryFailures } from "../errors.ts";

const DESIGNATOR = "ab".repeat(32);

function assert(value: unknown, message: string): asserts value {
	if (!value) throw new Error(message);
}

function rejects(fn: () => unknown, includes: string): void {
	try {
		fn();
	} catch (error) {
		assert(String(error).includes(includes), `expected ${String(error)} to include ${includes}`);
		return;
	}
	throw new Error(`expected refusal containing ${includes}`);
}

class FakeHost {
	advertised: Locator | null = null;
	bindingFailures: Array<{ operation: string; error: unknown }> = [];
	observerFailures: Array<{ operation: string; error: unknown }> = [];

	designator(): string {
		return DESIGNATOR;
	}

	setAdvertisedLocator(locator: Locator): void {
		this.advertised = locator;
	}

	recordCallerlessBindingFailure(operation: string, error: unknown): void {
		this.bindingFailures.push({ operation, error });
	}

	recordCallerlessFailure(operation: string, error: unknown): void {
		this.observerFailures.push({ operation, error });
	}
}

class FakeWebSocket extends EventTarget {
	static readonly CONNECTING = 0;
	static readonly OPEN = 1;
	static readonly CLOSING = 2;
	static readonly CLOSED = 3;
	readonly url: string;
	readyState = FakeWebSocket.CONNECTING;
	binaryType: BinaryType = "blob";
	bufferedAmount = 0;
	onmessage: ((event: MessageEvent) => void) | null = null;
	onclose: ((event: CloseEvent) => void) | null = null;
	onerror: (() => void) | null = null;
	closeCalls = 0;

	constructor(url: string) {
		super();
		this.url = url;
	}

	close(code?: number, reason?: string): void {
		this.closeCalls++;
		this.readyState = FakeWebSocket.CLOSED;
		this.onclose?.({ wasClean: true, code: code ?? 1000, reason: reason ?? "" } as CloseEvent);
		this.dispatchEvent(new Event("close"));
	}

	open(): void {
		this.readyState = FakeWebSocket.OPEN;
		this.dispatchEvent(new Event("open"));
	}

	fail(): void {
		this.dispatchEvent(new Event("error"));
	}

	send(): void {}
}

Deno.test("rendezvous registration admits clear and Noise profiles", async () => {
	const realWebSocket = globalThis.WebSocket;
	const sockets: FakeWebSocket[] = [];
	class RecordingWebSocket extends FakeWebSocket {
		constructor(url: string) {
			super(url);
			sockets.push(this);
		}
	}
	try {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = RecordingWebSocket as unknown as typeof WebSocket;
		for (const transport of [TRANSPORT_KEYED_RELAY, TRANSPORT_NOISE_RELAY] as const) {
			const host = new FakeHost();
			const handle = serveRendezvous(
				host as unknown as Host,
				transport,
				{
					registerUrl: (id) => `wss://relay.example.test/register?id=${id}`,
					relayUrl: "wss://relay.example.test/relay",
				},
				{ pool: 1 },
			);
			assert(handle.locator.transport === transport, "registration changed its profile");
			assert(host.advertised?.transport === transport, "Host advertised another profile");
			assert(sockets.at(-1)?.url.includes(DESIGNATOR), "registration URL lost the Host designator");
			await handle.stop();
		}
	} finally {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});

Deno.test("rendezvous stop retires registrations but preserves admitted sessions", async () => {
	const realWebSocket = globalThis.WebSocket;
	const realEstablishAccepted = Session.establishAccepted;
	const sockets: FakeWebSocket[] = [];
	let finishServe!: () => void;
	const serving = new Promise<void>((resolve) => finishServe = resolve);
	class RecordingWebSocket extends FakeWebSocket {
		constructor(url: string) {
			super(url);
			sockets.push(this);
		}
	}
	try {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = RecordingWebSocket as unknown as typeof WebSocket;
		Session.establishAccepted = () => Promise.resolve({ serve: () => serving } as unknown as Session);
		const host = new FakeHost();
		const handle = serveRendezvous(
			host as unknown as Host,
			TRANSPORT_NOISE_RELAY,
			{
				registerUrl: () => "wss://relay.example.test/register",
				relayUrl: "wss://relay.example.test/relay",
			},
			{ pool: 1 },
		);
		const admitted = sockets[0];
		const ready = handle.ready();
		admitted.open();
		await ready;
		await new Promise((resolve) => setTimeout(resolve, 0));
		assert(sockets.length === 2, "accepted registration did not replenish the pool");
		const firstStop = handle.stop();
		assert(firstStop === handle.stop(), "rendezvous stop did not preserve one barrier");
		await firstStop;
		assert(admitted.closeCalls === 0, "listener stop closed a Host-owned accepted session");
		assert(sockets[1].closeCalls === 1, "listener stop did not close its pending registration");
		const draining = handle.drain();
		assert(draining === handle.drain(), "rendezvous drain did not preserve one barrier");
		let drained = false;
		void draining.then(() => drained = true);
		await new Promise((resolve) => setTimeout(resolve, 0));
		assert(!drained, "rendezvous drain returned before an accepted session ended");
		finishServe();
		await draining;
		assert(drained, "rendezvous drain did not settle with its accepted session");
	} finally {
		Session.establishAccepted = realEstablishAccepted;
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});

Deno.test("rendezvous stop joins each registration's physical close", async () => {
	const realWebSocket = globalThis.WebSocket;
	let socket!: DelayedCloseWebSocket;
	class DelayedCloseWebSocket extends FakeWebSocket {
		override close(): void {
			this.closeCalls++;
			this.readyState = FakeWebSocket.CLOSING;
		}

		finishClose(): void {
			this.readyState = FakeWebSocket.CLOSED;
			this.onclose?.({ wasClean: true, code: 1000, reason: "" } as CloseEvent);
			this.dispatchEvent(new Event("close"));
		}
	}
	class RecordingWebSocket extends DelayedCloseWebSocket {
		constructor(url: string) {
			super(url);
			socket = this;
		}
	}
	try {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = RecordingWebSocket as unknown as typeof WebSocket;
		const handle = serveRendezvous(
			new FakeHost() as unknown as Host,
			TRANSPORT_NOISE_RELAY,
			{
				registerUrl: () => "wss://relay.example.test/register",
				relayUrl: "wss://relay.example.test/relay",
			},
			{ pool: 1 },
		);
		const stopped = handle.stop();
		let settled = false;
		void stopped.then(() => settled = true);
		await new Promise((resolve) => setTimeout(resolve, 0));
		assert(!settled, "rendezvous stop returned before its registration physically closed");
		socket.finishClose();
		await stopped;
		assert(settled, "rendezvous stop did not settle after physical close");
	} finally {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});

Deno.test("rendezvous readiness settles once and stop refuses pending waiters", async () => {
	const realWebSocket = globalThis.WebSocket;
	const realEstablishAccepted = Session.establishAccepted;
	const sockets: FakeWebSocket[] = [];
	class RecordingWebSocket extends FakeWebSocket {
		constructor(url: string) {
			super(url);
			sockets.push(this);
		}
	}
	try {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = RecordingWebSocket as unknown as typeof WebSocket;
		Session.establishAccepted = () => Promise.resolve({ serve: () => Promise.resolve() } as unknown as Session);
		const route = {
			registerUrl: () => "wss://relay.example.test/register",
			relayUrl: "wss://relay.example.test/relay",
		};
		const first = serveRendezvous(new FakeHost() as unknown as Host, TRANSPORT_NOISE_RELAY, route, { pool: 1 });
		const firstReady = first.ready();
		sockets[0].open();
		await firstReady;
		await first.ready();
		await first.stop();

		const second = serveRendezvous(new FakeHost() as unknown as Host, TRANSPORT_NOISE_RELAY, route, { pool: 1 });
		const secondReady = second.ready();
		await second.stop();
		let refusal: unknown;
		try {
			await secondReady;
		} catch (error) {
			refusal = error;
		}
		assert(String(refusal).includes("stopped before"), "stop left rendezvous readiness pending");
	} finally {
		Session.establishAccepted = realEstablishAccepted;
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});

Deno.test("rendezvous reports registration and observer failures to the Host waist", async () => {
	const realWebSocket = globalThis.WebSocket;
	const sockets: FakeWebSocket[] = [];
	const observerFailure = new Error("observer refused");
	class RecordingWebSocket extends FakeWebSocket {
		constructor(url: string) {
			super(url);
			sockets.push(this);
		}
	}
	try {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = RecordingWebSocket as unknown as typeof WebSocket;
		const host = new FakeHost();
		const handle = serveRendezvous(
			host as unknown as Host,
			TRANSPORT_NOISE_RELAY,
			{
				registerUrl: () => "wss://relay.example.test/register",
				relayUrl: "wss://relay.example.test/relay",
			},
			{
				pool: 1,
				onError: () => {
					throw observerFailure;
				},
			},
		);
		sockets[0].fail();
		await new Promise((resolve) => setTimeout(resolve, 0));
		assert(host.bindingFailures.length === 1, "registration failure missed the Host diagnostic waist");
		assert(
			host.bindingFailures[0].operation === "rendezvous.register.accept",
			"registration diagnostic lost its operation",
		);
		assert(host.observerFailures.length === 1, "throwing error observer escaped without a diagnostic");
		assert(host.observerFailures[0].error === observerFailure, "observer diagnostic lost exact identity");
		await handle.stop();
	} finally {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});

Deno.test("rendezvous stop preserves its first close refusal and later consequences", async () => {
	const realWebSocket = globalThis.WebSocket;
	const failures = [new Error("first close refused"), new Error("second close refused")];
	let next = 0;
	class RefusingWebSocket extends FakeWebSocket {
		override close(): void {
			const refusal = failures[next++];
			queueMicrotask(() => {
				this.readyState = FakeWebSocket.CLOSED;
				this.onclose?.({ wasClean: true, code: 1000, reason: "" } as CloseEvent);
				this.dispatchEvent(new Event("close"));
			});
			throw refusal;
		}
	}
	try {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = RefusingWebSocket as unknown as typeof WebSocket;
		const handle = serveRendezvous(
			new FakeHost() as unknown as Host,
			TRANSPORT_NOISE_RELAY,
			{
				registerUrl: () => "wss://relay.example.test/register",
				relayUrl: "wss://relay.example.test/relay",
			},
			{ pool: 2 },
		);
		let refusal: unknown;
		try {
			await handle.stop();
		} catch (error) {
			refusal = error;
		}
		assert(refusal === failures[0], "stop replaced its exact first close refusal");
		assert(secondaryFailures(refusal)[0] === failures[1], "stop dropped its later close refusal");
	} finally {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});

Deno.test("rendezvous refuses an invalid pool before advertising or opening I/O", () => {
	const realWebSocket = globalThis.WebSocket;
	let sockets = 0;
	class CountingWebSocket extends FakeWebSocket {
		constructor(url: string) {
			super(url);
			sockets++;
		}
	}
	try {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = CountingWebSocket as unknown as typeof WebSocket;
		for (const pool of [0, -1, Number.NaN]) {
			const host = new FakeHost();
			rejects(
				() =>
					serveRendezvous(
						host as unknown as Host,
						TRANSPORT_NOISE_RELAY,
						{
							registerUrl: () => "wss://relay.example.test/register",
							relayUrl: "wss://relay.example.test/relay",
						},
						{ pool },
					),
				"positive safe integer",
			);
			assert(host.advertised === null, "invalid registration changed Host reachability");
		}
		assert(sockets === 0, "invalid registration opened a WebSocket");
	} finally {
		(globalThis as { WebSocket: typeof WebSocket }).WebSocket = realWebSocket;
	}
});
