// Stage ledger: claims, nicks, identity, and replay.

import { assertEquals } from "@std/assert";
import { makeBaseEventConverter } from "../feed.ts";
import { type BaseTimelineEvent } from "../record.ts";
import { closeSession, expectKind, openSession } from "./harness.ts";
import { wireName } from "./fixtures.ts";

Deno.test("an unverified claim is session-scoped, not an identity", () => {
	// Two browser tabs behind a relay both CLAIM `127.0.0.1:0` (a
	// browser peer has no listening address). An unverified name
	// must not merge them onto one stage peer: each session gets its
	// own, and the label disambiguates along with the id, so the two
	// are told apart on screen and not only in the document. A claim
	// is not an identity, so nothing is lost by qualifying it.
	const convert = makeBaseEventConverter();
	const openUnverified = (session: string, t_ns: number) =>
		convert({
			v: 1,
			sim_t_ns: t_ns,
			kind: "ocapn.session-opened",
			session,
			a: "rooms",
			b: "127.0.0.1:0",
			codec: "syrup",
			provenance: "unauthenticated",
		});
	const first = openUnverified("s1", 0);
	const second = openUnverified("s2", 1_000_000);
	// Neither claim draws a peer at all, which is the strongest form of "not
	// an identity": there is nothing for a second session's identical claim to
	// be merged onto, and nothing to dispose of when it turns out to be
	// somebody. The claim rides the end that carries it.
	for (const batch of [first, second]) {
		const opened = expectKind(
			batch.find((e) => e.kind === "session-opened"),
			"session-opened",
		);
		assertEquals(opened.a.peer, "rooms");
		assertEquals(
			opened.b.peer,
			undefined,
			"an unproven claim attaches nobody",
		);
		assertEquals(opened.b.designator, "127.0.0.1:0");
		assertEquals(opened.b.attributedBy, undefined);
	}
	// Only the reporting host is ever drawn, and only once: the first session
	// joins it and the second finds it already there.
	assertEquals(
		first.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
		["rooms"],
	);
	assertEquals(
		second.filter((e) => e.kind === "peer-joined").length,
		0,
		"the second identical claim drew nobody new",
	);
	// Closing one tab's session retires no peer but the room's own row stays:
	// the loose end had nobody to retire.
	const closed = closeSession(convert, "s1", 2_000_000);
	assertEquals(
		closed.filter((e) => e.kind === "peer-left").length,
		0,
		"a loose end leaving takes no peer with it",
	);
});

Deno.test("a room nick is a name for an end, never a name that identifies it", () => {
	// A real Goblins vat joins a glowcap room over plain tcp. The room server is
	// the only producer that can see it, and everything it has about that end is
	// a claim: the vat's designator is an address, so the host's provenance
	// verdict is `unauthenticated`, and the nick the room states is an
	// application annotation about a membership that can change hands.
	//
	// So the end stays loose, and this is the design working rather than a gap
	// in it. Attributing on the address would merge every session that ever
	// claimed it; attributing on the nick would merge whoever wears it next.
	// Nothing here concludes Goblins either, glowcap speaks the v1.0 floor over
	// Syrup as readily as a vat does, so the profile the far side runs is not
	// something this observation can reach.
	const convert = makeBaseEventConverter();
	const open = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		session: "p0/live-h1-s1",
		a: "127.0.0.1:9099",
		a_label: "rooms",
		b: "127.0.0.1:41234",
		transport: "tcp",
		provenance: "unauthenticated",
		session_id: wireName("c"),
		codec: "syrup",
		captp_version: "1.0",
	});
	const opened = expectKind(
		open.find((e) => e.kind === "session-opened"),
		"session-opened",
	);
	assertEquals(
		opened.b.peer,
		undefined,
		"an address nothing proved names nobody",
	);
	assertEquals(opened.b.designator, "127.0.0.1:41234");
	assertEquals(
		open.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
		["127.0.0.1:9099"],
		"only the reporting host is drawn",
	);
	// The room then vouches for the member's nick, and the end is still loose:
	// no peer arrives to wear it, and no profile is concluded from it.
	const named = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.session-meta",
		session: "p0/live-h1-s1",
		meta: { label: "goblins-carol" },
	});
	assertEquals(
		named.filter((e) => e.kind === "peer-joined").length,
		0,
		"a nick draws no peer",
	);
	assertEquals(
		named.filter((e) =>
			e.kind === "peer-updated" &&
			expectKind(e, "peer-updated").profile !== undefined
		).length,
		0,
		"a nick says nothing about what the far side runs",
	);
});

Deno.test("a verified name IS an identity across sessions", () => {
	const convert = makeBaseEventConverter();
	const open = (session: string, t_ns: number) =>
		convert({
			v: 1,
			sim_t_ns: t_ns,
			kind: "ocapn.session-opened",
			session,
			a: "rooms",
			b: "ed25519:bobkey",
			codec: "syrup",
			provenance: "authenticated-transport",
		});
	const first = open("s1", 0);
	const second = open("s2", 1_000_000);
	expectKind(first[1], "peer-joined");
	// Second session: no new peer-joined for bob, same identity.
	assertEquals(second.length, 1);
	const session = expectKind(second[0], "session-opened");
	assertEquals(session.b.peer, "ed25519:bobkey");
});

Deno.test("message payload passes through: whole frame or capped head", () => {
	// The producer owns the cap; this layer neither decodes nor
	// re-bounds. Whole frame: bytes_b64 + len. Capped: summary's
	// head + true length.
	const convert = makeBaseEventConverter();
	openSession(convert, "s1", "bob", 0);
	const whole = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.message-decoded",
		session: "s1",
		outbound: false,
		op: "post",
		bytes_b64: "U3lydXAh",
		len: 6,
	});
	const wholeMsg = expectKind(whole[0], "message-sent");
	assertEquals(wholeMsg.bytesB64, "U3lydXAh");
	assertEquals(wholeMsg.byteLen, 6);
	const capped = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.message-decoded",
		session: "s1",
		outbound: true,
		op: "post",
		summary: { len: 9000, head_b64: "U3lydXAh" },
	});
	const cappedMsg = expectKind(capped[0], "message-sent");
	assertEquals(cappedMsg.bytesB64, "U3lydXAh");
	assertEquals(cappedMsg.byteLen, 9000);
});

Deno.test("replay is state, not events: topology applies, messages stay out", () => {
	// A (re)connecting viewer hears the producer's replay marked
	// `replay: true`. Session opens must materialize (the viewer
	// needs the live topology to route what it sees next); replayed
	// messages happened before this viewer watched, so they must not
	// enter its capture.
	//
	// The batch is one picture, so the topology lands when the endpoint
	// says the batch has ended rather than record by record. That is
	// what lets a wire reported by both its ends be drawn once, already
	// knowing both.
	const convert = makeBaseEventConverter();
	const held = convert({
		v: 1,
		sim_t_ns: 0,
		replay: true,
		kind: "ocapn.session-opened",
		session: "s1",
		a: "rooms",
		b: "bob",
		codec: "syrup",
	});
	assertEquals(
		held.length,
		0,
		"a replayed open waits for the end of its batch",
	);
	const replayedMsg = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		replay: true,
		kind: "ocapn.message-decoded",
		session: "s1",
		outbound: true,
		op: "post",
	});
	assertEquals(replayedMsg.length, 0);
	const opened = convert({
		v: 1,
		sim_t_ns: 1_500_000,
		kind: "trace.replay-end",
	});
	assertEquals(opened.length, 3); // two joins + the open: state applies
	// The replayed message stayed out of the capture even though it rode
	// the same batch.
	assertEquals(opened.filter((e) => e.kind === "message-sent").length, 0);
	// The live tail after the replay flows normally.
	const liveMsg = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.message-decoded",
		session: "s1",
		outbound: true,
		op: "post",
	});
	assertEquals(liveMsg.length, 1);
	expectKind(liveMsg[0], "message-sent");
});

Deno.test("replay completion removes observations absent from the snapshot", () => {
	const convert = makeBaseEventConverter();
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "p0/s1",
		a: "rooms",
		b: "alice",
		codec: "syrup",
	});
	const reconciled = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "trace.replay-end",
	});
	assertEquals(
		reconciled.filter((ev) => ev.kind === "session-unobserved").length,
		1,
	);
});

Deno.test("replay completion retains observations still in the snapshot", () => {
	const convert = makeBaseEventConverter();
	const open: BaseTimelineEvent = {
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "p0/s1",
		a: "rooms",
		b: "alice",
		codec: "syrup",
	};
	convert(open);
	assertEquals(convert({ ...open, replay: true }), []);
	assertEquals(
		convert({
			v: 1,
			sim_t_ns: 2_000_000,
			kind: "trace.replay-end",
		}),
		[],
		"a retained observation was closed and reopened during snapshot replacement",
	);
});

Deno.test("session-meta folds into the partner's label, identity untouched", () => {
	// The annotation pipeline's viewer edge: the producing app states
	// which member a session carries, and the converter turns it into
	// a peer-updated on the session's PARTNER. A claim about naming,
	// never identity (the stage id does not change).
	const convert = makeBaseEventConverter();
	openSession(convert, "s1", "127.0.0.1:0", 0);
	const out = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-meta",
		session: "s1",
		meta: { label: "carol" },
	});
	assertEquals(out.length, 1);
	const updated = expectKind(out[0], "peer-updated");
	assertEquals(updated.peerId, "127.0.0.1:0");
	assertEquals(updated.label, "carol");
	// A session the converter has not seen open: nothing to name yet.
	assertEquals(
		convert({
			v: 1,
			sim_t_ns: 2_000_000,
			kind: "ocapn.session-meta",
			session: "nope",
			meta: { label: "x" },
		}).length,
		0,
	);
});

Deno.test("a name claimed before its session opens lands at the open", () => {
	// A producer replaying its state to a connecting viewer can send
	// the name before the session it names. Dropping it would leave
	// that member under its locator for the rest of the feed.
	const convert = makeBaseEventConverter();
	assertEquals(
		convert({
			v: 1,
			sim_t_ns: 1_000_000,
			kind: "ocapn.session-meta",
			session: "s1",
			meta: { label: "carol" },
		}).length,
		0,
	);
	const opened = openSession(convert, "s1", "127.0.0.1:0", 2_000_000);
	const updated = expectKind(
		opened.find((ev) => ev.kind === "peer-updated"),
		"peer-updated",
	);
	assertEquals(updated.peerId, "127.0.0.1:0");
	assertEquals(updated.label, "carol");
	// At the open's own time: the peer arrives already named.
	assertEquals(updated.t, 2);
});

Deno.test("a claim is spent once, and the newest claim wins", () => {
	const convert = makeBaseEventConverter();
	const claim = (label: string) =>
		convert({
			v: 1,
			sim_t_ns: 1_000_000,
			kind: "ocapn.session-meta",
			session: "s1",
			meta: { label },
		});
	claim("stale");
	claim("carol");
	const opened = openSession(convert, "s1", "127.0.0.1:0", 2_000_000);
	const updates = opened.filter((ev) => ev.kind === "peer-updated");
	assertEquals(updates.length, 1);
	assertEquals(expectKind(updates[0], "peer-updated").label, "carol");

	// The same wire id opening again is a new incarnation, and the
	// spent claim must not name it.
	closeSession(convert, "s1", 3_000_000);
	const reopened = openSession(convert, "s1", "127.0.0.1:0", 4_000_000);
	assertEquals(reopened.filter((ev) => ev.kind === "peer-updated").length, 0);
});

Deno.test("restating the name a peer already answers to is not a rename", () => {
	// The rooms server annotates a session when a member subscribes to
	// a room and again when it registers for direct messages, both
	// with the same nick. One join must paint one diamond, not two
	// saying the same thing.
	const convert = makeBaseEventConverter();
	openSession(convert, "s1", "127.0.0.1:0", 0);
	const claim = (label: string, t_ns: number) =>
		convert({
			v: 1,
			sim_t_ns: t_ns,
			kind: "ocapn.session-meta",
			session: "s1",
			meta: { label },
		});
	assertEquals(claim("carol", 1_000_000).length, 1);
	assertEquals(claim("carol", 2_000_000).length, 0);
	// A different name still renames.
	const renamed = claim("carol-away", 3_000_000);
	assertEquals(renamed.length, 1);
	assertEquals(expectKind(renamed[0], "peer-updated").label, "carol-away");
});

Deno.test("a claim restating a peer's join name is not a rename", () => {
	// The name a peer joined under is the name it answers to, so a
	// producer stating it explicitly changes nothing.
	const convert = makeBaseEventConverter();
	openSession(convert, "s1", "carol", 0);
	assertEquals(
		convert({
			v: 1,
			sim_t_ns: 1_000_000,
			kind: "ocapn.session-meta",
			session: "s1",
			meta: { label: "carol" },
		}).length,
		0,
	);
});

Deno.test("a claim for a session that closed instead of opening is dropped", () => {
	// The close ends that wire id's life. A claim still waiting on it
	// has nothing left to name, and must not name the next session to
	// take the same id.
	const convert = makeBaseEventConverter();
	convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-meta",
		session: "s1",
		meta: { label: "carol" },
	});
	closeSession(convert, "s1", 2_000_000);
	const opened = openSession(convert, "s1", "127.0.0.1:0", 3_000_000);
	assertEquals(opened.filter((ev) => ev.kind === "peer-updated").length, 0);
});
