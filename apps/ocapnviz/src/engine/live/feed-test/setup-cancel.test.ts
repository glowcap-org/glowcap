// The factory owns a connected session until enliven/subscribe transfers it to LiveFeed.
import { assert, assertEquals, assertRejects, assertStrictEquals } from "@std/assert";
import { browserPeerFactory, type LivePeer } from "../connection.ts";
import { dialLiveFeed } from "../mode.ts";
import type { EngineError } from "../../errors.ts";
import type { BrowserSession, GlowcapWebModule } from "../glowcap-web-api.ts";

Deno.test("disconnect retires setup once during enliven or subscribe; transferred peers own their close", async () => {
	let current!: BrowserSession;
	const globals = globalThis as typeof globalThis & {
		__OCV_GLOWCAP_WEB_LOADER?: () => Promise<GlowcapWebModule>;
		__OCV_GLOWCAP_WASM_URL?: string;
	};
	globals.__OCV_GLOWCAP_WASM_URL = "data:application/wasm;base64,AGFzbQEAAAA=";
	globals.__OCV_GLOWCAP_WEB_LOADER = () =>
		Promise.resolve({
			init: async ({ wasm }) => {
				await (await wasm).arrayBuffer();
				return {
					connect: () => Promise.resolve(current),
					parseSturdyRef: () => ({
						locator: { transport: "tcp", designator: "key", hints: new Map(), hintWireForm: "map" },
						swissnum: new Uint8Array(),
					}),
				};
			},
		});
	try {
		for (const phase of ["enliven", "subscribe", "transferred"] as const) {
			for (
				const cleanupFailure of phase === "transferred" ? [null] : [null, new Error("setup retirement failed")]
			) {
				let entered!: () => void;
				const waiting = new Promise<void>((resolve) => entered = resolve);
				let end!: () => void;
				const closed = new Promise<void>((resolve) => end = resolve);
				let closes = 0;
				current = {
					serve: () => closed,
					spawn: () => null,
					enliven: () => {
						if (phase !== "enliven") return Promise.resolve("trace");
						entered();
						return new Promise(() => {});
					},
					send: () => {
						entered();
						return phase === "subscribe" ? new Promise(() => {}) : Promise.resolve(null);
					},
					close: () => {
						closes += 1;
						if (cleanupFailure !== null) throw cleanupFailure;
						end();
					},
				};
				if (phase === "transferred") {
					const cancellation = new AbortController();
					const peer = await browserPeerFactory("trace", () => {}, cancellation.signal);
					cancellation.abort();
					await Promise.resolve();
					assertEquals(closes, 0, "setup cancellation remained attached after peer ownership transferred");
					await peer.close();
					assertEquals(closes, 1);
					continue;
				}
				let constructing!: Promise<LivePeer>;
				let signal!: AbortSignal;
				const errors: EngineError[] = [];
				const states: string[] = [];
				const handle = dialLiveFeed({
					sturdyref: "ocapn://key.tcp/s/swiss",
					peerFactory: (ref, receive, cancellation) => {
						signal = cancellation;
						constructing = browserPeerFactory(ref, receive, cancellation);
						return constructing;
					},
					onError: (error) => errors.push(error),
					onConnectionChange: (connected) => states.push(connected),
				});
				try {
					await waiting;
					handle.dispose();
					const failure = await assertRejects(() => constructing);
					if (cleanupFailure === null) {
						assertStrictEquals(failure, signal.reason);
						assertEquals(errors, []);
					} else {
						assert(failure instanceof AggregateError);
						assertStrictEquals(failure.cause, signal.reason);
						assertStrictEquals(failure.errors[0], signal.reason);
						assertStrictEquals(failure.errors[1], cleanupFailure);
						assertEquals(errors.length, 1);
						assertEquals(errors[0]!.title, "Live connection did not close cleanly");
						assertStrictEquals(errors[0]!.cause, cleanupFailure);
					}
					assertEquals(states, [], "a disposed view received a late connection transition");
					assertEquals(closes, 1, `setup cancellation during ${phase} did not retire exactly once`);
				} finally {
					handle.dispose();
					end();
				}
			}
		}
	} finally {
		delete globals.__OCV_GLOWCAP_WEB_LOADER;
		delete globals.__OCV_GLOWCAP_WASM_URL;
	}
});
