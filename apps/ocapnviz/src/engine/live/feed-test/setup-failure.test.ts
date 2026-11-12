// A failed setup whose retirement also fails cannot safely reuse its session.
import { assert, assertEquals, assertRejects, assertStrictEquals } from "@std/assert";
import { browserPeerFactory, type LivePeer } from "../connection.ts";
import { dialLiveFeed } from "../mode.ts";
import type { EngineError } from "../../errors.ts";
import { type AppError, pushError, subscribeErrors } from "../../../ui/error/error-bus.ts";
import type { GlowcapWebModule } from "../glowcap-web-api.ts";

Deno.test("setup and retirement failures settle state, expose both causes, and require reload before retry", async () => {
	const primary = new Error("trace subscription denied");
	const retirement = new Error("session close refused before retirement");
	let calls = 0;
	let closes = 0;
	let end!: () => void;
	const closed = new Promise<void>((resolve) => end = resolve);
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
					parseSturdyRef: () => ({
						locator: { transport: "tcp", designator: "key", hints: new Map(), hintWireForm: "map" },
						swissnum: new Uint8Array(),
					}),
					connect: () => {
						calls += 1;
						return Promise.resolve({
							serve: () => closed,
							spawn: () => null,
							enliven: () => Promise.resolve("trace"),
							send: () => Promise.reject(primary),
							close: () => {
								closes += 1;
								throw retirement;
							},
						});
					},
				};
			},
		});
	const states: string[] = [];
	const reports: EngineError[] = [];
	const scheduled: unknown[] = [];
	const setTimeout = globalThis.setTimeout;
	globalThis.setTimeout = ((...args: unknown[]) => {
		scheduled.push(args);
		return 0;
	}) as typeof globalThis.setTimeout;
	let constructing!: Promise<LivePeer>;
	const handle = dialLiveFeed({
		sturdyref: "ocapn://key.tcp/s/swiss",
		onConnectionChange: (connected) => states.push(connected),
		onError: (error) => reports.push(error),
		peerFactory: (...args) => constructing = browserPeerFactory(...args),
	});
	try {
		const failure = await assertRejects(() => constructing);
		assert(failure instanceof AggregateError);
		assertStrictEquals(failure.cause, primary);
		assertEquals(states, ["stopped"]);
		assertEquals(reports.length, 2);
		assertEquals(reports[0]!.title, "Live connection did not close cleanly");
		assertStrictEquals(reports[0]!.cause, retirement);
		assertEquals(reports[1]!.title, "Live capability unreachable");
		assertStrictEquals(reports[1]!.cause, primary);
		assert(reports[1]!.detail.includes(primary.message));
		assert(reports[1]!.detail.includes(retirement.message));
		assertEquals(
			reports[1]!.recovery,
			"Automatic reconnect stopped because session cleanup failed. Reload the viewer before reconnecting.",
		);
		handle.feed.connect();
		assertEquals(calls, 1, "the failed retirement must block manual and automatic reuse");
		assertEquals(closes, 1);
		assertEquals(scheduled, []);
	} finally {
		handle.dispose();
		end();
		globalThis.setTimeout = setTimeout;
		delete globals.__OCV_GLOWCAP_WEB_LOADER;
		delete globals.__OCV_GLOWCAP_WASM_URL;
	}
});

Deno.test("mode disposal keeps returned-peer cleanup failures owned by the application error bus", async () => {
	const failure = new Error("returned peer retirement failed");
	let report!: (event: AppError) => void;
	const reported = new Promise<AppError>((resolve) => report = resolve);
	const unsubscribe = subscribeErrors(report);
	const states: string[] = [];
	const handle = dialLiveFeed({
		sturdyref: "ocapn://key.tcp/s/swiss",
		peerFactory: () =>
			Promise.resolve({
				closed: new Promise(() => {}),
				close: () => Promise.reject(failure),
			}),
		onConnectionChange: (state) => states.push(state),
		onError: (error) => pushError({ error, source: "engine" }),
	});
	try {
		await Promise.resolve();
		handle.dispose();
		const event = await reported;
		assertEquals(states, ["connected"]);
		assertEquals(event.source, "engine");
		assertEquals(event.error.title, "Live connection did not close cleanly");
		assertStrictEquals(event.error.cause, failure);
	} finally {
		unsubscribe();
		handle.dispose();
	}
});
