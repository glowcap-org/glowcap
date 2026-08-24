// The converter: one host record becomes the timeline events the stage draws.

import { assert, assertEquals } from "@std/assert";
import { makeBaseEventConverter } from "../feed.ts";
import { type BaseTimelineEvent } from "../record.ts";
import { expectKind } from "./harness.ts";

Deno.test("ocapn.session-opened synthesizes peer-joined for both peers", () => {
	const convert = makeBaseEventConverter();
	const ev: BaseTimelineEvent = {
		v: 1,
		sim_t_ns: 5_000_000,
		kind: "ocapn.session-opened",
		session: "alice--bob",
		a: "alice",
		b: "bob",
		codec: "syrup",
	};
	const out = convert(ev);
	assertEquals(out.length, 3);
	expectKind(out[0], "peer-joined");
	expectKind(out[1], "peer-joined");
	const session = expectKind(out[2], "session-opened");
	assertEquals(session.sessionId, "alice--bob");
	assertEquals(session.a.peer, "alice");
	assertEquals(session.b.peer, "bob");
	assertEquals(session.codec, "syrup");
});

Deno.test("peer-joined fires exactly once per peer across multiple events", () => {
	const convert = makeBaseEventConverter();
	const session = convert({
		v: 1,
		sim_t_ns: 5_000_000,
		kind: "ocapn.session-opened",
		session: "alice--bob",
		a: "alice",
		b: "bob",
		codec: "syrup",
	});
	const message = convert({
		v: 1,
		sim_t_ns: 6_000_000,
		kind: "ocapn.message-decoded",
		session: "alice--bob",
		src: "alice",
		dst: "bob",
		op: "op:deliver",
		len: 50,
	});
	assertEquals(session.length, 3);
	assertEquals(message.length, 1);
	expectKind(message[0], "message-sent");
});

Deno.test("ocapn.message-decoded yields message-sent with op label", () => {
	const convert = makeBaseEventConverter();
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "alice--bob",
		a: "alice",
		b: "bob",
		codec: "syrup",
	});
	const out = convert({
		v: 1,
		sim_t_ns: 10_000_000,
		kind: "ocapn.message-decoded",
		session: "alice--bob",
		src: "alice",
		dst: "bob",
		op: "op:start-session",
		len: 275,
	});
	assertEquals(out.length, 1);
	const msg = expectKind(out[0], "message-sent");
	assertEquals(msg.from, "alice");
	assertEquals(msg.to, "bob");
	assertEquals(msg.label, "op:start-session");
});

Deno.test("ocapn.message-decoded with depart_ns anchors message at depart, arrival at sim_t", () => {
	const convert = makeBaseEventConverter();
	const out = convert({
		v: 1,
		sim_t_ns: 217_000_000,
		kind: "ocapn.message-decoded",
		session: "eu-bob--us-alice",
		src: "us-alice",
		dst: "eu-bob",
		op: "op:start-session",
		len: 275,
		depart_ns: 136_000_000,
	});
	// Two synthesized peer-joined + one message-sent.
	assertEquals(out.length, 3);
	const msg = expectKind(out[2], "message-sent");
	assertEquals(msg.t, 136); // depart at 136ms
	assertEquals(msg.arrivalT, 217); // arrive at 217ms (real flight ≈ 81ms)
	assertEquals(msg.from, "us-alice");
	assertEquals(msg.to, "eu-bob");
});

Deno.test("ocapn.message-decoded without depart_ns stamps the unobserved-flight sentinel", () => {
	// A live host tap observes only arrival. `arrivalT === t` is the
	// "flight unobserved" sentinel: the projection reads a zero
	// flight as absent and substitutes its visible default, so the
	// message flies instead of flashing for a sub-frame instant.
	const convert = makeBaseEventConverter();
	const out = convert({
		v: 1,
		sim_t_ns: 5_000_000,
		kind: "ocapn.message-decoded",
		session: "alice--bob",
		src: "alice",
		dst: "bob",
		op: "op:deliver",
		len: 50,
	});
	assertEquals(out.length, 3);
	const msg = expectKind(out[2], "message-sent");
	assertEquals(msg.t, 5);
	assertEquals(msg.arrivalT, 5);
});

Deno.test("converter generates monotonic unique ids", () => {
	const convert = makeBaseEventConverter();
	const base: BaseTimelineEvent = {
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "s",
		a: "a",
		b: "b",
		codec: "syrup",
	};
	const a = convert({ ...base, session: "s1", a: "a1", b: "b1" });
	const b = convert({ ...base, session: "s2", a: "a2", b: "b2" });
	const c = convert({ ...base, session: "s3", a: "a3", b: "b3" });
	const aFirst = a[0];
	const bFirst = b[0];
	const cFirst = c[0];
	assert(aFirst && bFirst && cFirst, "each conversion produced an event");
	assert(aFirst.id !== bFirst.id);
	assert(bFirst.id !== cFirst.id);
	assert(aFirst.id !== cFirst.id);
});

Deno.test("a kind this viewer does not read yields nothing", () => {
	// The feed reads the `ocapn.*` and `trace.*` families and ignores
	// everything else rather than guessing at it. A producer is free to
	// put its own records on the same stream, and a viewer that threw or
	// drew something on one would make that impossible.
	const convert = makeBaseEventConverter();
	const cases = [
		{ kind: "UnknownKind" },
		{ kind: "some.other.family" },
		{ kind: "ocapn.a-kind-from-a-later-schema" },
		{ kind: "" },
		{ kind: 42 },
	];
	for (const c of cases) {
		const ev: BaseTimelineEvent = { v: 1, sim_t_ns: 0, ...c };
		assertEquals(convert(ev).length, 0, `expected [] for kind=${c.kind}`);
	}
});

Deno.test("a non-number timestamp yields nothing", () => {
	const convert = makeBaseEventConverter();
	const out = convert({
		v: 1,
		sim_t_ns: "0",
		kind: "ocapn.session-opened",
		session: "alice--bob",
		a: "alice",
		b: "bob",
		codec: "syrup",
	});
	assertEquals(out, []);
});

Deno.test("live-feed: a host tap's outbound flag resolves src/dst from session-opened", () => {
	// The live producer names only its session and direction; the converter
	// owns endpoint labeling from the session-opened it already saw, so every
	// producer veneer can stay a stamp-and-forward.
	const convert = makeBaseEventConverter();
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		session: "live-s7",
		a: "rooms",
		b: "alice",
		codec: "syrup",
	});
	const outbound = convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.message-decoded",
		session: "live-s7",
		outbound: true,
		op: "notify",
	});
	const sent = outbound.find((ev) => ev.kind === "message-sent");
	assertEquals(sent?.kind === "message-sent" ? sent.from : null, "rooms");
	assertEquals(sent?.kind === "message-sent" ? sent.to : null, "alice");
	const inbound = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.message-decoded",
		session: "live-s7",
		outbound: false,
		op: "post",
	});
	const got = inbound.find((ev) => ev.kind === "message-sent");
	assertEquals(got?.kind === "message-sent" ? got.from : null, "alice");
	assertEquals(got?.kind === "message-sent" ? got.to : null, "rooms");
	const closed = convert({
		v: 1,
		sim_t_ns: 3_000_000,
		kind: "ocapn.session-closed",
		session: "live-s7",
	});
	// The session's own close lands on stage, then the far end leaves.
	const closeEv = closed.find((ev) => ev.kind === "session-closed");
	assertEquals(
		closeEv?.kind === "session-closed" ? closeEv.sessionId : null,
		"live-s7",
	);
	const left = closed.find((ev) => ev.kind === "peer-left");
	assertEquals(left?.kind === "peer-left" ? left.peerId : null, "alice");
});
