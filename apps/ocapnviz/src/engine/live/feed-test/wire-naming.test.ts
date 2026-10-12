// Two ends of one wire: a claim, a name, and an end that attaches later.

import { assertEquals } from "@std/assert";
import { makeBaseEventConverter } from "../feed.ts";
import { sessionEndpoint } from "../../../schema/session-end.ts";
import { expectKind } from "./harness.ts";
import { wireName } from "./fixtures.ts";

Deno.test("withdrawing a claim reveals the name underneath", () => {
	// A member leaving a room keeps its connection to the room server, so the
	// session stays; what changed is that the room no longer knows the
	// connection by a nickname. Withdrawing the claim has to show that, and
	// freezing the last nick anyone said would not.
	//
	// The name underneath is the peer's own designator, so the end has to be
	// attached to a peer for there to be anything under the nick at all: the
	// room accepts a dialer it cannot name, the dialer's own producer speaks for
	// that end, and only then is there a peer for a nickname to sit on top of.
	const convert = makeBaseEventConverter();
	const wire = wireName("7");
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "p1/live-h1-s1",
		a: "rooms",
		b: "127.0.0.1:0",
		provenance: "unauthenticated",
		session_id: wire,
		codec: "syrup",
	});
	convert({
		v: 1,
		sim_t_ns: 500_000,
		kind: "ocapn.session-opened",
		session: "p2/live-h1-s1",
		a: "tab-key",
		b: "rooms",
		provenance: "authenticated-transport",
		session_id: wire,
		codec: "syrup",
	});
	const named = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-meta",
		session: "p1/live-h1-s1",
		meta: { label: "nick2" },
	});
	const renamed = expectKind(
		named.find((e) => e.kind === "peer-updated" && e.label !== undefined),
		"peer-updated",
	);
	assertEquals(renamed.peerId, "tab-key");
	assertEquals(renamed.label, "nick2");
	const withdrawn = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.session-meta",
		session: "p1/live-h1-s1",
		meta: { label: null },
	});
	assertEquals(withdrawn.length, 1);
	// The designator it joined under, not the nick it last answered to.
	assertEquals(expectKind(withdrawn[0], "peer-updated").label, "tab-key");
});

Deno.test("a wire drawn before its far end could be named learns who is on it", () => {
	// The order that has no order-free answer. A member's own end of a direct
	// session opens FIRST on the accepting side, which cannot name the dialer:
	// a browser tab presents no address it can prove. So the picture draws that
	// end loose, and then the dialer reports the same wire, says who it is, and
	// it is a peer already on stage from its room session. There is nothing
	// derivable from the first observation that would have avoided this, so the
	// picture has to be able to learn.
	//
	// What it must NOT do is report the learning as something the network did.
	// One session opened and stayed open; nobody departed. So the session keeps
	// its identity, the wire name both ends derived, and its end moves onto
	// the peer that spoke for it. Nothing is superseded, because nothing was
	// ever drawn in that peer's place.
	const convert = makeBaseEventConverter();
	const roomWire = wireName("1");
	const dmWire = wireName("2");
	// Both members are on stage from their room sessions.
	for (
		const [scope, self] of [["p1", "alice-key"], ["p2", "bob-key"]] as const
	) {
		convert({
			v: 1,
			sim_t_ns: 0,
			kind: "ocapn.session-opened",
			session: `${scope}/live-h1-s1`,
			a: self,
			b: "rooms",
			session_id: scope === "p1" ? roomWire : wireName("3"),
			codec: "syrup",
		});
	}
	// Bob accepts a direct session and cannot name who dialed.
	const accepted = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		session: "p2/live-h1-s2",
		a: "bob-key",
		b: "127.0.0.1:0",
		provenance: "unauthenticated",
		session_id: dmWire,
		codec: "syrup",
	});
	assertEquals(
		accepted.filter((e) => e.kind === "peer-joined").length,
		0,
		"an end nobody could name drew nobody, and bob was already on stage",
	);
	const first = expectKind(
		accepted.find((e) => e.kind === "session-opened"),
		"session-opened",
	);
	// The claim rides the end that carries it, attached to no peer.
	assertEquals(first.b.peer, undefined);
	assertEquals(first.b.designator, "127.0.0.1:0");
	assertEquals(first.b.attributedBy, undefined);
	// Alice reports the same wire, and it is her.
	const dialed = convert({
		v: 1,
		sim_t_ns: 1_100_000,
		kind: "ocapn.session-opened",
		session: "p1/live-h1-s2",
		a: "alice-key",
		b: "bob-key",
		provenance: "authenticated-transport",
		session_id: dmWire,
		codec: "syrup",
	});
	// Nothing the network did: no close, no departure, no second edge, and no
	// new peer, because both ends were already there.
	for (const invented of ["session-closed", "peer-left", "session-opened"]) {
		assertEquals(
			dialed.filter((e) => e.kind === invented).length,
			0,
			`learning who dialed is not a ${invented}`,
		);
	}
	assertEquals(dialed.filter((e) => e.kind === "peer-joined").length, 0);
	// What it IS: the accepting end reported itself as `a`, so the end that
	// could not be named is `b`, and it is alice.
	const moved = expectKind(
		dialed.find((e) => e.kind === "session-endpoint-attributed"),
		"session-endpoint-attributed",
	);
	assertEquals(moved.sessionId, first.sessionId);
	assertEquals(moved.side, "b");
	assertEquals(moved.peerId, "alice-key");
});

Deno.test("the same direct session in the other order needs no redraw", () => {
	// The dialer reporting first names both ends outright, so nothing is drawn
	// that has to be taken back. Both orders end at the same picture.
	const convert = makeBaseEventConverter();
	const dmWire = wireName("4");
	for (
		const [scope, self] of [["p1", "alice-key"], ["p2", "bob-key"]] as const
	) {
		convert({
			v: 1,
			sim_t_ns: 0,
			kind: "ocapn.session-opened",
			session: `${scope}/live-h1-s1`,
			a: self,
			b: "rooms",
			session_id: wireName(scope === "p1" ? "5" : "6"),
			codec: "syrup",
		});
	}
	const dialed = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		session: "p1/live-h1-s2",
		a: "alice-key",
		b: "bob-key",
		provenance: "authenticated-transport",
		session_id: dmWire,
		codec: "syrup",
	});
	assertEquals(dialed.filter((e) => e.kind === "peer-joined").length, 0);
	const opened = expectKind(
		dialed.find((e) => e.kind === "session-opened"),
		"session-opened",
	);
	assertEquals([opened.a.peer, opened.b.peer].sort(), [
		"alice-key",
		"bob-key",
	]);
	const accepted = convert({
		v: 1,
		sim_t_ns: 1_100_000,
		kind: "ocapn.session-opened",
		session: "p2/live-h1-s2",
		a: "bob-key",
		b: "127.0.0.1:0",
		provenance: "unauthenticated",
		session_id: dmWire,
		codec: "syrup",
	});
	assertEquals(accepted.length, 0);
});

Deno.test("a name claimed before an end attaches comes with it", () => {
	// The accepting end annotates the connection with the nick it knows the
	// dialer by, and it does so while that end is still loose. There is no peer
	// yet for the nick to sit on. The claim is about whoever turns out to be
	// there, so it waits on the end and transfers when the end attaches.
	// Dropping it would leave the conversation nameless for no reason.
	const convert = makeBaseEventConverter();
	const dmWire = wireName("8");
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "p1/live-h1-s1",
		a: "alice-key",
		b: "rooms",
		session_id: wireName("a"),
		codec: "syrup",
	});
	convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		session: "p2/live-h1-s2",
		a: "bob-key",
		b: "127.0.0.1:0",
		provenance: "unauthenticated",
		session_id: dmWire,
		codec: "syrup",
	});
	const claimed = convert({
		v: 1,
		sim_t_ns: 1_500_000,
		kind: "ocapn.session-meta",
		session: "p2/live-h1-s2",
		meta: { label: "alice" },
	});
	assertEquals(
		claimed.length,
		0,
		"a nick for an end with no peer on it renames nobody yet",
	);
	const dialed = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.session-opened",
		session: "p1/live-h1-s2",
		a: "alice-key",
		b: "bob-key",
		provenance: "authenticated-transport",
		session_id: dmWire,
		codec: "syrup",
	});
	// The end attaches to alice, and the nick the accepting end had been holding
	// for it is what she answers to.
	const attached = expectKind(
		dialed.find((e) => e.kind === "session-endpoint-attributed"),
		"session-endpoint-attributed",
	);
	assertEquals(attached.peerId, "alice-key");
	const renamed = dialed.filter((e) => e.kind === "peer-updated" && e.label !== undefined).map((e) =>
		expectKind(e, "peer-updated")
	);
	assertEquals(renamed.map((e) => e.label), ["alice"]);
	assertEquals(renamed[0]?.peerId, "alice-key");
});

Deno.test("an end nobody could name attaches when its own producer speaks", () => {
	// What the stage needs to draw the difference between "someone is on the
	// other end of this wire" and "this is nick2". The accepting end cannot name
	// the dialer, so that end stays loose and carries its claim; when the
	// dialer's own producer reports the wire, the end attaches to it. The moment
	// lands on the SESSION's end, not on a peer, because no peer was invented to
	// have a moment.
	const convert = makeBaseEventConverter();
	const dmWire = wireName("b");
	const accepted = convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "p2/live-h1-s1",
		a: "bob-key",
		b: "127.0.0.1:0",
		provenance: "unauthenticated",
		session_id: dmWire,
		codec: "syrup",
	});
	// Only the reporting host is drawn: it speaks for itself, and nothing
	// speaks for the end it accepted.
	assertEquals(
		accepted.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
		["bob-key"],
	);
	const opened = expectKind(
		accepted.find((e) => e.kind === "session-opened"),
		"session-opened",
	);
	assertEquals(
		opened.a,
		sessionEndpoint({
			peer: "bob-key",
			designator: "bob-key",
			attributedBy: "self-reported",
		}),
	);
	assertEquals(opened.b, sessionEndpoint({ designator: "127.0.0.1:0" }));

	// The dialer reports the same wire, so the loose end is hers. She is drawn
	// here for the first time, under her own designator, never under the claim
	// the accepting end could not back.
	const dialed = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		session: "p1/live-h1-s1",
		a: "alice-key",
		b: "bob-key",
		provenance: "authenticated-transport",
		session_id: dmWire,
		codec: "syrup",
	});
	assertEquals(
		dialed.filter((e) => e.kind === "peer-joined").map((e) => expectKind(e, "peer-joined").peerId),
		["alice-key"],
	);
	const attached = dialed.filter((e) => e.kind === "session-endpoint-attributed").map((e) =>
		expectKind(e, "session-endpoint-attributed")
	);
	assertEquals(attached.length, 1);
	assertEquals(attached[0]?.sessionId, opened.sessionId);
	assertEquals(attached[0]?.side, "b");
	assertEquals(attached[0]?.peerId, "alice-key");

	// Restating it is not a second moment: the end is already attached.
	const again = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.session-opened",
		session: "p1/live-h1-s2",
		a: "alice-key",
		b: "bob-key",
		provenance: "authenticated-transport",
		session_id: dmWire,
		codec: "syrup",
	});
	assertEquals(
		again.filter((e) => e.kind === "session-endpoint-attributed").length,
		0,
	);
});
