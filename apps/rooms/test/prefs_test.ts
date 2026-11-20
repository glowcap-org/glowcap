// Hermetic goldens for page settings. The URL wins when it names a value.
// Storage fills in when it does not.
import "./support/match_media.ts";
import { assertEquals } from "./assert.ts";

const { dmFrom, writeSearch } = await import("../web/ui/prefs.ts");
const { roomAddress, directoryAddress, dmAddress } = await import("../web/ui/route_address.ts");

Deno.test("dm: a URL route wins over the stored preference", () => {
	assertEquals(dmFrom(new URLSearchParams("dm=relay"), "webrtc"), "relay", "url relay");
	assertEquals(dmFrom(new URLSearchParams("dm=webrtc"), "relay"), "webrtc", "url webrtc");
	assertEquals(dmFrom(new URLSearchParams("dm=fastest"), "relay"), "fastest", "url fastest");
});

Deno.test("dm: an absent URL uses the stored preference", () => {
	assertEquals(dmFrom(new URLSearchParams(""), "relay"), "relay", "stored relay");
	assertEquals(dmFrom(new URLSearchParams(""), "webrtc"), "webrtc", "stored webrtc");
});

Deno.test("dm: absent URL and storage means the fastest route", () => {
	assertEquals(dmFrom(new URLSearchParams(""), null), "fastest", "default");
});

Deno.test("dm: an unknown query or stored value falls through", () => {
	assertEquals(dmFrom(new URLSearchParams("dm=nope"), "relay"), "relay", "unknown query");
	assertEquals(dmFrom(new URLSearchParams(""), "nope"), "fastest", "unknown storage");
});

Deno.test("writeSearch names a chosen route and clears for the default", () => {
	const url = new URL("http://rooms.test/?keep=1&dm=relay");
	for (const dm of ["webrtc", "relay"] as const) {
		writeSearch(url, { dm });
		assertEquals(url.searchParams.get("keep"), "1", `other query stays under ${dm}`);
		assertEquals(url.searchParams.get("dm"), dm, dm);
	}
	writeSearch(url, { dm: "fastest" });
	assertEquals(url.searchParams.get("keep"), "1", "keep still");
	assertEquals(url.searchParams.get("dm"), null, "the default drops dm");
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

const { servedByRooms } = await import("../web/ui/page_base.ts");

Deno.test("servedByRooms: only a page the static export marked has no server behind it", () => {
	assertEquals(servedByRooms("static"), false, "static export");
	assertEquals(servedByRooms(null), true, "served by Rooms");
	assertEquals(servedByRooms("other"), true, "an unknown mark");
});
