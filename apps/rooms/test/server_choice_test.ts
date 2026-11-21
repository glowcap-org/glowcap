// The browser's Rooms server choice: what a typed address may be, and what is kept.
import { assertEquals } from "./assert.ts";
import printedLinks from "./web/page_links.json" with { type: "json" };
import {
	type AddressSpace,
	addressSpace,
	chooseServer,
	chosenServer,
	localNetworkBlock,
	type LocalNetworkPermission,
	type PermissionsQuery,
	probeServer,
	reachesLocalNetwork,
	SERVER_KEY,
	serverBase,
	serverInUse,
	serverOffer,
	sessionOffer,
	withSessionOffer,
} from "../web/ui/server_choice.ts";
import { pageStorage } from "../web/ui/page_storage.ts";
import { LocalRefusal } from "../lib/text/failure.ts";
import { locateRoomsServer, type ServerLocatorReply } from "../web/ui/application.ts";
import { initializeApplication } from "./support/application.ts";

Deno.test("a typed server address reads as a page base or is refused whole", () => {
	assertEquals(serverBase(""), { base: null });
	assertEquals(serverBase("  "), { base: null });
	assertEquals(serverBase("https://rooms.example"), { base: "https://rooms.example/" });
	assertEquals(serverBase("http://127.0.0.1:36173/"), { base: "http://127.0.0.1:36173/" });
	assertEquals(serverBase("https://you.example/rooms/app/"), { base: "https://you.example/rooms/app/" });
	for (
		const refused of [
			"rooms.example",
			// A path with no final `/` could name a file or a directory. The
			// server refuses the same entry, so the page never guesses either.
			"https://you.example/rooms/app",
			"ftp://rooms.example/",
			"https://a:b@rooms.example/",
			"https://rooms.example/?x=1",
			"https://rooms.example/#top",
			"https://rooms.example/?",
		]
	) {
		assertEquals(serverBase(refused), { refused: true }, refused);
	}
});

Deno.test("the kept server is the choice, and a damaged one is no choice", () => {
	const kept = new Map<string, string>();
	const storage = pageStorage(() => ({
		getItem: (key: string) => kept.get(key) ?? null,
		setItem: (key: string, value: string) => void kept.set(key, value),
		removeItem: (key: string) => void kept.delete(key),
		key: () => null,
		length: 0,
	}));
	assertEquals(chosenServer(storage), null);
	assertEquals(chooseServer("https://rooms.example/", storage), null);
	assertEquals(chosenServer(storage), "https://rooms.example/");
	kept.set(SERVER_KEY, "not a url");
	assertEquals(chosenServer(storage), null);
	assertEquals(chooseServer(null, storage), null);
	assertEquals(kept.has(SERVER_KEY), false);
});

Deno.test("a browser that blocks storage has chosen no server and refuses a new choice", () => {
	const blocked = pageStorage(() => {
		throw new DOMException("The operation is insecure.", "SecurityError");
	});
	assertEquals(chosenServer(blocked), null);
	assertEquals(chooseServer("https://rooms.example/", blocked) instanceof LocalRefusal, true);
	assertEquals(chooseServer(null, blocked) instanceof LocalRefusal, true);
});

Deno.test("the server in use is the chosen one, else the page's own, and a static page has none", () => {
	const page = new URL("https://pages.example/rooms/");
	assertEquals(serverInUse("http://127.0.0.1:36173/", page, false), {
		base: "http://127.0.0.1:36173/",
		chosen: true,
	});
	assertEquals(serverInUse(null, page, true), { base: "https://pages.example/rooms/", chosen: false });
	assertEquals(serverInUse(null, page, false), null);
});

Deno.test("a link's server offer is asked once and leaves the address either way", () => {
	const page = new URL("https://glowcap.org/rooms/app/?server=http%3A%2F%2F127.0.0.1%3A8080&dm=relay#garden");
	const offer = serverOffer(page, null);
	assertEquals(offer?.base, "http://127.0.0.1:8080/");
	assertEquals(offer?.rest.href, "https://glowcap.org/rooms/app/?dm=relay#garden");
	// Already chosen, or not a server address: nothing to ask, still removed.
	assertEquals(serverOffer(page, "http://127.0.0.1:8080/")?.base, null);
	const bad = serverOffer(new URL("https://glowcap.org/rooms/app/?server=javascript:alert(1)"), null);
	assertEquals(bad?.base, null);
	assertEquals(bad?.unreadable, "javascript:alert(1)", "an offer that is no server address is named, not dropped");
	assertEquals(bad?.rest.href, "https://glowcap.org/rooms/app/");
	assertEquals(serverOffer(page, "http://127.0.0.1:8080/")?.unreadable, null);
	assertEquals(serverOffer(new URL("https://glowcap.org/rooms/app/?dm=relay"), null), null);
	// The link the Rooms server prints for a listed page offers that server.
	// The fixture is the one its web.rs test prints from.
	assertEquals(serverOffer(new URL(printedLinks.pageLink), null)?.base, printedLinks.server);
});

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

Deno.test("a browser is asked about the local network when a page reaches a more private space", async () => {
	const spaces: Record<AddressSpace, string[]> = {
		loopback: ["localhost", "app.localhost", "127.0.0.1", "127.1.2.3", "[::1]", "::1"],
		local: ["10.0.0.8", "172.16.0.1", "172.31.9.9", "192.168.1.1", "169.254.1.1", "fd12::1", "fe80::1"],
		public: ["glowcap.org", "172.32.0.1", "11.0.0.1", "193.168.1.1", "2606:4700::1", "localhost.example"],
	};
	for (const [space, hosts] of Object.entries(spaces)) {
		for (const host of hosts) assertEquals(addressSpace(host), space, host);
	}
	const loopback = new URL("http://127.0.0.1:8080/locator");
	const lan = new URL("http://192.168.1.20:8080/locator");
	assertEquals(reachesLocalNetwork(loopback, "glowcap.org"), true);
	assertEquals(reachesLocalNetwork(lan, "glowcap.org"), true);
	assertEquals(reachesLocalNetwork(loopback, "192.168.1.5"), true);
	assertEquals(reachesLocalNetwork(lan, "192.168.1.5"), false);
	assertEquals(reachesLocalNetwork(loopback, "localhost"), false);
	assertEquals(reachesLocalNetwork(lan, "localhost"), false);
	assertEquals(reachesLocalNetwork(new URL("https://rooms.example/"), "glowcap.org"), false);
	assertEquals(reachesLocalNetwork(loopback, undefined), false);
	const asked: string[] = [];
	const chrome: PermissionsQuery = {
		query: (descriptor) => {
			asked.push(descriptor.name);
			return Promise.resolve({ state: "denied" });
		},
	};
	const local = new URL("http://127.0.0.1:8080/locator");
	assertEquals(await localNetworkBlock(local, { page: "glowcap.org", permissions: chrome }), "denied");
	assertEquals(asked, ["local-network-access"]);
	// A local page is never blocked, a public server is not local, and a
	// browser without the permission, or that refuses the question, says nothing.
	assertEquals(await localNetworkBlock(local, { page: "localhost", permissions: chrome }), null);
	assertEquals(
		await localNetworkBlock(new URL("https://rooms.example/locator"), { page: "glowcap.org", permissions: chrome }),
		null,
	);
	assertEquals(await localNetworkBlock(local, { page: "glowcap.org" }), null);
	const firefox: PermissionsQuery = { query: () => Promise.reject(new TypeError("unknown")) };
	assertEquals(await localNetworkBlock(local, { page: "glowcap.org", permissions: firefox }), null);
});

Deno.test("a link's session offer leaves the address and never takes a room route", () => {
	// The link the Rooms server prints for a listed page with a shared session,
	// from the fixture its web.rs test prints from.
	const offer = sessionOffer(new URL(printedLinks.sessionLink));
	assertEquals(offer?.capability, printedLinks.session);
	assertEquals(offer?.rest.href, printedLinks.pageLink);
	assertEquals(sessionOffer(new URL("https://glowcap.org/rooms/app/#garden")), null);
	assertEquals(sessionOffer(new URL("https://glowcap.org/rooms/app/#room/attach=x")), null);
	// A link carried across a reload reads back whole.
	const carried = withSessionOffer(new URL("https://glowcap.org/rooms/app/#garden"), "ocapn://abc.iroh/s/x?y=1&z");
	assertEquals(sessionOffer(carried)?.capability, "ocapn://abc.iroh/s/x?y=1&z");
	assertEquals(sessionOffer(carried)?.rest.href, "https://glowcap.org/rooms/app/#garden");
});

Deno.test("a session offer preserves a join destination in either fragment order", () => {
	const join = new URL(
		"https://glowcap.org/rooms/app/join#room=workshop&address=ocapn%3A%2F%2Froom.iroh%2Fs%2Fsecret",
	);
	const offered = withSessionOffer(join, "ocapn://session.iroh/s/attach?x=1&y=2");
	assertEquals(offered.pathname + offered.search, "/rooms/app/join");
	assertEquals(sessionOffer(offered)?.rest.href, join.href);
	assertEquals(sessionOffer(offered)?.capability, "ocapn://session.iroh/s/attach?x=1&y=2");
	const reordered = new URL(join);
	reordered.hash = `attach=other&${join.hash.slice(1)}`;
	assertEquals(sessionOffer(reordered)?.rest.href, join.href);
	assertEquals(sessionOffer(join), null);
});
