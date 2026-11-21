// DM transport selection: an explicit URL wins over the saved session preference.
import { assertEquals } from "./assert.ts";
import { dmFrom, writeDmMode } from "../web/ui/dm_transport.ts";

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

Deno.test("writeDmMode names a chosen route and clears for the default", () => {
	const url = new URL("http://rooms.test/?keep=1&dm=relay");
	for (const dm of ["webrtc", "relay"] as const) {
		writeDmMode(url, dm);
		assertEquals(url.searchParams.get("keep"), "1", `other query stays under ${dm}`);
		assertEquals(url.searchParams.get("dm"), dm, dm);
	}
	writeDmMode(url, "fastest");
	assertEquals(url.searchParams.get("keep"), "1", "keep still");
	assertEquals(url.searchParams.get("dm"), null, "the default drops dm");
});
