// Browser peer lifetime while subscription is still being constructed.

import { assertEquals, assertRejects, assertStrictEquals } from "@std/assert";
import { browserPeerFactory, MAX_TRACE_RECORD_BYTES } from "../connection.ts";
import type { BrowserSession, GlowcapWebModule } from "../glowcap-web-api.ts";

// The page starts one runtime, so every test in this file connects through
// the first module loaded and reads the session to hand out from here.
let serving: BrowserSession | null = null;

/** Run `body` against a web module whose connections are `session`, and
 * return the rejections nothing owned. */
async function withSession(session: BrowserSession, body: () => Promise<void>): Promise<unknown[]> {
	serving = session;
	const globals = globalThis as {
		__OCV_GLOWCAP_WEB_LOADER?: () => Promise<GlowcapWebModule>;
		__OCV_GLOWCAP_WASM_URL?: string;
	};
	globals.__OCV_GLOWCAP_WASM_URL = "data:application/wasm;base64,";
	globals.__OCV_GLOWCAP_WEB_LOADER = () =>
		Promise.resolve({
			init: async ({ wasm }) => {
				await (await wasm).arrayBuffer();
				return {
					connect: () =>
						serving === null ? Promise.reject(new Error("no session")) : Promise.resolve(serving),
					parseSturdyRef: () => ({
						locator: { transport: "tcp", designator: "localhost", hints: new Map(), hintWireForm: "map" },
						swissnum: new TextEncoder().encode("trace"),
					}),
				};
			},
		});
	const unowned: unknown[] = [];
	const onUnhandled = (event: PromiseRejectionEvent) => {
		unowned.push(event.reason);
		event.preventDefault();
	};
	globalThis.addEventListener("unhandledrejection", onUnhandled);
	try {
		await body();
		// Let a rejection nothing owns reach the listener before it is removed.
		await new Promise((resolve) => setTimeout(resolve, 0));
	} finally {
		globalThis.removeEventListener("unhandledrejection", onUnhandled);
		delete globals.__OCV_GLOWCAP_WEB_LOADER;
		delete globals.__OCV_GLOWCAP_WASM_URL;
		serving = null;
	}
	return unowned;
}

Deno.test("an inbox retirement during subscription owns its rejection immediately", async () => {
	const failure = new Error("retirement failed during subscription");
	let inbox!: (verb: string, args: readonly unknown[]) => unknown;
	let endPump!: () => void;
	const pump = new Promise<void>((resolve) => endPump = resolve);
	let subscribed!: () => void;
	const subscription = new Promise<void>((resolve) => subscribed = resolve);
	let received!: () => void;
	const didReceive = new Promise<void>((resolve) => received = resolve);
	let closes = 0;
	const session: BrowserSession = {
		serve: () => pump,
		spawn: (behavior) => {
			inbox = behavior;
			return "inbox";
		},
		enliven: () => Promise.resolve("trace"),
		send: () => {
			try {
				inbox("record", ["x".repeat(MAX_TRACE_RECORD_BYTES + 1)]);
			} catch {
				// The producer sees the inbox refusal independently of its
				// subscribe answer, which has not arrived at this peer yet.
			}
			received();
			return subscription;
		},
		close: () => {
			closes += 1;
			endPump();
			return Promise.reject(failure);
		},
	};
	const unowned = await withSession(session, async () => {
		const constructing = browserPeerFactory("trace", () => {}, new AbortController().signal);
		await didReceive;
		// Cross a task boundary before subscription completes: attaching an
		// owner only when the factory returns leaves this interval exposed.
		await new Promise((resolve) => setTimeout(resolve, 0));
		subscribed();
		const peer = await constructing;
		assertStrictEquals(await assertRejects(() => peer.closed), failure);
		assertStrictEquals(await assertRejects(() => peer.close()), failure);
		assertEquals(closes, 1);
	});
	assertEquals(unowned, []);
});

Deno.test("a connection lost during setup is the setup failure, with no failed cleanup", async () => {
	const lost = new Error("transport reset");
	const pump = Promise.withResolvers<void>();
	let closes = 0;
	const session: BrowserSession = {
		serve: () => pump.promise,
		spawn: () => "inbox",
		enliven: () => {
			pump.reject(lost);
			return Promise.reject(lost);
		},
		send: () => Promise.resolve(null),
		close: () => {
			closes += 1;
			return Promise.resolve();
		},
	};
	const unowned = await withSession(session, async () => {
		const refused = await assertRejects(() => browserPeerFactory("trace", () => {}, new AbortController().signal));
		assertStrictEquals(refused, lost);
		assertEquals(closes, 1);
	});
	assertEquals(unowned, []);
});
