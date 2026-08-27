// The interface's general text derivations, kept exact without a DOM.

import { assertEquals } from "./assert.ts";
import { conversationReach, dirCaptionSaid, dirConnection, dirStanding, footState } from "../web/ui/text.ts";

// The rail foot's state row says how the reader stands, and the connection
// only when standing cannot be the answer. It was written the other way once:
// any sentence the net layer had written won, so a reader who stepped away
// watched their own standing replaced by whichever directory was reaching a
// locator, and the line under their name showed an address instead.
Deno.test("the foot says the reader's standing on a settled connection", () => {
	assertEquals(footState("connected", "back in ten", true), { said: "back in ten", away: true });
	assertEquals(footState("connected", "", true), { said: "here", away: false });
});

Deno.test("the foot says the phase before a connection settles, never an address", () => {
	assertEquals(footState("connecting", "", true), { said: "connecting…", away: false });
	assertEquals(footState("reconnecting", "back in ten", true), { said: "reconnecting…", away: false });
	assertEquals(footState("disconnected", "", true), { said: "not connected", away: false });
});

Deno.test("with no name granted the foot says the plain connected word", () => {
	assertEquals(footState("connected", "", false), { said: "connected", away: false });
	// A standing is the reader's own, so it is said even before a directory
	// has granted them a name.
	assertEquals(footState("connected", "away", false), { said: "away", away: true });
});

// How one directory is doing is that directory's own fact, and every surface
// that reports it reads these. The page used to hold a single value for it, so
// a directory coming back cleared the notice for one that was still away.
Deno.test("a connected directory has nothing for a row to say", () => {
	assertEquals(dirStanding("connected"), "");
	assertEquals(dirCaptionSaid("this directory", "connected"), "About this directory");
});

Deno.test("a row on a directory that is away says the phase and names it", () => {
	assertEquals(dirStanding("reconnecting"), "Reconnecting…");
	assertEquals(dirStanding("disconnected"), "Not connected");
	assertEquals(dirStanding("connecting"), "Connecting…");
	assertEquals(dirCaptionSaid("127.0.0.1:6000", "reconnecting"), "About 127.0.0.1:6000, reconnecting…");
});

// Two directories, read the same way, one reading each. Nothing here can carry
// one directory's answer to another, which is the whole of the fix: the fact is
// a property of the directory the row is on rather than of the page.
Deno.test("one directory coming back leaves another's standing alone", () => {
	const away = dirStanding("reconnecting");
	assertEquals(dirStanding("connected"), "");
	assertEquals(away, "Reconnecting…");
	assertEquals(dirStanding("reconnecting"), away);
});

// The card says both parts. The sentence is dropped when it only echoes the
// phase word, so a reader is never told the same thing twice in one line.
Deno.test("a directory's card says what it is doing beside the phase", () => {
	assertEquals(dirConnection("reconnecting", "could not reach the room directory; retrying…"), {
		said: "Reconnecting…",
		why: "could not reach the room directory; retrying…",
	});
	assertEquals(dirConnection("connected", ""), { said: "Connected", why: "" });
	assertEquals(dirConnection("disconnected", "not connected"), { said: "Not connected", why: "" });
});

Deno.test("a conversation card says why it copies the directory's locator", () => {
	assertEquals(
		conversationReach({ type: "room", held: false, id: "lobby" }).includes("not a separate address for #lobby"),
		true,
	);
	assertEquals(
		conversationReach({ type: "room", held: true, id: "secret" }).includes("live reference"),
		true,
	);
	assertEquals(
		conversationReach({ type: "room", held: true, id: "secret", link: "ocapn://peer.tcp/s/swiss" }).includes(
			"sturdyref",
		),
		true,
	);
	assertEquals(
		conversationReach({ type: "dm" }).includes("no room address"),
		true,
	);
});
