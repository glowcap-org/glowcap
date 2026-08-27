// Hermetic goldens for page settings. The URL wins when it names a value;
// storage fills in when it does not.
import { assertEquals } from "./assert.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { dmFrom, dmTransportFor, originVizUrl, vizFrom, writeSearch } = await import("../web/ui/prefs.ts");
const { vizOverrideRefusal } = await import("../lib/viz_publish.ts");

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

Deno.test("writeSearch preserves exact visualizer values and removes only empty", () => {
	const url = new URL("http://rooms.test/?keep=1&dm=relay&viz=ws://old/");
	writeSearch(url, { dm: "webrtc", viz: "" });
	assertEquals(url.searchParams.get("keep"), "1", "other query stays");
	assertEquals(url.searchParams.get("dm"), null, "webrtc drops dm");
	assertEquals(url.searchParams.get("viz"), null, "blank viz drops");
	writeSearch(url, { dm: "relay", viz: " ws://127.0.0.1:9/ " });
	assertEquals(url.searchParams.get("keep"), "1", "keep still");
	assertEquals(url.searchParams.get("dm"), "relay", "relay");
	assertEquals(url.searchParams.get("viz"), " ws://127.0.0.1:9/ ", "exact viz");
});

Deno.test("visualizer overrides are explicit WebSocket URLs or blank", () => {
	assertEquals(vizOverrideRefusal(""), null);
	assertEquals(vizOverrideRefusal("wss://rooms.test/viz"), null);
	assertEquals(vizOverrideRefusal(" wss://rooms.test/viz")?.includes("whitespace"), true);
	assertEquals(vizOverrideRefusal("https://rooms.test/viz")?.includes("ws://"), true);
	assertEquals(vizOverrideRefusal("wss://rooms.test/viz#feed")?.includes("fragment"), true);
});

Deno.test("originVizUrl: http is ws, https is wss, on the page's own host", () => {
	assertEquals(
		originVizUrl({ protocol: "http:", host: "rooms.test:8000" }),
		"ws://rooms.test:8000/viz",
		"ws",
	);
	assertEquals(
		originVizUrl({ protocol: "https:", host: "rooms.test" }),
		"wss://rooms.test/viz",
		"wss",
	);
});
