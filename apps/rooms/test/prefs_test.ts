// Hermetic goldens for page settings. The URL wins when it names a value.
// Storage fills in when it does not.
import "./support/match_media.ts";
import { assertEquals } from "./assert.ts";

const { dmFrom, dmNeedsServer, servedDirectory, writeSearch } = await import("../web/ui/prefs.ts");
const { roomAddress, directoryAddress, dmAddress } = await import("../web/ui/route_address.ts");

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
		assertEquals(dmAddress("grace hopper"), "/dm/grace%20hopper?dm=relay", "direct configuration");
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

Deno.test("dm: a saved relay mode stays relay with no server, and says it needs one", () => {
	const saved = dmFrom(new URLSearchParams(""), "relay");
	assertEquals(saved, "relay", "the mode is not swapped for another");
	assertEquals(dmNeedsServer(saved, false), true, "with no server the row says relay needs one");
	assertEquals(dmNeedsServer(saved, true), false, "with a server it says nothing");
	assertEquals(dmNeedsServer("webrtc", false), false, "browser to browser claims nothing");
});

Deno.test("a deep link to a direct message or the directory asks for the server and resumes at the same address", async () => {
	const store = await import("../web/ui/store.ts");
	const projection = new store.PageProjection();
	const prior = Object.getOwnPropertyDescriptor(globalThis, "location");
	Object.defineProperty(globalThis, "location", { configurable: true, value: { search: "" } });
	try {
		assertEquals(dmAddress("alice"), "/dm/alice");
		assertEquals(directoryAddress(), "/directory");
		for (const resume of [dmAddress("alice"), directoryAddress()]) {
			projection.set({ server: null, serverAsk: null });
			assertEquals(store.serverOrAsk(projection, () => resume), null, `${resume} waits for a server`);
			assertEquals(projection.get().serverAsk, { resume }, `${resume} is where the reload picks up`);
		}
	} finally {
		if (prior) Object.defineProperty(globalThis, "location", prior);
		else Reflect.deleteProperty(globalThis, "location");
	}
});
