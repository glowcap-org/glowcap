// Stage ledger: negotiated codec, CapTP profile, and producer departure.

import { assert, assertEquals } from "@std/assert";
import { makeBaseEventConverter } from "../feed.ts";
import { CAPTP_VERSION_WIRE } from "../../../schema/topology.ts";
import { expectKind } from "./harness.ts";

Deno.test("the negotiated CapTP profile comes from the producer, not a guess", () => {
	// The tap reports the codec and not the version, so the viewer must not
	// stamp v1_0 on every session, or a glowcap-to-glowcap session drawn as
	// capnp would read as CapTP 1.0.
	const convert = makeBaseEventConverter();
	const nextOut = convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		session: "s1",
		a: "rooms",
		b: "bob",
		codec: "capnp",
		captp_version: CAPTP_VERSION_WIRE.next,
	});
	assertEquals(expectKind(nextOut[2], "session-opened").captpVersion, "next");
	// The floor profile reads back as v1_0.
	const floorOut = makeBaseEventConverter()({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "s2",
		a: "rooms",
		b: "carol",
		codec: "syrup",
	});
	assertEquals(
		expectKind(floorOut[2], "session-opened").captpVersion,
		"v1_0",
	);

	const unknownOut = makeBaseEventConverter()({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		session: "s3",
		a: "rooms",
		b: "dave",
		codec: "syrup",
		captp_version: "future-profile",
	});
	assertEquals(
		expectKind(unknownOut[2], "session-opened").captpVersion,
		"unknown",
	);

	const nonStringOut = makeBaseEventConverter()({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		session: "s4",
		a: "rooms",
		b: "erin",
		codec: "syrup",
		captp_version: 1,
	});
	assertEquals(
		expectKind(nonStringOut[2], "session-opened").captpVersion,
		"unknown",
	);
});

Deno.test("an unknown negotiated codec stays unknown", () => {
	const convert = makeBaseEventConverter();
	const out = convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "s1",
		a: "rooms",
		b: "bob",
		codec: "unknown",
	});
	assertEquals(expectKind(out[2], "session-opened").codec, "unknown");
});

Deno.test("a future negotiated codec keeps its wire word", () => {
	const convert = makeBaseEventConverter();
	const out = convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "s1",
		a: "rooms",
		b: "bob",
		codec: "postcard",
	});
	assertEquals(expectKind(out[2], "session-opened").codec, "postcard");
});

Deno.test("an absent, empty, or non-string codec is unknown", () => {
	const convert = makeBaseEventConverter();
	const absentOut = convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "s1",
		a: "rooms",
		b: "bob",
	});
	assertEquals(expectKind(absentOut[2], "session-opened").codec, "unknown");

	const emptyOut = makeBaseEventConverter()({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "s2",
		a: "rooms",
		b: "bob",
		codec: "",
	});
	assertEquals(expectKind(emptyOut[2], "session-opened").codec, "unknown");

	const numericOut = makeBaseEventConverter()({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "s3",
		a: "rooms",
		b: "bob",
		codec: 1,
	});
	assertEquals(expectKind(numericOut[2], "session-opened").codec, "unknown");
});

Deno.test("a departed producer's own node leaves with the last session to it", () => {
	// The reported bug: refresh a tab and its node stayed on stage forever.
	//
	// A reporting host outlives its sessions, a room server is
	// there whether or not anyone is connected, and that was right while the
	// room server was the only producer. A browser tab is a producer too, and
	// its life ends when it reloads, so the endpoint says which producer left
	// and the host it spoke for stops being one. What takes it off stage is
	// the last session touching it going, and the converter ends this
	// producer's sessions itself when it hears the departure.
	//
	// The row ends UNOBSERVED: a publishing socket closed, which is all
	// anyone here saw. A tab that merely turned tracing off looks the same.
	const convert = makeBaseEventConverter();
	const opened = convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p2/live-h1-s1",
		a: "tab-designator",
		b: "rooms",
		codec: "syrup",
	});
	assert(opened.some((e) => e.kind === "peer-joined"));

	convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-closed",
		session: "p2/live-h1-s1",
	});
	const left = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "trace.producer-left",
		scope: "p2",
	});
	const gone = left.filter((e) => e.kind === "peer-unobserved");
	assertEquals(gone.length, 1);
	assertEquals(
		expectKind(gone[0], "peer-unobserved").peerId,
		"tab-designator",
	);
	assertEquals(
		left.filter((e) => e.kind === "peer-left").length,
		0,
		"a publishing socket closing is not a departure anyone observed",
	);
});

Deno.test("a producer leaving does not retire another producer's host", () => {
	// The hazard in the fix: the ledger already had a whole-topology
	// retirement for a restarted process, and reaching for that here would
	// have wiped every other producer's peers off the stage.
	const convert = makeBaseEventConverter();
	convert({
		v: 1,
		sim_t_ns: 0,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p1/live-h1-s1",
		a: "rooms",
		b: "someone",
		codec: "syrup",
	});
	convert({
		v: 1,
		sim_t_ns: 1_000_000,
		kind: "ocapn.session-opened",
		transport: "tcp",
		captp_version: "1.0",
		session: "p2/live-h1-s1",
		a: "tab-designator",
		b: "rooms",
		codec: "syrup",
	});
	convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.session-closed",
		session: "p2/live-h1-s1",
	});
	const left = convert({
		v: 1,
		sim_t_ns: 3_000_000,
		kind: "trace.producer-left",
		scope: "p2",
	});
	const gone = left.filter((e) => e.kind === "peer-unobserved").map((e) => expectKind(e, "peer-unobserved").peerId);
	assertEquals(gone, ["tab-designator"]);
});

Deno.test("an explicit close retires a shared wire before producer departure", () => {
	// Both producers observe one transport. A protocol close from either end
	// proves that shared wire ended; it is not observer loss and must not wait
	// for the second endpoint's duplicate close.
	const convert = makeBaseEventConverter();
	const wire = "d".repeat(64);
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
		a: "tab-designator",
		b: "rooms",
		session_id: wire,
		codec: "syrup",
	});
	const closed = convert({
		v: 1,
		sim_t_ns: 2_000_000,
		kind: "ocapn.session-closed",
		session: "p2/live-h1-s1",
	});
	assertEquals(closed.filter((e) => e.kind === "session-closed").length, 1);
	const left = convert({
		v: 1,
		sim_t_ns: 3_000_000,
		kind: "trace.producer-left",
		scope: "p2",
	});
	assertEquals(left.filter((e) => e.kind === "peer-left").length, 0);
	assertEquals(left.filter((e) => e.kind === "session-closed").length, 0);
	assertEquals(left.filter((e) => e.kind === "peer-unobserved").length, 1);
	const duplicate = convert({
		v: 1,
		sim_t_ns: 4_000_000,
		kind: "ocapn.session-closed",
		session: "p1/live-h1-s1",
	});
	assertEquals(duplicate.length, 0);
});
