// Whether Share may publish a WebRTC sturdyref.

import { TRANSPORT_WEBRTC } from "@glowcap/runtime";
import { webrtcHomeShareReady, webrtcShareRefusal } from "../web/ui/session/host_reach.ts";
import { assertEquals } from "./assert.ts";

const home = "ocapn://home.example";
const elsewhere = "ocapn://elsewhere.example";

Deno.test("a WebRTC Share without this page's home directory is refused before the sturdyref is shown", () => {
	assertEquals(webrtcShareRefusal(TRANSPORT_WEBRTC, false).includes("Join a room"), true);
	assertEquals(webrtcShareRefusal(TRANSPORT_WEBRTC, true), "");
	assertEquals(webrtcShareRefusal("tcp", false), "");
});

Deno.test("a live membership on another directory is not a WebRTC Share", () => {
	assertEquals(
		webrtcHomeShareReady(TRANSPORT_WEBRTC, home, [elsewhere], "alice").includes("Join a room"),
		true,
	);
});

Deno.test("a home directory that never registered a name is not a WebRTC Share", () => {
	assertEquals(
		webrtcHomeShareReady(TRANSPORT_WEBRTC, home, [home], "").includes("Join a room"),
		true,
	);
});

Deno.test("this page's registered home directory is a WebRTC Share", () => {
	assertEquals(webrtcHomeShareReady(TRANSPORT_WEBRTC, home, [home], "alice"), "");
	assertEquals(webrtcHomeShareReady("tcp", home, [], ""), "");
});

Deno.test("a hosted Share keeps this tab's directory sessions instead of redialing them", async () => {
	const source = await Deno.readTextFile(new URL("../web/ui/session/host.ts", import.meta.url));
	assertEquals(source.includes("stealHeldDirectories(page)"), true);
	assertEquals(source.includes("adoptDirectories(stolen)"), true);
	assertEquals(source.includes("await leftover.close()"), false);
	assertEquals(source.includes("await live.settled()"), true);
	assertEquals(source.includes("webrtcHomeShareReady("), true);
	assertEquals(source.includes("await homeLocator(page)"), true);
	assertEquals(
		source.indexOf("await homeLocator(page)") < source.indexOf("sessionHostLocator(page)"),
		true,
	);
});

Deno.test("a WebRTC Share refusal names this page's directory as the one Attach will use", () => {
	const said = webrtcShareRefusal(TRANSPORT_WEBRTC, false);
	assertEquals(said.includes("Join a room on this page's directory"), true);
	assertEquals(said.includes("different Rooms page"), true);
});
