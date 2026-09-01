// Whether a refusal is too much to keep next to the control it answers.

import { errorDetailTitle, locatorRefusal, needsErrorDetail, sessionCapabilityRefusal } from "../web/ui/error_text.ts";
import { assertEquals } from "./assert.ts";

Deno.test("a short refusal stays beside the control", () => {
	assertEquals(needsErrorDetail("That name is too long for this room (32 characters)."), false);
	assertEquals(needsErrorDetail("Not sent"), false);
});

Deno.test("a locator, a paragraph, or a stack opens the rest on a card", () => {
	assertEquals(
		needsErrorDetail(
			"Could not reach ocapn://abcdefghijklmnopqrstuvwxyz.onion/s/swiss: the peer closed.",
		),
		true,
	);
	assertEquals(needsErrorDetail("one\ntwo"), true);
	assertEquals(
		needsErrorDetail(
			"the peer closed the session before the handshake finished, and the directory never answered the fetch that would have opened this room",
		),
		true,
	);
});

Deno.test("the card's title follows the kind of notice that opened it", () => {
	assertEquals(errorDetailTitle("failure"), "What went wrong");
	assertEquals(errorDetailTitle("warning"), "The full message");
	assertEquals(errorDetailTitle("success"), "The full message");
});

Deno.test("a session capability is checked for the two mistakes a reader makes", () => {
	assertEquals(sessionCapabilityRefusal(""), "");
	assertEquals(
		sessionCapabilityRefusal("hello"),
		"Paste the session's ocapn:// capability link.",
	);
	// A peer's address rather than something it granted. Both are shown in
	// this app, so reaching for the wrong one is a mistake worth naming.
	assertEquals(
		sessionCapabilityRefusal("ocapn://127.0.0.1%3A7300.tcp"),
		"That is a peer's address rather than a capability it granted. " +
			"The session's own link has a /s/ in it, after the address.",
	);
	assertEquals(sessionCapabilityRefusal("ocapn://127.0.0.1%3A7300.tcp/s/swiss"), "");
});

Deno.test("a refusal that is not a native error is passed through as it stands", () => {
	assertEquals(locatorRefusal("", "session capability link"), "");
	assertEquals(
		locatorRefusal("The session peer could not be reached.", "session capability link"),
		"The session peer could not be reached.",
	);
});

Deno.test("a native error offers the likely mistake rather than diagnosing one", () => {
	const said = locatorRefusal("pancake error -2: uri parse: UriParseError", "session capability link");
	// It suggests checking the paste; it does not tell the reader their link
	// was truncated, which the code it was handed does not establish.
	assertEquals(said.includes("Check that you pasted all of it"), true);
	assertEquals(said.includes("is not a whole"), false);
	assertEquals(said.includes("pancake error -2"), true);
});
