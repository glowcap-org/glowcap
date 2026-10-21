// Dialing a live feed: connect, disconnect, inbox, and the wasm peer.

import { assert, assertEquals } from "@std/assert";
import { LiveFeed, type LivePeerFactory } from "../connection.ts";
import { startLiveMode } from "../mode.ts";
import type { EngineError } from "../../errors.ts";
import type { TimelineEvent } from "../../timeline.ts";
import type { GlowcapWebModule } from "../glowcap-web-api.ts";

Deno.test("connect: an invalid sturdyref is reported, not thrown", () => {
	const feed = new LiveFeed("w");
	const seen: string[] = [];
	feed.onError((e) => seen.push(e.detail));
	feed.connect();
	assertEquals(seen.length, 1);
	assert(
		seen[0]!.includes('"w"'),
		`the report names the value; got ${seen[0]}`,
	);
	feed.disconnect();
});

Deno.test("startLiveMode: an invalid sturdyref still returns a live handle", () => {
	const seen: string[] = [];
	const handle = startLiveMode({
		sturdyref: "ws:/",
		onError: (e) => seen.push(e.detail),
	});
	assertEquals(seen.length, 1);
	assert(handle.engine.doc.id === "live");
	handle.dispose();
});

type ControlledPeer = {
	closeCount: number;
	finish: () => void;
};

function controlledFactory(): {
	factory: LivePeerFactory;
	peers: ControlledPeer[];
	records: Array<(line: string) => void>;
} {
	const peers: ControlledPeer[] = [];
	const records: Array<(line: string) => void> = [];
	const factory: LivePeerFactory = (_ref, onRecord) => {
		let finish!: () => void;
		const closed = new Promise<void>((resolve) => finish = resolve);
		const control: ControlledPeer = { closeCount: 0, finish };
		peers.push(control);
		records.push(onRecord);
		return Promise.resolve({
			closed,
			close: () => {
				control.closeCount += 1;
				finish();
				return Promise.resolve();
			},
		});
	};
	return { factory, peers, records };
}

Deno.test("a retirement that fails after disconnect reaches the error listeners", async () => {
	// `disconnect()` returns before the transport is gone, so a close that
	// then fails has no caller. Left unobserved it is an unowned rejection,
	// which is fatal to the page; the feed's error channel owns it instead.
	const failure = new Error("WebSocket closed abnormally (code 0)");
	const factory: LivePeerFactory = () =>
		Promise.resolve({
			closed: new Promise<void>(() => {}),
			close: () => Promise.reject(failure),
		});
	const feed = new LiveFeed(
		"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
		factory,
	);
	const reported: EngineError[] = [];
	feed.onError((error) => reported.push(error));
	feed.connect();
	await Promise.resolve();
	feed.disconnect();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(reported.length, 1);
	assertEquals(reported[0]!.cause, failure);
	assert(reported[0]!.detail.includes("abnormally"), reported[0]!.detail);
});

Deno.test("a faulted drop is reported once with reconnect as its recovery; a clean close is not", async () => {
	for (const failure of [new Error("WebSocket closed abnormally (code 1006)"), null]) {
		let end!: () => void;
		let fail!: (cause: unknown) => void;
		const factory: LivePeerFactory = () =>
			Promise.resolve({
				closed: new Promise<void>((resolve, reject) => {
					end = resolve;
					fail = reject;
				}),
				close: () => Promise.resolve(),
			});
		const feed = new LiveFeed(
			"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
			factory,
		);
		const reported: EngineError[] = [];
		feed.onError((error) => reported.push(error));
		const connection: boolean[] = [];
		feed.onConnectionChange((value) => connection.push(value));
		feed.connect();
		await Promise.resolve();
		if (failure === null) end();
		else fail(failure);
		await new Promise((resolve) => setTimeout(resolve, 0));
		assertEquals(connection, [true, false]);
		if (failure === null) {
			assertEquals(reported.length, 0);
		} else {
			assertEquals(reported.length, 1);
			assertEquals(reported[0]!.cause, failure);
			assert(reported[0]!.recovery.includes("Reconnecting"), reported[0]!.recovery);
		}
		feed.disconnect();
	}
});

Deno.test("a peer that arrives after disconnect is retired and its failure still owned", async () => {
	// The peer of a stale generation is closed and never joins the live path,
	// so its `closed` outcome would otherwise have no observer. The feed owns
	// it through the same retirement report.
	const failure = new Error("retire refused");
	const factory: LivePeerFactory = () =>
		new Promise((resolve) =>
			setTimeout(() => {
				const outcome = Promise.reject<void>(failure);
				resolve({ closed: outcome, close: () => outcome });
			}, 0)
		);
	const feed = new LiveFeed(
		"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
		factory,
	);
	const reported: EngineError[] = [];
	feed.onError((error) => reported.push(error));
	feed.connect();
	feed.disconnect();
	await new Promise((resolve) => setTimeout(resolve, 5));
	assertEquals(reported.length, 1);
	assertEquals(reported[0]!.cause, failure);
});

Deno.test("disconnect closes the exact peer once and a late close reaches nobody", async () => {
	const controlled = controlledFactory();
	const feed = new LiveFeed(
		"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
		controlled.factory,
	);
	let connected: boolean | null = null;
	feed.onConnectionChange((v) => connected = v);
	feed.connect();
	await Promise.resolve();
	assertEquals(connected, true);
	feed.disconnect();
	assertEquals(controlled.peers[0]?.closeCount, 1);
	connected = null;
	controlled.peers[0]?.finish();
	await Promise.resolve();
	assertEquals(
		connected,
		null,
		"a disposed feed wrote its close into a live subscriber",
	);
});

Deno.test("onConnectionChange: the unsubscribe releases the slot", async () => {
	const controlled = controlledFactory();
	const feed = new LiveFeed(
		"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
		controlled.factory,
	);
	let connected: boolean | null = null;
	const off = feed.onConnectionChange((v) => connected = v);
	feed.connect();
	off();
	await Promise.resolve();
	assertEquals(connected, null);
	feed.disconnect();
});

Deno.test("records arrive through the hosted inbox callback", async () => {
	const controlled = controlledFactory();
	const feed = new LiveFeed(
		"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
		controlled.factory,
	);
	const seen: TimelineEvent[] = [];
	feed.subscribe((ev) => seen.push(ev));
	feed.connect();
	await Promise.resolve();
	controlled.records[0]?.(JSON.stringify({
		v: 1,
		sim_t_ns: 0,
		seq: 10,
		epoch: 1,
		kind: "ocapn.session-opened",
		session: "p0/s1",
		a: "rooms",
		b: "alice",
		transport: "tcp",
		codec: "syrup",
		captp_version: "1.0",
	}));
	assertEquals(seen.filter((ev) => ev.kind === "session-opened").length, 1);
	feed.disconnect();
});

Deno.test("a malformed record is reported, not thrown", async () => {
	const controlled = controlledFactory();
	const feed = new LiveFeed(
		"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
		controlled.factory,
	);
	const errors: string[] = [];
	const events: TimelineEvent[] = [];
	feed.onError((e) => errors.push(e.title));
	feed.subscribe((ev) => events.push(ev));
	feed.connect();
	await Promise.resolve();
	controlled.records[0]?.("{");
	assertEquals(errors, ["Live record unreadable"]);
	controlled.records[0]?.(JSON.stringify({
		v: 1,
		sim_t_ns: 0,
		seq: 10,
		epoch: 1,
		kind: "ocapn.session-opened",
		session: "p0/s1",
		a: "rooms",
		b: "alice",
		transport: "tcp",
		codec: "syrup",
		captp_version: "1.0",
	}));
	assertEquals(events.filter((ev) => ev.kind === "session-opened").length, 1);
	feed.disconnect();
});

Deno.test("old replay sequence numbers still form an authoritative snapshot", async () => {
	const controlled = controlledFactory();
	const feed = new LiveFeed(
		"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
		controlled.factory,
	);
	const seen: TimelineEvent[] = [];
	feed.subscribe((ev) => seen.push(ev));
	feed.connect();
	await Promise.resolve();
	const open = {
		v: 1,
		sim_t_ns: 0,
		seq: 10,
		epoch: 1,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p0/s1",
		a: "rooms",
		b: "alice",
		codec: "syrup",
	};
	controlled.records[0]?.(JSON.stringify(open));
	controlled.records[0]?.(JSON.stringify({ ...open, replay: true }));
	controlled.records[0]?.(JSON.stringify({
		v: 1,
		sim_t_ns: 1_000_000,
		epoch: 1,
		kind: "trace.replay-end",
	}));
	assertEquals(
		seen.filter((ev) => ev.kind === "session-unobserved").length,
		0,
		"stale-sequence suppression discarded current snapshot state",
	);
	feed.disconnect();
});

Deno.test({
	name: "a dropped peer reconnects with a fresh session and inbox",
	sanitizeOps: false,
	sanitizeResources: false,
	async fn() {
		const controlled = controlledFactory();
		const feed = new LiveFeed(
			"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
			controlled.factory,
		);
		const states: boolean[] = [];
		feed.onConnectionChange((connected) => states.push(connected));
		feed.connect();
		await Promise.resolve();
		controlled.peers[0]?.finish();
		await new Promise((resolve) => setTimeout(resolve, 550));
		await Promise.resolve();
		assertEquals(controlled.peers.length, 2);
		assert(controlled.records[0] !== controlled.records[1]);
		assertEquals(states, [true, false, true]);
		feed.disconnect();
		assertEquals(controlled.peers[1]?.closeCount, 1);
	},
});

const browserWasm = new URL(
	"../../../../../../zig-out/wasm/glowcap_host.wasm",
	import.meta.url,
);
let browserWasmExists = true;
try {
	await Deno.stat(browserWasm);
} catch (error) {
	if (error instanceof Deno.errors.NotFound) browserWasmExists = false;
	else throw error;
}

Deno.test({
	name: "the lazy wasm browser peer enlivens, subscribes, and receives a live record",
	ignore: !browserWasmExists,
	sanitizeOps: false,
	sanitizeResources: false,
	async fn() {
		const root = new URL("../../../../../../", import.meta.url);
		const hostScript = new URL(
			"../../../../../rooms/test/trace/browser_host.ts",
			import.meta.url,
		);
		const child = new Deno.Command(Deno.execPath(), {
			args: ["run", "-A", hostScript.pathname],
			cwd: root.pathname,
			stdout: "piped",
			stderr: "inherit",
		}).spawn();
		const reader = child.stdout.getReader();
		let wasmObjectUrl: string | null = null;
		let feed: LiveFeed | null = null;
		let publisher: WebSocket | null = null;
		try {
			const ready = await readJsonLine(reader) as {
				port: number;
				sturdyref: string;
				publish: string;
			};
			const registry = globalThis as Record<symbol, unknown>;
			const adapterKey = Symbol.for("glowcap.runtime.adapter");
			assertEquals(
				registry[adapterKey],
				undefined,
				"importing LiveFeed eagerly initialized the browser runtime",
			);

			const wasm = await Deno.readFile(browserWasm);
			wasmObjectUrl = URL.createObjectURL(
				new Blob([wasm], { type: "application/wasm" }),
			);
			(globalThis as { __OCV_GLOWCAP_WASM_URL?: string })
				.__OCV_GLOWCAP_WASM_URL = wasmObjectUrl;
			const webModuleName: string = "@glowcap/web";
			(globalThis as {
				__OCV_GLOWCAP_WEB_LOADER?: () => Promise<GlowcapWebModule>;
			}).__OCV_GLOWCAP_WEB_LOADER = () => import(webModuleName) as unknown as Promise<GlowcapWebModule>;

			let connected!: () => void;
			const didConnect = new Promise<void>((resolve) => connected = resolve);
			feed = new LiveFeed(ready.sturdyref);
			let fail!: (cause: unknown) => void;
			const didFail = new Promise<never>((_, reject) => fail = reject);
			feed.onError((error) => fail(error.cause ?? new Error(error.detail)));
			feed.onConnectionChange((value) => {
				if (value) connected();
			});
			const received: TimelineEvent[] = [];
			let sawSession!: () => void;
			const didReceive = new Promise<void>((resolve) => sawSession = resolve);
			feed.subscribe((event) => {
				received.push(event);
				if (event.kind === "session-opened") sawSession();
			});
			feed.connect();
			await Promise.race([didConnect, didFail]);
			assert(
				registry[adapterKey] !== undefined,
				"Live mode did not initialize wasm",
			);

			// The endpoint refuses a producer that presents no capability, and it
			// refuses it after the upgrade, so a bare socket opens and then goes
			// quiet rather than failing where it was opened.
			publisher = new WebSocket(ready.publish);
			await new Promise<void>((resolve, reject) => {
				publisher!.onopen = () => resolve();
				publisher!.onerror = () => reject(new Error("publisher did not open"));
			});
			// A session-opened record names the transport it opened on, and the
			// endpoint drops a record it cannot read rather than answering, so
			// leaving the field out reads exactly like a feed that never
			// delivers.
			publisher.send(JSON.stringify({
				v: 1,
				sim_t_ns: 0,
				kind: "ocapn.session-opened",
				captp_version: "1.0",
				session: "browser-proof-s1",
				a: "rooms",
				b: "alice",
				transport: "tcp",
				codec: "syrup",
			}));
			await Promise.race([didReceive, didFail]);
			assertEquals(
				received.filter((event) => event.kind === "session-opened")
					.length,
				1,
			);
		} finally {
			publisher?.close();
			feed?.disconnect();
			delete (globalThis as { __OCV_GLOWCAP_WASM_URL?: string })
				.__OCV_GLOWCAP_WASM_URL;
			delete (globalThis as { __OCV_GLOWCAP_WEB_LOADER?: unknown })
				.__OCV_GLOWCAP_WEB_LOADER;
			if (wasmObjectUrl !== null) URL.revokeObjectURL(wasmObjectUrl);
			reader.releaseLock();
			try {
				child.kill("SIGTERM");
			} catch {
				// already exited
			}
			await child.status;
		}
	},
});

async function readJsonLine(
	reader: ReadableStreamDefaultReader<Uint8Array>,
): Promise<unknown> {
	const decoder = new TextDecoder();
	let buffered = "";
	while (true) {
		const { value, done } = await reader.read();
		if (done) {
			throw new Error("trace host exited before announcing its capability");
		}
		buffered += decoder.decode(value, { stream: true });
		const newline = buffered.indexOf("\n");
		if (newline >= 0) return JSON.parse(buffered.slice(0, newline));
	}
}
