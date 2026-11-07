// Hermetic goldens for page settings. The URL wins when it names a value.
// Storage fills in when it does not.
import "./support/match_media.ts";
import { assertEquals } from "./assert.ts";

const { dmFrom, servedDirectory, writeSearch } = await import("../web/ui/prefs.ts");
const { roomAddress, directoryAddress } = await import("../web/ui/route_address.ts");

Deno.test("dm: URL relay wins over stored webrtc", () => {
	assertEquals(dmFrom(new URLSearchParams("dm=relay"), "webrtc"), "relay", "url relay");
});

Deno.test("dm: URL webrtc wins over stored relay", () => {
	assertEquals(dmFrom(new URLSearchParams("dm=webrtc"), "relay"), "webrtc", "url webrtc");
});

Deno.test("dm: absent URL uses stored relay", () => {
	assertEquals(dmFrom(new URLSearchParams(""), "relay"), "relay", "stored relay");
});

Deno.test("dm: absent URL and storage defaults to webrtc", () => {
	assertEquals(dmFrom(new URLSearchParams(""), null), "webrtc", "default");
});

Deno.test("dm: an unknown query falls through to storage", () => {
	assertEquals(dmFrom(new URLSearchParams("dm=nope"), "relay"), "relay", "unknown query");
});

Deno.test("writeSearch preserves unrelated values", () => {
	const url = new URL("http://rooms.test/?keep=1&dm=relay");
	writeSearch(url, { dm: "webrtc" });
	assertEquals(url.searchParams.get("keep"), "1", "other query stays");
	assertEquals(url.searchParams.get("dm"), null, "webrtc drops dm");
	writeSearch(url, { dm: "relay" });
	assertEquals(url.searchParams.get("keep"), "1", "keep still");
	assertEquals(url.searchParams.get("dm"), "relay", "relay");
});

Deno.test("shared room and directory addresses carry only the DM startup choice", () => {
	const prior = Object.getOwnPropertyDescriptor(globalThis, "location");
	Object.defineProperty(globalThis, "location", {
		configurable: true,
		value: { search: "?dm=relay&pane=settings&unrelated=private" },
	});
	try {
		assertEquals(roomAddress("lobby"), "/room/lobby?dm=relay", "room configuration");
		assertEquals(directoryAddress(), "/directory?dm=relay", "directory configuration");
	} finally {
		if (prior) Object.defineProperty(globalThis, "location", prior);
		else Reflect.deleteProperty(globalThis, "location");
	}
});

// A page from a static host has no `/locator`. Whatever that host answers,
// the page opens holding no directory, and only a directory address counts.
const namesDirectory = (text: string) => text.startsWith("ocapn://");
const { pageRoute, servedByRooms } = await import("../web/ui/page_base.ts");

Deno.test("servedByRooms: only a page the static export marked has no server behind it", () => {
	assertEquals(servedByRooms("static"), false, "static export");
	assertEquals(servedByRooms(null), true, "served by Rooms");
	assertEquals(servedByRooms("other"), true, "an unknown mark");
});
// A page served under a base path reads its route under that base.
const locator = pageRoute("locator", new URL("https://pages.test/rooms/app/"));
const answering = (response: Response | Error) => (address: URL) => {
	assertEquals(address.href, "https://pages.test/rooms/app/locator", "the route under the page base");
	return response instanceof Error ? Promise.reject(response) : Promise.resolve(response);
};

Deno.test("servedDirectory: a served directory address is the page's directory", async () => {
	const read = answering(new Response("ocapn://directory.test\n"));
	assertEquals(await servedDirectory(namesDirectory, read, locator), "ocapn://directory.test", "served");
});

Deno.test("servedDirectory: a missing route means no served directory", async () => {
	const read = answering(new Response("not found", { status: 404 }));
	assertEquals(await servedDirectory(namesDirectory, read, locator), null, "404");
});

Deno.test("servedDirectory: a page fallback answering HTML means no served directory", async () => {
	const read = answering(new Response("<!doctype html><title>Rooms</title>", { status: 200 }));
	assertEquals(await servedDirectory(namesDirectory, read, locator), null, "fallback page");
});

Deno.test("servedDirectory: an unreachable host means no served directory", async () => {
	const read = answering(new TypeError("Failed to fetch"));
	assertEquals(await servedDirectory(namesDirectory, read, locator), null, "network failure");
});

Deno.test("servedDirectory: an empty body means no served directory", async () => {
	const read = answering(new Response("\n"));
	assertEquals(await servedDirectory(namesDirectory, read, locator), null, "empty");
});
