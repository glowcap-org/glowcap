// The browser's Rooms server choice: what a typed address may be, and what is kept.
import { assertEquals } from "./assert.ts";
import {
	chooseServer,
	chosenServer,
	probeServer,
	SERVER_KEY,
	serverBase,
	serverInUse,
	serverOffer,
} from "../web/ui/server_choice.ts";

Deno.test("a typed server address reads as a page base or is refused whole", () => {
	assertEquals(serverBase(""), { base: null });
	assertEquals(serverBase("  "), { base: null });
	assertEquals(serverBase("https://rooms.example"), { base: "https://rooms.example/" });
	assertEquals(serverBase("http://127.0.0.1:36173/"), { base: "http://127.0.0.1:36173/" });
	assertEquals(serverBase("https://you.example/rooms/app"), { base: "https://you.example/rooms/app/" });
	for (
		const refused of [
			"rooms.example",
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
	assertEquals(bad?.rest.href, "https://glowcap.org/rooms/app/");
	assertEquals(serverOffer(new URL("https://glowcap.org/rooms/app/?dm=relay"), null), null);
	// The link rooms-web prints for a listed page (its web.rs tests hold the
	// same text) offers that server.
	const printed = new URL("https://glowcap.org/rooms/app/?server=http%3A%2F%2Flocalhost%3A8080%2F");
	assertEquals(serverOffer(printed, null)?.base, "http://localhost:8080/");
});

Deno.test("a server test tells a Rooms server, another answer, a refusal of this page, and silence apart", async () => {
	const names = (text: string) => text.startsWith("ocapn://");
	const base = "http://127.0.0.1:8080/rooms/";
	const asked: string[] = [];
	const answering = (body: string, status = 200) => (address: URL, init: RequestInit) => {
		asked.push(`${address.href} ${init.mode ?? "cors"}`);
		return Promise.resolve(new Response(body, { status }));
	};
	assertEquals(await probeServer(base, names, answering("ocapn://dir.iroh\n")), {
		kind: "answers",
		directory: "ocapn://dir.iroh",
	});
	assertEquals(asked, ["http://127.0.0.1:8080/rooms/locator cors"]);
	assertEquals(await probeServer(base, names, answering("", 404)), { kind: "elsewhere" });
	assertEquals(await probeServer(base, names, answering("", 503)), { kind: "elsewhere" });
	assertEquals(await probeServer(base, names, answering("not a directory")), { kind: "elsewhere" });
	const refusing = (_: URL, init: RequestInit) =>
		init.mode === "no-cors" ? Promise.resolve(new Response(null)) : Promise.reject(new TypeError("cors"));
	assertEquals(await probeServer(base, names, refusing), { kind: "refuses" });
	const silent = () => Promise.reject(new TypeError("refused"));
	assertEquals(await probeServer(base, names, silent), { kind: "silent" });
});
