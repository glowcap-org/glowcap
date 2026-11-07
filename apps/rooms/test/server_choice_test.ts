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
	const storage = {
		getItem: (key: string) => kept.get(key) ?? null,
		setItem: (key: string, value: string) => void kept.set(key, value),
		removeItem: (key: string) => void kept.delete(key),
	};
	assertEquals(chosenServer(storage), null);
	chooseServer("https://rooms.example/", storage);
	assertEquals(chosenServer(storage), "https://rooms.example/");
	kept.set(SERVER_KEY, "not a url");
	assertEquals(chosenServer(storage), null);
	chooseServer(null, storage);
	assertEquals(kept.has(SERVER_KEY), false);
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

Deno.test("a server test tells a Rooms server, another answer, a refusal of this page, and silence apart", async () => {
	const names = (text: string) => text.startsWith("ocapn://");
	const base = "http://127.0.0.1:8080/rooms/";
	const asked: string[] = [];
	const answering = (body: string, status = 200) => (address: URL, init: RequestInit) => {
		asked.push(`${address.href} ${init.mode ?? "cors"}`);
		return Promise.resolve(new Response(body, { status }));
	};
	assertEquals(await probeServer(base, names, { read: answering("ocapn://dir.iroh\n") }), {
		kind: "answers",
		directory: "ocapn://dir.iroh",
	});
	assertEquals(asked, ["http://127.0.0.1:8080/rooms/locator cors"]);
	assertEquals(await probeServer(base, names, { read: answering("", 404) }), { kind: "elsewhere" });
	assertEquals(await probeServer(base, names, { read: answering("", 503) }), { kind: "elsewhere" });
	assertEquals(await probeServer(base, names, { read: answering("not a directory") }), { kind: "elsewhere" });
	const refusing = (_: URL, init: RequestInit) =>
		init.mode === "no-cors" ? Promise.resolve(new Response(null)) : Promise.reject(new TypeError("cors"));
	assertEquals(await probeServer(base, names, { read: refusing }), { kind: "refuses" });
	const silent = () => Promise.reject(new TypeError("refused"));
	assertEquals(await probeServer(base, names, { read: silent }), { kind: "silent" });
	// Silence from a local server behind a browser that has not allowed the
	// local network is the browser's doing, and says which answer it gave.
	const asks = () => Promise.resolve<LocalNetworkPermission>("prompt");
	assertEquals(await probeServer(base, names, { read: silent, blocked: asks }), {
		kind: "blocked",
		permission: "prompt",
	});
	const allowed = () => Promise.resolve<LocalNetworkPermission>("granted");
	assertEquals(await probeServer(base, names, { read: silent, blocked: allowed }), { kind: "silent" });
	assertEquals(await probeServer(base, names, { read: answering("ocapn://dir.iroh"), blocked: asks }), {
		kind: "answers",
		directory: "ocapn://dir.iroh",
	});
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
	assertEquals(sessionOffer(carried)?.rest.href, "https://glowcap.org/rooms/app/");
});
