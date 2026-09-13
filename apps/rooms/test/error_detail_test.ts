// Whether a refusal is too much to keep next to the control it answers.

import {
	actionRefusal,
	errorDetailTitle,
	locatorRefusal,
	needsErrorDetail,
	sessionCapabilityRefusal,
} from "../web/ui/error_text.ts";
import { assertEquals } from "./assert.ts";
import { NICK_TAKEN, RoomsError, roomsErrorInMessage } from "../lib/error_codes.ts";
import { failureView } from "../lib/text/failure.ts";

Deno.test("Rooms errors parse only from the carrier position that owns the code", () => {
	assertEquals(roomsErrorInMessage(new RoomsError(NICK_TAKEN, "alice"))?.code, NICK_TAKEN);
	assertEquals(roomsErrorInMessage(new Error("glowcap error -14: nick-taken: alice"))?.detail, "alice");
	assertEquals(roomsErrorInMessage(new Error("transport: nick-taken: alice")), null);
	assertEquals(roomsErrorInMessage(new Error("glowcap error 999999999999: nick-taken: alice")), null);
	assertEquals(roomsErrorInMessage(new Error("glowcap error +14: nick-taken: alice")), null);
	assertEquals(roomsErrorInMessage(new Error("blob-expired: nick-taken: alice"))?.detail, "nick-taken: alice");
});

Deno.test("an unexpected failure keeps its diagnostic without inventing retry authority", () => {
	assertEquals(failureView(new Error("transport retired")), {
		code: "unexpected",
		subject: "operation",
		retry: "unknown",
		summary: "Rooms couldn't complete that action.",
		action: "Check the diagnostic before trying again.",
		detail: "transport retired",
	});
});

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
	// The wording is the catalog's and moves when the voice does; what each
	// refusal has to carry is the detail that tells the reader which of their
	// several ocapn:// strings they should have reached for.
	assertEquals(sessionCapabilityRefusal(""), "");
	assertEquals(sessionCapabilityRefusal("hello").includes("ocapn://"), true);
	// A peer's address rather than something it granted. Both are shown in
	// this app, so reaching for the wrong one is a mistake worth naming.
	assertEquals(sessionCapabilityRefusal("ocapn://127.0.0.1%3A7300.tcp").includes("/s/"), true);
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
	const said = locatorRefusal("glowcap error -2: uri parse: UriParseError", "session capability link");
	// It suggests checking the paste; it does not tell the reader their link
	// was truncated, which the code it was handed does not establish.
	assertEquals(said.toLowerCase().includes("pasted"), true);
	assertEquals(said.includes("is not a whole"), false);
	assertEquals(said.includes("truncated"), false);
	assertEquals(said.includes("glowcap error -2"), true);
});

Deno.test("a UI action preserves expected refusals and contains unexpected failures", async () => {
	assertEquals(
		await actionRefusal(() => Promise.resolve("That nickname is already taken.")),
		"That nickname is already taken.",
	);
	const transport = await actionRefusal(() => Promise.reject(new Error("transport retired")));
	assertEquals(transport.includes("Rooms couldn't complete"), true);
	assertEquals(transport.includes("transport retired"), true);
	const wire = await actionRefusal(() => Promise.reject("wire refused"));
	assertEquals(wire.includes("Rooms couldn't complete"), true);
	assertEquals(wire.includes("wire refused"), true);
});
