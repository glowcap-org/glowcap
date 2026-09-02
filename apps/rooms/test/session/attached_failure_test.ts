// Attach refusals that are not about the paste.

import { attachedSessionFailureText } from "../../web/ui/session/attached_failure.ts";
import { locatorRefusal } from "../../web/ui/error_text.ts";
import { assertEquals } from "../assert.ts";

Deno.test("a missing WebRTC signaling inbox is not reported as a truncated paste", () => {
	const said = attachedSessionFailureText(
		new Error("glowcap error -12: peer-offline: no signaling inbox for that designator"),
	);
	assertEquals(said.includes("hosting tab"), true);
	assertEquals(said.startsWith("glowcap error"), false);
	assertEquals(
		locatorRefusal(said, "session capability link").includes("Check that you pasted"),
		false,
	);
});

Deno.test("an unregistered signalOffer is not reported as a truncated paste", () => {
	const said = attachedSessionFailureText(
		new Error("glowcap error -12: not-registered: signalOffer needs a registered name"),
	);
	assertEquals(said.includes("could not signal through the directory"), true);
	assertEquals(said.startsWith("glowcap error"), false);
	assertEquals(
		locatorRefusal(said, "session capability link").includes("Check that you pasted"),
		false,
	);
});

Deno.test("an unverified session peer is not reported as a truncated paste", () => {
	const said = attachedSessionFailureText(
		new Error("glowcap error -3: host: PeerIdentityUnverified"),
	);
	assertEquals(said.includes("could not authenticate"), true);
	assertEquals(said.includes("hosting tab"), false);
	assertEquals(said.startsWith("glowcap error"), false);
	assertEquals(
		locatorRefusal(said, "session capability link").includes("Check that you pasted"),
		false,
	);
});
