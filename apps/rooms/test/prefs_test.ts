// Hermetic goldens for page settings. The URL wins when it names a value;
// storage fills in when it does not.
import { dmFrom, vizFrom, vizWsUrl, writeSearch } from "../web/ui/prefs.ts";
import { assertEquals } from "./assert.ts";

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

Deno.test("viz: URL present wins, including a blank", () => {
	assertEquals(vizFrom(new URLSearchParams("viz="), "ws://stored"), "", "blank url");
	assertEquals(
		vizFrom(new URLSearchParams("viz=ws://127.0.0.1:9/"), "ws://stored"),
		"ws://127.0.0.1:9/",
		"url viz",
	);
});

Deno.test("viz: absent URL uses storage, else null", () => {
	assertEquals(vizFrom(new URLSearchParams(""), "ws://stored"), "ws://stored", "stored viz");
	assertEquals(vizFrom(new URLSearchParams(""), null), null, "no viz");
});

Deno.test("dm: an unknown query falls through to storage", () => {
	assertEquals(dmFrom(new URLSearchParams("dm=nope"), "relay"), "relay", "unknown query");
});

Deno.test("writeSearch: relay and viz land; webrtc and a blank viz come off", () => {
	const url = new URL("http://rooms.test/?keep=1&dm=relay&viz=ws://old/");
	writeSearch(url, { dm: "webrtc", viz: "  " });
	assertEquals(url.searchParams.get("keep"), "1", "other query stays");
	assertEquals(url.searchParams.get("dm"), null, "webrtc drops dm");
	assertEquals(url.searchParams.get("viz"), null, "blank viz drops");
	writeSearch(url, { dm: "relay", viz: " ws://127.0.0.1:9/ " });
	assertEquals(url.searchParams.get("keep"), "1", "keep still");
	assertEquals(url.searchParams.get("dm"), "relay", "relay");
	assertEquals(url.searchParams.get("viz"), "ws://127.0.0.1:9/", "trimmed viz");
});

Deno.test("vizWsUrl: http is ws, https is wss, junk port is null", () => {
	assertEquals(
		vizWsUrl("9300", { protocol: "http:", hostname: "rooms.test" }),
		"ws://rooms.test:9300/",
		"http",
	);
	assertEquals(
		vizWsUrl("9300", { protocol: "https:", hostname: "rooms.test" }),
		"wss://rooms.test:9300/",
		"https",
	);
	assertEquals(vizWsUrl("nope", { protocol: "http:", hostname: "rooms.test" }), null, "junk");
});
