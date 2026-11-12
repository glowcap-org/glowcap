// A feed owns setup from runtime initialization through its pending transport dial.
import { assertEquals } from "@std/assert";
import { LiveFeed, type LivePeerFactory } from "../connection.ts";
import type { BrowserRuntime, GlowcapWebModule } from "../glowcap-web-api.ts";

const STURDYREF = "ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss";

Deno.test("disconnect cancels its pending dial without reporting a connection failure", async () => {
	let signal: AbortSignal | undefined;
	const factory: LivePeerFactory = (_ref, _receive, cancellation) => {
		signal = cancellation;
		return new Promise((_, reject) => {
			cancellation.addEventListener("abort", () => reject(cancellation.reason), { once: true });
		});
	};
	const feed = new LiveFeed(STURDYREF, factory);
	const errors: unknown[] = [];
	feed.onError((error) => errors.push(error));
	feed.connect();
	assertEquals(signal?.aborted, false);
	feed.disconnect();
	assertEquals(signal?.aborted, true);
	await Promise.resolve();
	assertEquals(errors, []);
});

Deno.test("a disposed feed never dials after shared wasm initialization; its replacement connects", async () => {
	let ready!: (runtime: BrowserRuntime) => void;
	const runtimeReady = new Promise<BrowserRuntime>((resolve) => ready = resolve);
	const globals = globalThis as typeof globalThis & {
		__OCV_GLOWCAP_WEB_LOADER?: () => Promise<GlowcapWebModule>;
		__OCV_GLOWCAP_WASM_URL?: string;
	};
	globals.__OCV_GLOWCAP_WASM_URL = "data:application/wasm;base64,AGFzbQEAAAA=";
	globals.__OCV_GLOWCAP_WEB_LOADER = () =>
		Promise.resolve({
			init: async ({ wasm }) => {
				await (await wasm).arrayBuffer();
				return await runtimeReady;
			},
		});
	let end!: () => void;
	const closed = new Promise<void>((resolve) => end = resolve);
	const signals: Array<AbortSignal | undefined> = [];
	const runtime: BrowserRuntime = {
		parseSturdyRef: () => ({
			locator: { transport: "tcp", designator: "key", hints: new Map(), hintWireForm: "map" },
			swissnum: new Uint8Array(),
		}),
		connect: (_locator, options) => {
			signals.push(options?.signal);
			return Promise.resolve({
				serve: () => closed,
				spawn: () => null,
				enliven: () => Promise.resolve(null),
				send: () => Promise.resolve(null),
				close: () => end(),
			});
		},
	};
	const disposed = new LiveFeed(STURDYREF);
	const replacement = new LiveFeed(STURDYREF);
	const connected = new Promise<void>((resolve) => {
		replacement.onConnectionChange((up) => {
			if (up === "connected") resolve();
		});
	});
	try {
		disposed.connect();
		disposed.disconnect();
		replacement.connect();
		ready(runtime);
		await connected;
		assertEquals(signals.length, 1);
		assertEquals(signals[0]?.aborted, false);
	} finally {
		disposed.disconnect();
		replacement.disconnect();
		await closed;
		delete globals.__OCV_GLOWCAP_WEB_LOADER;
		delete globals.__OCV_GLOWCAP_WASM_URL;
	}
});

Deno.test("a cancelled predecessor cannot clear its replacement's pending dial", async () => {
	let calls = 0;
	const factory: LivePeerFactory = (_ref, _receive, signal) => {
		calls += 1;
		return new Promise((_, reject) =>
			signal.addEventListener("abort", () => reject(signal.reason), { once: true })
		);
	};
	const feed = new LiveFeed(STURDYREF, factory);
	try {
		feed.connect();
		feed.disconnect();
		feed.connect();
		await Promise.resolve();
		feed.connect();
		assertEquals(calls, 2);
	} finally {
		feed.disconnect();
		await Promise.resolve();
	}
});
