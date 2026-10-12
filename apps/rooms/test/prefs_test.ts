// Hermetic goldens for page settings. The URL wins when it names a value.
// Storage fills in when it does not.
import { assertEquals } from "./assert.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { dmFrom, dmTransportFor, writeSearch } = await import("../web/ui/prefs.ts");
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

Deno.test("dm: relay mode selects the sealed relay profile", () => {
	assertEquals(dmTransportFor("relay"), "noise-relay", "relay transport");
	assertEquals(dmTransportFor("webrtc"), "webrtc", "webrtc transport");
});

Deno.test("dm: an unknown query falls through to storage", () => {
	assertEquals(dmFrom(new URLSearchParams("dm=nope"), "relay"), "relay", "unknown query");
});

Deno.test("writeSearch preserves unrelated values and removes obsolete trace redirection", () => {
	const url = new URL("http://rooms.test/?keep=1&dm=relay&trace=ws://old/");
	writeSearch(url, { dm: "webrtc" });
	assertEquals(url.searchParams.get("keep"), "1", "other query stays");
	assertEquals(url.searchParams.get("dm"), null, "webrtc drops dm");
	assertEquals(url.searchParams.get("trace"), null, "obsolete trace drops");
	writeSearch(url, { dm: "relay" });
	assertEquals(url.searchParams.get("keep"), "1", "keep still");
	assertEquals(url.searchParams.get("dm"), "relay", "relay");
	assertEquals(url.searchParams.get("trace"), null, "no endpoint override is written");
});

Deno.test("shared room and directory addresses carry only the DM startup choice", () => {
	const prior = Object.getOwnPropertyDescriptor(globalThis, "location");
	Object.defineProperty(globalThis, "location", {
		configurable: true,
		value: { search: "?dm=relay&trace=wss://elsewhere.test/&pane=trace" },
	});
	try {
		assertEquals(roomAddress("lobby"), "/room/lobby?dm=relay", "room configuration");
		assertEquals(directoryAddress(), "/directory?dm=relay", "directory configuration");
	} finally {
		if (prior) Object.defineProperty(globalThis, "location", prior);
		else Reflect.deleteProperty(globalThis, "location");
	}
});
