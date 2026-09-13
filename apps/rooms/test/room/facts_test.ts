// What a room says about itself, and what a line costs against it.
//
// A room may say it carries less than this app allows — one bridged to IRC has
// to fit each line into a protocol that gives 512 bytes to the whole thing,
// envelope included. That is a fact a room states about itself rather than a
// mode anybody switches on. Two rooms in one tab can therefore answer
// differently, and the value is arithmetic rather than a flag.
//
// The counting is in bytes, which is the part worth pinning: everything a
// reader types is characters, everything a limit downstream counts is bytes,
// and the two disagree the moment anybody writes an emoji.

import { lineNotShowable, lineRoom } from "../../web/ui/text.ts";
import {
	lineCost,
	MAX_DIRECTORY_DISCOVERY_ROWS,
	MAX_LINE,
	MAX_NICK,
	MAX_ROOM,
	MAX_SEAT_BADGE,
	MAX_SEAT_SAID,
	MAX_SIGNAL_CANDIDATE,
	MAX_SIGNAL_ID,
	MAX_SIGNAL_SDP,
	MAX_TOPIC,
	relayedSignalFits,
} from "../../lib/limits.ts";
import {
	readCarries,
	readLineBytes,
	readListed,
	readPresence,
	readRoomEvent,
	readRoomFacts,
	readTopic,
} from "../../lib/room/client.ts";
import { parseDirectoryWatchSnapshot, parseRooms } from "../../lib/directory_publications.ts";
import { assertEquals } from "../assert.ts";
import { registrationId } from "../support/registration.ts";

const APP_MAX = 8192;

Deno.test("a line costs what it costs to carry, not what it looks like", () => {
	assertEquals(lineCost("hello"), 5, "plain");
	// Two characters to a reader, one `length` of two in JavaScript, four bytes
	// on the wire. A message measured any other way passes here and is cut on the
	// far side, where nobody can see it happen.
	assertEquals(lineCost("🚀"), 4, "an emoji");
	assertEquals("🚀".length, 2, "which is not what JavaScript would have said");
	assertEquals(lineCost("é"), 2, "an accent");
	assertEquals(lineCost("\ud800"), 3, "a lone high surrogate");
	assertEquals(lineCost("\udc00"), 3, "a lone low surrogate");
	assertEquals(lineCost(""), 0, "nothing");
	for (const text of ["hello", "🚀", "é", "\ud800", "\udc00", "a🚀é\ud800"]) {
		assertEquals(lineCost(text), new TextEncoder().encode(text).length, `TextEncoder agrees for ${text}`);
	}
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
	// A room that states a topic longer than a topic may be has said something
	// this cannot show, and a topic sits on screen for as long as the room is
	// open. Read the way a malformed cap is: it said nothing, which leaves the
	// last topic a reader could actually read in place.
	assertEquals(
		readTopic(["alice", "welcome", "topic", "t".repeat(MAX_TOPIC + 1)]),
		undefined,
		"a room stated a topic longer than one may be and it was taken",
	);
	assertEquals(readTopic(["alice", "welcome", "topic", "t".repeat(MAX_TOPIC)]), "t".repeat(MAX_TOPIC));

	// The roster draws a row per name it is given, so a name longer than any this
	// protocol grants is dropped rather than drawn.
	const roster = readPresence(["room", "", "roster", "ada", "n".repeat(MAX_NICK + 1), "bo"]);
	assertEquals(
		roster?.kind === "roster" && roster.names.join(","),
		"ada,bo",
		"the roster took a name that is not one",
	);
	assertEquals(
		readPresence(["room", "", "join", "n".repeat(MAX_NICK + 1)]),
		undefined,
		"somebody joined under a name longer than one may be",
	);
	assertEquals(readTopic(["alice", "hi", "roster", "bob"]), undefined, "nor does a roster");
	// A topic that is not text is a room saying something malformed, which reads
	// as having said nothing rather than as a topic of "undefined".
	assertEquals(readTopic(["alice", "welcome", "topic", 7n]), undefined, "not text");
});

Deno.test("a bridged room states one member's IRC seat without exposing an account", () => {
	assertEquals(
		readPresence(["room", "", "seat", "alice", "linked", "alice_irc", "Libera", "LINKED", "Rooms + Libera"]),
		{
			kind: "seat",
			name: "alice",
			state: "linked",
			nick: "alice_irc",
			network: "Libera",
			badge: "LINKED",
			said: "Rooms + Libera",
		},
		"a linked seat",
	);
	assertEquals(
		readPresence(["room", "", "seat", "alice", "rooms", "alice_irc", "Libera", "ROOMS", "Rooms only"]),
		{
			kind: "seat",
			name: "alice",
			state: "rooms",
			nick: "alice_irc",
			network: "Libera",
			badge: "ROOMS",
			said: "Rooms only",
		},
		"a cleared seat",
	);
	for (
		const malformed of [
			["room", "", "seat", "alice", "unknown", "alice_irc", "Libera", "LINKED", "Rooms + Libera"],
			["room", "", "seat", "alice", "linked", "alice_irc"],
			["room", "", "seat", "a".repeat(MAX_NICK + 1), "linked", "alice_irc", "Libera", "L", "l"],
			// A seat with no words for it. The badge and the sentence are what a
			// reader sees, so a bridge that says a seat exists and will not say what
			// to call it has said nothing this room can draw.
			["room", "", "seat", "alice", "linked", "alice_irc", "Libera"],
			["room", "", "seat", "alice", "linked", "alice_irc", "Libera", "LINKED"],
			["room", "", "seat", "alice", "linked", "alice_irc", "Libera", "", "Rooms + Libera"],
			["room", "", "seat", "alice", "linked", "alice_irc", "Libera", "LINKED", ""],
			// And words past what a room admits, which an untrusted bridge is the
			// reason to bound rather than a careless one.
			["room", "", "seat", "alice", "linked", "alice_irc", "Libera", "L".repeat(MAX_SEAT_BADGE + 1), "l"],
			["room", "", "seat", "alice", "linked", "alice_irc", "Libera", "L", "l".repeat(MAX_SEAT_SAID + 1)],
		]
	) {
		assertEquals(readPresence(malformed), undefined, `malformed seat ${JSON.stringify(malformed)}`);
	}
});

Deno.test("the two room facts do not answer for each other", () => {
	// They ride the same tail and are told apart by their name alone, so reading
	// one as the other would put a byte count in the topic bar or a sentence in
	// the line cap.
	assertEquals(readTopic(["a", "b", "line-bytes", 400n]), undefined, "a cap is not a topic");
	assertEquals(readLineBytes(["a", "b", "topic", "about things"]), undefined, "a topic is not a cap");
	assertEquals(readListed(["a", "b", "topic", "about things"]), undefined, "a topic is not listed-ness");
	assertEquals(readTopic(["a", "b", "listed"]), undefined, "listed-ness is not a topic");
	assertEquals(readListed(["room", "", "listed"]), true, "listed");
	assertEquals(readListed(["room", "", "unlisted"]), false, "unlisted");
});

Deno.test("a room states what it carries, and a word it does not know is skipped", () => {
	// Positive and additive: what is named is carried, what is not is not.
	assertEquals(readCarries(["room", "", "carries", "previews", "typing"]), { previews: true, typing: true }, "both");
	assertEquals(readCarries(["room", "", "carries", "typing"]), { previews: false, typing: true }, "one");
	assertEquals(readCarries(["room", "", "carries"]), { previews: false, typing: false }, "neither, as IRC says");
	// A room may say something newer than this client before the client is
	// rebuilt; the words it knows still land.
	assertEquals(readCarries(["room", "", "carries", "holograms", "previews"]), { previews: true, typing: false });
	// Not a statement at all.
	assertEquals(readCarries(["room", "", "listed"]), undefined, "another tag");
	assertEquals(readCarries(["alice", "hello"]), undefined, "an ordinary line");
	// Malformed is nothing said: a word that is not a word, a word past its
	// bound, or more words than any room has.
	assertEquals(readCarries(["room", "", "carries", 4]), undefined, "not a word");
	assertEquals(readCarries(["room", "", "carries", ""]), undefined, "an empty word");
	assertEquals(readCarries(["room", "", "carries", "x".repeat(17)]), undefined, "past the bound");
	assertEquals(readCarries(["room", "", "carries", ...Array(17).fill("typing")]), undefined, "too many");
	assertEquals(
		readRoomFacts(["room", "", "carries", "previews"]),
		{ carries: { previews: true, typing: false } },
		"on the facts",
	);
});

Deno.test("a line carries whichever facts the room put on it, and nothing otherwise", () => {
	// The common case: a line that says nothing about the room allocates nothing
	// and a caller can ask one question rather than probing each field.
	assertEquals(readRoomFacts(["alice", "hello"]), undefined, "an ordinary line");
	assertEquals(readRoomFacts(["room", "welcome", "roster", "bob"]), undefined, "a roster");
	assertEquals(readRoomFacts(["room", "welcome", "topic", "about things"]), { topic: "about things" }, "a topic");
	assertEquals(readRoomFacts(["room", "welcome", "line-bytes", 400n]), { lineBytes: 400 }, "a cap");
	assertEquals(readRoomFacts(["room", "", "listed"]), { listed: true }, "a listed occupancy");
	assertEquals(readRoomFacts(["room", "", "unlisted"]), { listed: false }, "an unlisted occupancy");
	// A topic taken down is a fact, so it survives the "did this line say
	// anything" question rather than being read as silence.
	assertEquals(readRoomFacts(["room", "welcome", "topic", ""]), { topic: "" }, "a topic cleared");
});

Deno.test("a line from somebody else is held to what this app will show", () => {
	// A room holds its members to its cap, and a room is not the only source: a
	// direct line has no room in its path, and a room is whatever answered the
	// address a reader typed. What arrives is drawn into the log and walked by the
	// rich-text pass, so an unbounded line is an unbounded amount of both.
	assertEquals(lineNotShowable("bo", "an ordinary thing to say"), null);
	assertEquals(lineNotShowable("bo", "x".repeat(MAX_LINE)), null, "a line exactly at the cap is showable");
	const long = lineNotShowable("bo", "x".repeat(MAX_LINE + 1));
	// Refused rather than cut, and it says whose line is missing rather than this
	// app finishing somebody's sentence for them.
	assertEquals(long !== null && long.includes("bo"), true, `the line nobody can show said ${long}`);

	// Counted in bytes, the way the wire and the room count. In JavaScript's own
	// units this line is inside the cap; on the wire it is four times it.
	assertEquals(
		lineNotShowable("bo", "🚀".repeat(MAX_LINE / 2)) !== null,
		true,
		"an emoji line was measured in the wrong units",
	);

	// And a line nobody can attribute is not shown either: no name this room
	// grants is that long, so the sentence cannot repeat it back.
	const nameless = lineNotShowable("n".repeat(MAX_NICK + 1), "hello");
	assertEquals(nameless !== null && !nameless.includes("nnnn"), true, `an unnamed line said ${nameless}`);
});

Deno.test("a directory's live feed is read the way its other claims are", () => {
	// This is the feed a directory keeps open, and every event on it names
	// something and counts something. A kind nobody knows used to fall through to
	// the room list, a name longer than one may be was kept for as long as the tab
	// held that directory, and a count that is not a count was drawn as it stood.
	const lobby = {
		id: "room-generation",
		name: "lobby",
		kind: "local" as const,
		count: 1,
		origin: "",
		proof: "local" as const,
		offers: "participant" as const,
	};
	assertEquals(readRoomEvent(["opened", "lobby", 1n, "room-generation", "local", "", "local", "participant"]), {
		kind: "opened",
		name: "lobby",
		count: 1,
		entry: lobby,
	});
	assertEquals(readRoomEvent(["registered", "ada", 1n, registrationId(1)]), {
		kind: "registered",
		name: "ada",
		registrationId: registrationId(1),
		count: 1,
		entry: null,
	});
	assertEquals(readRoomEvent(["truncated", 4n]), {
		kind: "truncated",
		name: "",
		count: 4,
		entry: null,
	});
	assertEquals(readRoomEvent(["truncated", 4n, "extra"]), null, "a truncated event accepted trailing data");

	assertEquals(readRoomEvent(["gossip", "lobby", 1n]), null, "a kind nobody knows was taken as one");
	assertEquals(readRoomEvent(["opened", "", 1n]), null, "an unnamed room was taken");
	assertEquals(readRoomEvent(["count", "r".repeat(MAX_ROOM + 1), 1n]), null, "a room name past its ceiling was kept");
	assertEquals(
		readRoomEvent(["registered", "n".repeat(MAX_NICK + 1), 1n]),
		null,
		"a member name past its ceiling was kept",
	);
	// A member event and a room event are two different things wearing one field,
	// so each is held to its own ceiling rather than to the looser of the two.
	assertEquals(
		readRoomEvent([
			"count",
			"r".repeat(MAX_ROOM),
			2n,
			"room-generation",
			"local",
			"",
			"local",
			"participant",
		])?.name.length,
		MAX_ROOM,
	);

	assertEquals(readRoomEvent(["count", "lobby", "many"]), null, "a count that is not a count was drawn");
	assertEquals(readRoomEvent(["count", "lobby", -1n]), null, "a room with fewer than nobody in it was drawn");
	assertEquals(
		readRoomEvent([
			"opened",
			"remote",
			null,
			"foreign-generation",
			"foreign",
			"peer-key",
			"authenticated",
			"participant",
		]),
		{
			kind: "opened",
			name: "remote",
			count: null,
			entry: {
				id: "foreign-generation",
				name: "remote",
				kind: "foreign",
				count: null,
				origin: "peer-key",
				proof: "authenticated",
				offers: "participant",
			},
		},
		"a foreign room's unknown occupancy was invented",
	);
	assertEquals(
		readRoomEvent([
			"count",
			"network/#channel",
			3n,
			"bridge-generation",
			"bridge",
			"irc.example:6697",
			"bridge",
			"participant",
		])
			?.entry,
		{
			id: "bridge-generation",
			name: "network/#channel",
			kind: "bridge",
			count: 3,
			origin: "irc.example:6697",
			proof: "bridge",
			offers: "participant",
		},
		"a bridge that knows its occupancy lost its exact publication presentation",
	);
});

Deno.test("a directory snapshot is complete, bounded, and generation-unique", () => {
	const local = ["lobby", 1n, "room-generation", "local", "", "local", "participant"];
	assertEquals(parseRooms([local]).map((room) => room.id), ["room-generation"]);
	let malformed = "";
	try {
		parseRooms([local, ["broken"]]);
	} catch (error) {
		malformed = error instanceof Error ? error.message : String(error);
	}
	assertEquals(malformed.includes("invalid room-list row"), true);
	let duplicate = "";
	try {
		parseRooms([local, local]);
	} catch (error) {
		duplicate = error instanceof Error ? error.message : String(error);
	}
	assertEquals(duplicate.includes("invalid room-list row"), true);
	let oversized = "";
	try {
		parseRooms(Array.from({ length: MAX_DIRECTORY_DISCOVERY_ROWS + 1 }, () => local));
	} catch (error) {
		oversized = error instanceof Error ? error.message : String(error);
	}
	assertEquals(oversized.includes("oversized room list"), true);
});

Deno.test("a directory watch snapshot validates claims and aggregate bounds as one document", () => {
	const local = ["lobby", 1n, "room-generation", "local", "", "local", "participant"];
	assertEquals(parseDirectoryWatchSnapshot([[local], [["Ada", registrationId(1)]], 0n]), {
		rooms: [{
			id: "room-generation",
			name: "lobby",
			kind: "local",
			count: 1,
			origin: "",
			proof: "local",
			offers: "participant",
		}],
		peers: [{ name: "Ada", registrationId: registrationId(1) }],
		omitted: 0,
	});
	for (
		const malformed of [
			[[local], [["Ada", registrationId(1)], ["ada", registrationId(2)]], 0n],
			[[local], [["Ada", registrationId(1)], ["Bo", registrationId(1)]], 0n],
			[[local], [["Ada", ""]], 0n],
			[[local], [["Ada", registrationId(1)]], -1n],
		]
	) {
		assertEquals(
			refused(() => parseDirectoryWatchSnapshot(malformed)),
			true,
			"a malformed directory watch snapshot was accepted",
		);
	}
});

function refused(run: () => unknown): boolean {
	try {
		run();
		return false;
	} catch {
		return true;
	}
}

Deno.test("a relayed bring-up is held to a size at both ends of the relay", () => {
	// The directory carries an offer, an answer, and every candidate between two
	// members as they stand, so their size is the room's to bound rather than a
	// sender's to choose. A member holds what arrives to the same size, because a
	// directory is whatever answered the address they typed and what it relays is
	// only as bounded as it felt like being — and on that side the id becomes a
	// map key and the payload is parsed before anything else looks at it.
	assertEquals(relayedSignalFits("description", "x1", "v=0\r\no=- 1 1 IN IP4 0.0.0.0"), true);
	assertEquals(relayedSignalFits("candidate", "x1", '{"candidate":"a=candidate:1 1 udp"}'), true);

	assertEquals(relayedSignalFits("description", "x1", "v".repeat(MAX_SIGNAL_SDP + 1)), false);
	assertEquals(relayedSignalFits("description", "x1", "é".repeat(MAX_SIGNAL_SDP / 2)), true);
	assertEquals(relayedSignalFits("description", "x1", "é".repeat(Math.floor(MAX_SIGNAL_SDP / 2) + 1)), false);
	assertEquals(relayedSignalFits("candidate", "x1", "c".repeat(MAX_SIGNAL_CANDIDATE + 1)), false);
	assertEquals(relayedSignalFits("candidate", "x1", "é".repeat(MAX_SIGNAL_CANDIDATE / 2)), true);
	assertEquals(
		relayedSignalFits("candidate", "x1", "é".repeat(Math.floor(MAX_SIGNAL_CANDIDATE / 2) + 1)),
		false,
	);
	// A candidate is a line, a description is a document: the looser bound is not
	// the one a candidate gets.
	assertEquals(relayedSignalFits("candidate", "x1", "c".repeat(MAX_SIGNAL_SDP)), false);

	assertEquals(relayedSignalFits("description", "", "v=0"), false, "an exchange with no handle was acted on");
	assertEquals(
		relayedSignalFits("description", "x".repeat(MAX_SIGNAL_ID + 1), "v=0"),
		false,
		"a handle longer than one may be became a key",
	);
	assertEquals(
		relayedSignalFits("description", "é".repeat(Math.floor(MAX_SIGNAL_ID / 2) + 1), "v=0"),
		false,
		"a byte-long handle became a key",
	);
	assertEquals(relayedSignalFits("description", "é".repeat(MAX_SIGNAL_ID / 2), "v=0"), true);
	assertEquals(relayedSignalFits("candidate", "x1", ""), false, "an empty candidate was acted on");
});
