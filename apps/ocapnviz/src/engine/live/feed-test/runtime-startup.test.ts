// The viewer owns runtime startup failures; an unopened peer cannot be unreachable.
import { assertEquals } from "@std/assert";
import { LiveFeed } from "../connection.ts";
import type { GlowcapWebModule } from "../glowcap-web-api.ts";
import type { EngineError } from "../../errors.ts";

Deno.test("Live mode reports module and wasm startup failures separately from peer reachability", async () => {
	const globals = globalThis as typeof globalThis & {
		__OCV_GLOWCAP_WEB_LOADER?: () => Promise<GlowcapWebModule>;
		__OCV_GLOWCAP_WASM_URL?: string;
	};
	for (const phase of ["module", "wasm"] as const) {
		const failure = new Error(`${phase} could not load`);
		globals.__OCV_GLOWCAP_WASM_URL = "data:application/wasm;base64,AGFzbQEAAAA=";
		globals.__OCV_GLOWCAP_WEB_LOADER = phase === "module" ? () => Promise.reject(failure) : () =>
			Promise.resolve({
				init: async ({ wasm }) => {
					await (await wasm).arrayBuffer();
					throw failure;
				},
			});
		// Both feeds share the same pending runtime startup and its failure.
		const feeds = Array.from({ length: 2 }, () => new LiveFeed("ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss"));
		const reported = feeds.map((feed) => new Promise<EngineError>((resolve) => feed.onError(resolve)));
		try {
			for (const feed of feeds) feed.connect();
			for (const error of await Promise.all(reported)) {
				assertEquals(error.title, "Live runtime could not start");
				assertEquals(error.detail, failure.message);
				assertEquals(error.cause, failure);
				assertEquals(error.recovery, "Reload the viewer. If startup still fails, check its browser assets.");
			}
		} finally {
			for (const feed of feeds) feed.disconnect();
			delete globals.__OCV_GLOWCAP_WEB_LOADER;
			delete globals.__OCV_GLOWCAP_WASM_URL;
		}
	}
});

Deno.test("Live mode keeps a peer dial failure attributed to reachability", async () => {
	const failure = new Error("WebSocket could not connect");
	const feed = new LiveFeed(
		"ocapn://key.keyed-tcp?h=127.0.0.1:1/s/swiss",
		() => Promise.reject(failure),
	);
	const reported = new Promise<EngineError>((resolve) => feed.onError(resolve));
	try {
		feed.connect();
		const error = await reported;
		assertEquals(error.title, "Live capability unreachable");
		assertEquals(error.cause, failure);
	} finally {
		feed.disconnect();
	}
});
