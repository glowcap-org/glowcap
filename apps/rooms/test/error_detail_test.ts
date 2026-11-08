// Whether a refusal is too much to keep next to the control it answers.

import { actionRefusal, errorDetailTitle, needsErrorDetail, sessionCapabilityRefusal } from "../web/ui/error_text.ts";
import { attachedSessionFailureText } from "../web/ui/session/attached_failure.ts";
import { assertEquals } from "./assert.ts";
import { NICK_TAKEN, RoomsError, roomsErrorInMessage } from "../lib/error_codes.ts";
import {
	doorBlocked,
	doorUnreachable,
	failureView,
	refusalText,
	renderFailure,
	transportBreak,
} from "../lib/text/failure.ts";

Deno.test("Rooms errors parse only from the carrier position that owns the code", () => {
	assertEquals(roomsErrorInMessage(new RoomsError(NICK_TAKEN, "alice"))?.code, NICK_TAKEN);
	assertEquals(roomsErrorInMessage(new Error("glowcap error -14: nick-taken: alice"))?.detail, "alice");
	// A dial refused inside the runtime climbs through two layers, each adding its status.
	assertEquals(
		roomsErrorInMessage(new Error("glowcap error -12: glowcap error -8: no-server: none chosen"))?.code,
		"no-server",
	);
	assertEquals(roomsErrorInMessage(new Error("transport: nick-taken: alice")), null);
	assertEquals(roomsErrorInMessage(new Error("glowcap error 999999999999: nick-taken: alice")), null);
	assertEquals(roomsErrorInMessage(new Error("glowcap error +14: nick-taken: alice")), null);
	assertEquals(roomsErrorInMessage(new Error("blob-expired: nick-taken: alice"))?.detail, "nick-taken: alice");
});

Deno.test("an unexpected failure keeps its diagnostic without inventing retry authority", () => {
	assertEquals(refusalText(new Error("transport retired")).endsWith("again. (transport retired)"), true);
	assertEquals(failureView(new Error("transport retired")), {
		code: "unexpected",
		subject: "operation",
		retry: "unknown",
		summary: "Rooms couldn't complete that action.",
		action: "Check the diagnostic before trying again.",
		detail: "transport retired",
	});
});

Deno.test("a native access denial explains permissions and keeps the exact diagnostic", () => {
	const diagnostic = "glowcap error -12: Denied";
	const view = failureView(new Error(diagnostic));
	assertEquals(view.code, "access-denied");
	assertEquals(view.retry, "after-state-change");
	assertEquals(view.detail, diagnostic);
	assertEquals(view.summary, "This access doesn't allow that action.");
	assertEquals(view.action, "Ask whoever shared it to review the permissions.");
	for (
		const message of [
			"transport: Denied",
			"glowcap error -12: upstream: Denied",
			"glowcap error -12: Denied: nick-taken",
		]
	) {
		assertEquals(failureView(new Error(message)).code, "unexpected");
	}
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

Deno.test("a value glowcap could not read offers the likely mistake rather than diagnosing one", () => {
	const view = failureView(new Error("glowcap error -2: uri parse: UriParseError"));
	assertEquals(view.code, "unreadable-value");
	assertEquals(view.retry, "after-request-change");
	const said = renderFailure(view);
	// It suggests checking the text is whole; it does not tell the reader their
	// link was truncated, which the code it was handed does not establish.
	assertEquals(said.includes("from ocapn:// to the end"), true);
	assertEquals(said.includes("is not a whole"), false);
	assertEquals(said.includes("truncated"), false);
	// The cause keeps glowcap's own words, with no Rooms code in front.
	assertEquals(said.endsWith("(glowcap error -2: uri parse: UriParseError)"), true);
	// Only the leading position names the code: a -2 inside another cause is
	// that cause's business.
	assertEquals(failureView(new Error("glowcap error -12: glowcap error -2: x")).code, "unexpected");
});

Deno.test("a break on the way is told apart from a value or a denial", () => {
	// A broken call carrying the break's own code is the way, not the link; a
	// denial the peer answered is neither, and so is a value it could not read.
	assertEquals(
		transportBreak(new Error("glowcap error -12: glowcap error -8: browser channel error")),
		"glowcap error -12: glowcap error -8: browser channel error",
	);
	assertEquals(transportBreak(new Error("glowcap error -12: Denied")), null);
	assertEquals(transportBreak(new Error("glowcap error -2: host: MalformedPath")), null);
	assertEquals(transportBreak(new Error("That name is taken.")), null);
});

Deno.test("a reach through the browser's own relay door names the relay, and keeps the break when it has one", () => {
	const broke = doorUnreachable("127.0.0.1:8080", "glowcap error -12: glowcap error -8: browser channel error");
	assertEquals(broke.startsWith("Rooms couldn't reach that directory through its relay at 127.0.0.1:8080."), true);
	assertEquals(broke.endsWith("(glowcap error -12: glowcap error -8: browser channel error)"), true);
	// The dial reported another door's refusal, so there is no break to quote.
	assertEquals(doorUnreachable("127.0.0.1:8080", "").endsWith("isn't answering."), true);
	assertEquals(doorBlocked("prompt", "x").includes("Allow it when the browser asks, then connect again."), true);
	assertEquals(doorBlocked("denied", "x").includes("site settings, then connect again."), true);
});

Deno.test("a session act that broke on the way names the server this browser goes through", () => {
	const server = { base: "https://rooms.example/", chosen: true };
	const broke = new Error("glowcap error -12: glowcap error -8: browser channel error");
	const named = attachedSessionFailureText(broke, server);
	assertEquals(named.includes("rooms.example"), true);
	assertEquals(named.includes("browser channel error"), true);
	// With no server to name, the failure stands in its own words.
	const bare = attachedSessionFailureText(broke, null);
	assertEquals(bare.includes("rooms.example"), false);
	assertEquals(bare.includes("browser channel error"), true);
	// A refusal that is about the link never blames the server.
	assertEquals(
		attachedSessionFailureText(new Error("glowcap error -12: Denied"), server).includes("rooms.example"),
		false,
	);
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
