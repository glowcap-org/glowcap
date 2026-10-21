// Two ends of one wire: one session, one message, and who closes it.

import { assert, assertEquals } from "@std/assert";
import { convertEvent, makeBaseEventConverter, newFeedState } from "../feed.ts";
import { type BaseTimelineEvent } from "../record.ts";
import { expectKind } from "./harness.ts";
import { opened, pictureOf, wireName } from "./fixtures.ts";

Deno.test("two producers watching one wire draw one session", () => {
	// A browser tab publishes its own trace and the room server reports the
	// same connection. Both name the same wire, because both ends of a CapTP
	// session derive that name from the two public identifiers with the pair
	// sorted. One conversation is one edge however many ends report it.
	const convert = makeBaseEventConverter();
	const wire = wireName("a");
	const first = convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p1/live-h1-s1",
		a: "rooms",
		b: "127.0.0.1:0",
		provenance: "unauthenticated",
		session_id: wire,
		codec: "syrup",
	});
	assertEquals(first.filter((e) => e.kind === "session-opened").length, 1);
	const second = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p2/live-h1-s1",
		a: "tab-designator",
		b: "rooms",
		session_id: wire,
		codec: "syrup",
	});
	assertEquals(second.filter((e) => e.kind === "session-opened").length, 0);
	// The tab is drawn once, by the report that could say who it is. The room's
	// report drew nobody for that end, so this join has nothing to be a
	// duplicate of, two producers leave two nodes on stage, not three.
	assertEquals(
		second.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
		["tab-designator"],
	);
	assertEquals(
		pictureOf([...first, ...second]).peers.map((p) => p.split("=")[0]),
		["rooms", "tab-designator"],
	);
	// And the edge already on stage takes the tab on the end the room reported
	// as its partner, rather than a second edge being drawn to it.
	const attached = expectKind(
		second.find((e) => e.kind === "session-endpoint-attributed"),
		"session-endpoint-attributed",
	);
	assertEquals(attached.side, "b");
	assertEquals(attached.peerId, "tab-designator");
});

Deno.test("a tab's later session hangs off the node its end attached to", () => {
	// The whole point of joining two reports on one wire. The room sees a member
	// as an unverified claim and the member sees itself by its own key
	// designator; without the wire to join them the member is two nodes, and the
	// direct message it opens later hangs off the wrong one.
	const convert = makeBaseEventConverter();
	const roomWire = wireName("b");
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p1/live-h1-s1",
		a: "rooms",
		b: "127.0.0.1:0",
		provenance: "unauthenticated",
		session_id: roomWire,
		codec: "syrup",
	});
	const joined = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p2/live-h1-s1",
		a: "tab-designator",
		b: "rooms",
		session_id: roomWire,
		codec: "syrup",
	});
	// The tab's own report is what draws it, under its own designator.
	const tab = expectKind(
		joined.find((e) => e.kind === "peer-joined"),
		"peer-joined",
	).peerId;
	assertEquals(tab, "tab-designator");
	// Now the same tab opens a direct session to someone else. Its own end
	// must be the node already on stage, not a fresh one.
	const dm = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p2/live-h1-s2",
		a: "tab-designator",
		b: "other-tab",
		session_id: wireName("c"),
		codec: "syrup",
	});
	const opened = expectKind(
		dm.find((e) => e.kind === "session-opened"),
		"session-opened",
	);
	const newNodes = dm.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId);
	// Only the far end of the direct session is new.
	assertEquals(newNodes, ["other-tab"]);
	assertEquals(opened.a.peer, tab, "the tab's two sessions meet at one node");
	assertEquals(opened.a.attributedBy, "self-reported");
	assertEquals(opened.b.peer, "other-tab");
});

Deno.test("one message reported by both ends draws once", () => {
	// Each end of a session sees every message of it, so a merged feed would
	// double the whole conversation. The core tags each message with a hash of
	// its own wire bytes: one frame crosses one wire, so both ends derive the
	// same tag with nothing to coordinate, and the second sighting folds into
	// the first.
	const convert = makeBaseEventConverter();
	const wire = wireName("e");
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p1/live-h1-s1",
		a: "alice",
		b: "bob",
		session_id: wire,
		codec: "syrup",
	});
	convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p2/live-h1-s1",
		a: "bob",
		b: "alice",
		session_id: wire,
		codec: "syrup",
	});
	const sent = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.message-decoded",
		session: "p1/live-h1-s1",
		outbound: true,
		op: "dm",
		digest: "00112233445566778899aabbccddeeff",
	});
	assertEquals(sent.filter((e) => e.kind === "message-sent").length, 1);
	const echo = convert({
		v: 1,
		sim_t_ns: 2_100_000,
		kind: "ocapn.message-decoded",
		session: "p2/live-h1-s1",
		outbound: false,
		op: "dm",
		digest: "00112233445566778899aabbccddeeff",
	});
	assertEquals(echo.filter((e) => e.kind === "message-sent").length, 0);
});

Deno.test("a peer sending the same bytes twice draws twice", () => {
	// The fold consumes a tag rather than remembering it, so a genuine repeat
	// still draws. Remembering would silently swallow every retransmission of
	// an identical frame for the life of the session.
	const convert = makeBaseEventConverter();
	const wire = wireName("f");
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p1/live-h1-s1",
		a: "alice",
		b: "bob",
		session_id: wire,
		codec: "syrup",
	});
	convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p2/live-h1-s1",
		a: "bob",
		b: "alice",
		session_id: wire,
		codec: "syrup",
	});
	const tag = "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f";
	const drawn = [
		"p1/live-h1-s1",
		"p2/live-h1-s1",
		"p1/live-h1-s1",
		"p2/live-h1-s1",
	]
		.map((session, i) =>
			convert({
				v: 1,
				sim_t_ns: 2_000_000 + i * 1000,
				kind: "ocapn.message-decoded",
				session,
				outbound: session.startsWith("p1"),
				op: "ping",
				digest: tag,
			}).filter((e) => e.kind === "message-sent").length
		);
	assertEquals(drawn, [1, 0, 1, 0]);
});

Deno.test("either endpoint closes the shared wire immediately", () => {
	// A direct message closed from the receiving tab must end the session in
	// the picture. Both ends may report the close, but the first observation is
	// already conclusive and the duplicate must be inert.
	const state = newFeedState();
	const convert = (ev: BaseTimelineEvent) => convertEvent(ev, state);
	const wire = wireName("9");
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p1/live-h1-s1",
		a: "alice",
		b: "bob",
		session_id: wire,
		codec: "syrup",
	});
	convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p2/live-h1-s1",
		a: "bob",
		b: "alice",
		session_id: wire,
		codec: "syrup",
	});
	// The end the first observer did NOT report hangs up first.
	const closed = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.session-closed",
		session: "p2/live-h1-s1",
	});
	assertEquals(closed.filter((e) => e.kind === "session-closed").length, 1);
	assertEquals(
		state.sessionsOfScope.size,
		0,
		"the retired counterpart remained in its producer's session registry",
	);
	const duplicate = convert({
		v: 1,
		sim_t_ns: 2_100_000,
		kind: "ocapn.session-closed",
		session: "p1/live-h1-s1",
	});
	assertEquals(duplicate.length, 0);
});

Deno.test("a replacement wire opens after either endpoint closes the old one", () => {
	const convert = makeBaseEventConverter();
	const oldWire = wireName("9");
	const newWire = wireName("a");
	convert(opened(0, "p1/s1", "alice", "bob", oldWire, true));
	convert(opened(1, "p2/s1", "bob", "alice", oldWire, true));

	const closed = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.session-closed",
		session: "p2/s1",
	});
	assertEquals(closed.filter((e) => e.kind === "session-closed").length, 1);

	const reopened = convert(
		opened(3, "p1/s2", "alice", "bob", newWire, true),
	);
	const replacement = reopened.find((e) => e.kind === "session-opened");
	assert(replacement !== undefined, "the replacement wire was not drawn");
	assertEquals(expectKind(replacement, "session-opened").sessionId, newWire);
	const corroborated = convert(
		opened(4, "p2/s2", "bob", "alice", newWire, true),
	);
	assertEquals(
		corroborated.filter((e) => e.kind === "session-opened").length,
		0,
	);
});
