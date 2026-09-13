// Hermetic goldens for page settings. The URL wins when it names a value;
// storage fills in when it does not.
import { assertEquals } from "./assert.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { dmFrom, dmTransportFor, originTraceUrl, traceFrom, writeSearch } = await import("../web/ui/prefs.ts");
const { initializeApplication } = await import("./support/application.ts");
await initializeApplication();
const { traceOverrideRefusal } = await import("../web/ui/trace_endpoint.ts");

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

Deno.test("trace: URL present wins, including a blank", () => {
	assertEquals(traceFrom(new URLSearchParams("trace="), "ws://stored"), "", "blank url");
	assertEquals(
		traceFrom(new URLSearchParams("trace=ws://127.0.0.1:9/"), "ws://stored"),
		"ws://127.0.0.1:9/",
		"url trace",
	);
});

Deno.test("trace: absent URL uses storage, else null", () => {
	assertEquals(traceFrom(new URLSearchParams(""), "ws://stored"), "ws://stored", "stored trace");
	assertEquals(traceFrom(new URLSearchParams(""), null), null, "no trace");
});

Deno.test("dm: an unknown query falls through to storage", () => {
	assertEquals(dmFrom(new URLSearchParams("dm=nope"), "relay"), "relay", "unknown query");
});

Deno.test("writeSearch preserves exact visualizer values and removes only empty", () => {
	const url = new URL("http://rooms.test/?keep=1&dm=relay&trace=ws://old/");
	writeSearch(url, { dm: "webrtc", trace: "" });
	assertEquals(url.searchParams.get("keep"), "1", "other query stays");
	assertEquals(url.searchParams.get("dm"), null, "webrtc drops dm");
	assertEquals(url.searchParams.get("trace"), null, "blank trace drops");
	writeSearch(url, { dm: "relay", trace: " ws://127.0.0.1:9/ " });
	assertEquals(url.searchParams.get("keep"), "1", "keep still");
	assertEquals(url.searchParams.get("dm"), "relay", "relay");
	assertEquals(url.searchParams.get("trace"), " ws://127.0.0.1:9/ ", "exact trace");
});

Deno.test("visualizer overrides are explicit WebSocket URLs or blank", () => {
	assertEquals(traceOverrideRefusal(""), null);
	assertEquals(traceOverrideRefusal("wss://rooms.test/trace"), null);
	assertEquals(traceOverrideRefusal(" wss://rooms.test/trace")?.includes("whitespace"), true);
	assertEquals(traceOverrideRefusal("https://rooms.test/trace")?.includes("ws://"), true);
	assertEquals(traceOverrideRefusal("wss://rooms.test/trace#feed")?.includes("fragment"), true);
});

Deno.test("originTraceUrl: http is ws, https is wss, on the page's own host", () => {
	assertEquals(
		originTraceUrl({ protocol: "http:", host: "rooms.test:8000" }),
		"ws://rooms.test:8000/trace",
		"ws",
	);
	assertEquals(
		originTraceUrl({ protocol: "https:", host: "rooms.test" }),
		"wss://rooms.test/trace",
		"wss",
	);
});
