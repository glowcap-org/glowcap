// Choosing a Rooms server: accepted addresses, device storage, and offered links.
import { assertEquals } from "./assert.ts";
import printedLinks from "./web/page_links.json" with { type: "json" };
import {
	chooseServer,
	chosenServer,
	SERVER_KEY,
	serverBase,
	serverInUse,
	serverOffer,
} from "../web/ui/server_choice.ts";
import { pageStorage } from "../web/ui/page_storage.ts";
import { LocalRefusal } from "../lib/text/failure.ts";

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
