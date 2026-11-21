// Server locator reads across Wasm and the permission advice layered over failed reads.
import { assertEquals } from "./assert.ts";
import { locateRoomsServer, probeServer, type ServerLocatorReply } from "../web/ui/server_probe.ts";
import type { LocalNetworkPermission } from "../web/ui/local_network.ts";
import { initializeApplication } from "./support/application.ts";

Deno.test("the Rust locator reads once with same-origin credentials", async () => {
	await initializeApplication();
	const saved = globalThis.fetch;
	const savedTimeout = AbortSignal.timeout;
	const base = "https://rooms.example/app/";
	const cases: [Response | Error, ServerLocatorReply][] = [
		[new Response("ocapn://dir.iroh\n"), { kind: "answers", directory: "ocapn://dir.iroh" }],
		[new Response("\n"), { kind: "elsewhere" }],
		[new Response("<title>Rooms</title>"), { kind: "elsewhere" }],
		[new Response("", { status: 404 }), { kind: "elsewhere" }],
		[new Response("", { status: 503 }), { kind: "elsewhere" }],
		[new Response("", { status: 403 }), { kind: "unavailable" }],
		[new TypeError("browser blocked read"), { kind: "unavailable" }],
	];
	try {
		for (const [response, expected] of cases) {
			let calls = 0;
			globalThis.fetch = (address, options) => {
				calls++;
				assertEquals(address, base + "locator");
				assertEquals(options?.credentials, "same-origin");
				assertEquals(options?.redirect, "error");
				return response instanceof Error ? Promise.reject(response) : Promise.resolve(response);
			};
			assertEquals(await locateRoomsServer(base), expected);
			assertEquals(calls, 1);
		}

		const controller = new AbortController();
		AbortSignal.timeout = () => controller.signal;
		globalThis.fetch = () =>
			Promise.resolve(
				new Response(
					new ReadableStream({
						start(stream) {
							controller.signal.addEventListener("abort", () => stream.error(controller.signal.reason), {
								once: true,
							});
							queueMicrotask(() => controller.abort());
						},
					}),
				),
			);
		assertEquals(await locateRoomsServer(base), { kind: "timedOut" });
	} finally {
		globalThis.fetch = saved;
		AbortSignal.timeout = savedTimeout;
	}
});

Deno.test("a locator failure checks browser permission for a local server", async () => {
	const base = "http://127.0.0.1:8080/rooms/";
	const unavailable = (): Promise<ServerLocatorReply> => Promise.resolve({ kind: "unavailable" });
	const asks = () => Promise.resolve<LocalNetworkPermission>("prompt");
	assertEquals(await probeServer(base, unavailable, asks), { kind: "blocked", permission: "prompt" });
	const allowed = () => Promise.resolve<LocalNetworkPermission>("granted");
	assertEquals(await probeServer(base, unavailable, allowed), { kind: "unavailable" });
	const answers = (): Promise<ServerLocatorReply> =>
		Promise.resolve({ kind: "answers", directory: "ocapn://dir.iroh" });
	assertEquals(await probeServer(base, answers, asks), { kind: "answers", directory: "ocapn://dir.iroh" });
});

Deno.test("a timed-out server check still checks local-network permission", async () => {
	const base = "http://127.0.0.1:8080/rooms/";
	const timedOut = (): Promise<ServerLocatorReply> => Promise.resolve({ kind: "timedOut" });
	for (const permission of ["prompt", "denied"] as const) {
		assertEquals(await probeServer(base, timedOut, () => Promise.resolve(permission)), {
			kind: "blocked",
			permission,
		});
	}
	for (const permission of ["granted", null] as const) {
		assertEquals(await probeServer(base, timedOut, () => Promise.resolve(permission)), { kind: "timedOut" });
	}
});
