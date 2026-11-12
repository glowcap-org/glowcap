// The interface's general text derivations, kept exact without a DOM.

import { assertEquals } from "./assert.ts";
import {
	conversationReach,
	dirCaptionSaid,
	dirConnection,
	directoryDmBlocked,
	dirStanding,
	dmPath,
	footState,
	lineCapSaid,
	peeringSourcesOf,
	tooLong,
} from "../web/ui/text.ts";
import { composerLineRefusal } from "../web/ui/composer/send.ts";
import { reachDirect, reachPublicRoom, reachRoomHeld, reachRoomLink } from "../lib/text/conversation.ts";
import { lineCost, MAX_LINE } from "../lib/limits.ts";
import type { Conv } from "../web/ui/conversation.ts";
import { type DirId, dirId, type DirView } from "../web/ui/directory.ts";

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
// that reports it reads these. A single page-wide value would let a directory
// coming back clear the notice for one that was still away.
Deno.test("a connected directory has nothing for a row to say", () => {
	assertEquals(dirStanding("connected"), "");
	assertEquals(dirCaptionSaid("this directory", "connected"), "this directory");
});

Deno.test("a row on a directory that is not connected says the phase and names it", () => {
	assertEquals(dirStanding("reconnecting"), "Reconnecting…");
	assertEquals(dirStanding("disconnected"), "Not connected");
	assertEquals(dirStanding("connecting"), "Connecting…");
	assertEquals(dirCaptionSaid("127.0.0.1:6000", "reconnecting"), "127.0.0.1:6000, reconnecting…");
	assertEquals(dirCaptionSaid("127.0.0.1:6000", "connecting"), "127.0.0.1:6000, connecting…");
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
	assertEquals(dirConnection("reconnecting", "could not reach the room directory. Retrying…"), {
		said: "Reconnecting…",
		why: "could not reach the room directory. Retrying…",
		route: "",
	});
	assertEquals(dirConnection("connected", ""), { said: "Connected", why: "", route: "" });
	assertEquals(dirConnection("disconnected", "not connected"), { said: "Not connected", why: "", route: "" });
});

// The route is said once the directory is connected, by the transport the
// connection runs over. A browser running its own session opens only the
// relay doors itself, so every other transport is said to go through its
// Rooms server. A transport that is reconnecting names no route: the words
// would be about a connection that is not there.
Deno.test("a connected directory says how it is reached", () => {
	assertEquals(dirConnection("connected", "", "noise-relay", true).route, "Encrypted, through a relay");
	assertEquals(dirConnection("connected", "", "tcp", true).route, "Over TCP, in the clear, through the Rooms server");
	assertEquals(dirConnection("connected", "", "tcp", false).route, "Over TCP, in the clear");
	assertEquals(dirConnection("connected", "", "iroh", false).route, "Encrypted, direct over iroh");
	assertEquals(dirConnection("reconnecting", "", "noise-relay", true).route, "");
	assertEquals(dirConnection("connected", "", "webrtc", true).route, "");
});

// A direct message's path is the transport its open line runs over, so a
// line that fell back to the server says so whatever the saved choice.
Deno.test("a direct message's path is the open line's transport", () => {
	assertEquals(dmPath("webrtc"), "Browser to browser, encrypted");
	assertEquals(dmPath("noise-relay"), "Through the Rooms server, encrypted end to end");
	assertEquals(dmPath("keyed-relay"), "Through the Rooms server, encrypted end to end");
	assertEquals(dmPath("iroh"), "Encrypted, direct over iroh");
	assertEquals(dmPath("carrier-pigeon"), "carrier-pigeon");
});

Deno.test("direct messages on a directory that is not live use the same connection words", () => {
	assertEquals(directoryDmBlocked("connecting"), "Unavailable: this directory is connecting…");
	assertEquals(directoryDmBlocked("reconnecting"), "Unavailable: this directory is reconnecting…");
	assertEquals(directoryDmBlocked("disconnected"), "Unavailable: this directory is not connected");
	assertEquals(directoryDmBlocked("connected"), "");
});

Deno.test("a conversation card says which address the reader is looking at", () => {
	// Asserted against the catalog, because the wording belongs to the voice and
	// what this proves is that each kind of conversation gets its own answer. A
	// needle copied out of the copy turns a rewording into a red test that has
	// caught nothing.
	assertEquals(conversationReach({ type: "room", held: false, id: "lobby" }), reachPublicRoom("#lobby"));
	assertEquals(conversationReach({ type: "room", held: true, id: "secret" }), reachRoomHeld);
	assertEquals(
		conversationReach({ type: "room", held: true, id: "secret", link: "ocapn://peer.tcp/s/swiss" }),
		reachRoomLink,
	);
	assertEquals(conversationReach({ type: "dm" }), reachDirect);
});

// A limit says which measure it is held to, because two of them are in use and
// they only agree in ASCII. A name is counted in characters; a message is
// counted in what it costs on the wire.
Deno.test("a refusal names the measure the limit is kept in", () => {
	assertEquals(tooLong("name", 32, "characters"), "name too long (max 32 characters)");
	assertEquals(tooLong("Message", 8192, "bytes"), "Message too long (max 8192 bytes)");
});

Deno.test("a message is refused by what it costs, and says so", () => {
	const room = { type: "room", key: "k", id: "design" } as unknown as Parameters<typeof composerLineRefusal>[0];
	// Well under the limit in characters, over it in what the wire carries. The
	// sentence must not promise this reader thousands of characters they cannot
	// have, and the further their script sits from ASCII the further out that
	// promise would be.
	const japanese = "あ".repeat(3000);
	assertEquals(japanese.length < MAX_LINE, true);
	assertEquals(lineCost(japanese) > MAX_LINE, true);
	assertEquals(composerLineRefusal(room, japanese), `Message too long (max ${MAX_LINE} bytes)`);
	assertEquals(composerLineRefusal(room, "あ".repeat(10)), null);
});

// The counter over the composer watches a bridged room's smaller cap and the
// app's own, so neither is first met by pressing Send.
Deno.test("the counter watches whichever cap is in force", () => {
	const app = { type: "room" as const };
	const bridged = { type: "room" as const, lineBytes: 512 };
	// Quiet while there is room to spare, under either cap.
	assertEquals(lineCapSaid(app, "x".repeat(100)), null);
	assertEquals(lineCapSaid(app, "x".repeat(6000)), null);
	assertEquals(lineCapSaid(bridged, "x".repeat(100)), null);
	// The app's own wall is counted, and is not called the room's.
	assertEquals(lineCapSaid(app, "x".repeat(7000)), { over: false, said: "1192 bytes left" });
	assertEquals(lineCapSaid(app, "x".repeat(8192)), { over: false, said: "0 bytes left" });
	assertEquals(lineCapSaid(app, "x".repeat(9000)), { over: true, said: "808 bytes too long" });
	// A room carrying less than the app is still named, because that is the cap
	// a reader has no way to know about.
	assertEquals(lineCapSaid(bridged, "x".repeat(600)), { over: true, said: "88 bytes too long for this room" });
	// A conversation that is not a room carries the app's cap.
	assertEquals(lineCapSaid(null, "x".repeat(9000)), { over: true, said: "808 bytes too long" });
	// It counts cost, so a script that spends three bytes a character reaches
	// the wall at a third of the length.
	assertEquals(lineCapSaid(app, "あ".repeat(3000)), { over: true, said: "808 bytes too long" });
	assertEquals(lineCapSaid(app, "あ".repeat(2000)), null);
});

Deno.test("peering only offers held durable entrances on another connected directory", () => {
	const home = dirId("home");
	const away = dirId("away");
	const convs = new Map<string, Conv>([
		["local", { type: "room", dir: home, key: "local", id: "general", linkToken: "local-access" } as Conv],
		["public", { type: "room", dir: away, key: "public", id: "listed" } as Conv],
		["foreign", { type: "room", dir: away, key: "foreign", id: "shared", linkToken: "foreign-access" } as Conv],
	]);
	const dirs = new Map<DirId, DirView>([
		[home, { session: "connected" } as DirView],
		[away, { session: "connecting" } as DirView],
	]);
	assertEquals(peeringSourcesOf(convs, home, home, dirs).map((source) => source.key), []);
	dirs.set(away, { session: "reconnecting" } as DirView);
	assertEquals(peeringSourcesOf(convs, home, home, dirs).map((source) => source.key), []);
	dirs.set(away, { session: "connected" } as DirView);
	assertEquals(peeringSourcesOf(convs, home, home, dirs).map((source) => source.key), ["foreign"]);
	// Peering governed by another directory publishes into that one, so home's
	// rooms are the sources and that directory's own are not.
	assertEquals(peeringSourcesOf(convs, away, home, dirs).map((source) => source.key), ["local"]);
});
