// Browser peer lifetime while subscription is still being constructed.

import { assertEquals, assertRejects, assertStrictEquals } from "@std/assert";
import { browserPeerFactory, MAX_TRACE_RECORD_BYTES } from "../connection.ts";
import type { BrowserSession, GlowcapWebModule } from "../glowcap-web-api.ts";

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
					connect: () => Promise.resolve(session),
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
		const constructing = browserPeerFactory("trace", () => {});
		await didReceive;
		// Cross a task boundary before subscription completes: attaching an
		// owner only when the factory returns leaves this interval exposed.
		await new Promise((resolve) => setTimeout(resolve, 0));
		subscribed();
		const peer = await constructing;
		assertStrictEquals(await assertRejects(() => peer.closed), failure);
		assertStrictEquals(await assertRejects(() => peer.close()), failure);
		assertEquals(closes, 1);
		assertEquals(unowned, []);
	} finally {
		globalThis.removeEventListener("unhandledrejection", onUnhandled);
		delete globals.__OCV_GLOWCAP_WEB_LOADER;
		delete globals.__OCV_GLOWCAP_WASM_URL;
	}
});
