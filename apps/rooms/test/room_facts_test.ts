// What a room says about itself, and what a line costs against it.
//
// A room may say it carries less than this app allows — one bridged to IRC has
// to fit each line into a protocol that gives 512 bytes to the whole thing,
// envelope included. That is a fact a room states about itself rather than a
// mode anybody switches on, which is what lets two rooms in one tab answer
// differently, and it is why this is arithmetic rather than a flag.
//
// The counting is in bytes, which is the part worth pinning: everything a
// reader types is characters, everything a limit downstream counts is bytes,
// and the two disagree the moment anybody writes an emoji.

import { lineCost, lineRoom } from "../web/ui/text.ts";
import { readLineBytes, readRoomFacts, readTopic } from "../lib/room_client.ts";
import { assertEquals } from "./assert.ts";

const APP_MAX = 8192;

Deno.test("a line costs what it costs to carry, not what it looks like", () => {
	assertEquals(lineCost("hello"), 5, "plain");
	// Two characters to a reader, one `length` of two in JavaScript, four bytes
	// on the wire. A message measured any other way passes here and is cut on the
	// far side, where nobody can see it happen.
	assertEquals(lineCost("🚀"), 4, "an emoji");
	assertEquals("🚀".length, 2, "which is not what JavaScript would have said");
	assertEquals(lineCost("é"), 2, "an accent");
	assertEquals(lineCost(""), 0, "nothing");
});

Deno.test("a room with nothing to say about it is capped exactly as before", () => {
	assertEquals(lineRoom(null, APP_MAX), APP_MAX, "no conversation");
	assertEquals(lineRoom({ type: "dm" }, APP_MAX), APP_MAX, "a direct line");
	assertEquals(lineRoom({ type: "room" }, APP_MAX), APP_MAX, "a room that said nothing");
});

Deno.test("a room that asks for less gets less, and cannot ask for more", () => {
	assertEquals(lineRoom({ type: "room", lineBytes: 400 }, APP_MAX), 400, "a bridged room");
	// The tighter of the two, always: a room cannot talk this app into carrying
	// more than it would have, which keeps one cap the ceiling rather than making
	// every room's claim load-bearing.
	assertEquals(lineRoom({ type: "room", lineBytes: 99_999 }, APP_MAX), APP_MAX, "a room asking for more");
});

Deno.test("a room states its cap in the tail a presence change rides in", () => {
	assertEquals(readLineBytes(["alice", "welcome", "line-bytes", 400n]), 400, "as a number on the wire");
	assertEquals(readLineBytes(["alice", "welcome", "line-bytes", 400]), 400, "or as a plain one");
	// A roster or a join is not a cap, and reading one as a cap would silently
	// shorten every line in the room.
	assertEquals(readLineBytes(["alice", "hi", "roster", "bob"]), undefined, "a roster");
	assertEquals(readLineBytes(["alice", "hi"]), undefined, "an ordinary line");
	// A malformed claim is a room saying nothing, rather than a cap of zero that
	// would refuse every message anybody typed.
	assertEquals(readLineBytes(["alice", "welcome", "line-bytes", 0n]), undefined, "zero");
	assertEquals(readLineBytes(["alice", "welcome", "line-bytes", -5n]), undefined, "negative");
	assertEquals(readLineBytes(["alice", "welcome", "line-bytes", "lots"]), undefined, "not a number");
});

// ── What a room says it is about ───────────────────────────────────────────
// The other fact a room states about itself, read the same way and for the same
// reason: a bridge or a room can begin saying it whenever it likes, and clients
// already shipped will understand.

Deno.test("a room states its topic in the same tail", () => {
	assertEquals(readTopic(["alice", "welcome", "topic", "release 2.0 is out"]), "release 2.0 is out");
	// Cleared and never-set are different things, and both have to be sayable:
	// somebody taking a topic down is doing something on purpose, and reading it
	// as "nothing said" would make clearing one impossible.
	assertEquals(readTopic(["alice", "welcome", "topic", ""]), "", "cleared on purpose");
	assertEquals(readTopic(["alice", "hi"]), undefined, "an ordinary line says nothing about it");
	assertEquals(readTopic(["alice", "hi", "roster", "bob"]), undefined, "nor does a roster");
	// A topic that is not text is a room saying something malformed, which reads
	// as having said nothing rather than as a topic of "undefined".
	assertEquals(readTopic(["alice", "welcome", "topic", 7n]), undefined, "not text");
});

Deno.test("the two room facts do not answer for each other", () => {
	// They ride the same tail and are told apart by their name alone, so reading
	// one as the other would put a byte count in the topic bar or a sentence in
	// the line cap.
	assertEquals(readTopic(["a", "b", "line-bytes", 400n]), undefined, "a cap is not a topic");
	assertEquals(readLineBytes(["a", "b", "topic", "about things"]), undefined, "a topic is not a cap");
});

Deno.test("a line carries whichever facts the room put on it, and nothing otherwise", () => {
	// The common case: a line that says nothing about the room allocates nothing
	// and a caller can ask one question rather than probing each field.
	assertEquals(readRoomFacts(["alice", "hello"]), undefined, "an ordinary line");
	assertEquals(readRoomFacts(["room", "welcome", "roster", "bob"]), undefined, "a roster");
	assertEquals(readRoomFacts(["room", "welcome", "topic", "about things"]), { topic: "about things" }, "a topic");
	assertEquals(readRoomFacts(["room", "welcome", "line-bytes", 400n]), { lineBytes: 400 }, "a cap");
	// A topic taken down is a fact, so it survives the "did this line say
	// anything" question rather than being read as silence.
	assertEquals(readRoomFacts(["room", "welcome", "topic", ""]), { topic: "" }, "a topic cleared");
});
