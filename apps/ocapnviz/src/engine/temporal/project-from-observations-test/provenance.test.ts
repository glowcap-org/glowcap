/**
 * Derived spans re-derive when observations grow. Authored spans
 * keep the times a person wrote. Quiet re-projection keeps the
 * document's object identity so layout does not rebind.
 */

import { assertEquals } from "@std/assert";
import { attachedEndpoint } from "../../../schema/session-end.ts";
import { projectFromObservations } from "../project-from-observations.ts";
import { emptyDoc, withEvents } from "./harness.ts";

// ── Timing provenance: derived spans re-derive, authored spans win ──

Deno.test("live: a late-arriving peer-left re-derives the derived span", () => {
	// Live-mode shape: the join projects first (open-ended span), the
	// leave arrives on a LATER run. The derived span must pick it up,
	// this is the projection defect that made live peers immortal.
	const base = withEvents({
		...emptyDoc(),
		entities: { peers: { alice: { profile: "glowcap" } } },
	}, [
		{
			id: "e1",
			kind: "peer-joined",
			t: 5,
			peerId: "alice",
			profile: "glowcap",
		},
	]);
	const once = projectFromObservations(base);
	assertEquals(once.entities?.peers?.alice?.timing, {
		start: { value: 5, explicit: true },
		duration: { value: 0, explicit: false },
		derived: true,
	});
	// The live appender pushes into the same observations array.
	once.recording?.sources[0]?.observations.push(
		{ id: "e2", kind: "peer-left", t: 30, peerId: "alice" },
	);
	const twice = projectFromObservations(once);
	assertEquals(twice.entities?.peers?.alice?.timing, {
		start: { value: 5, explicit: true },
		duration: { value: 25, explicit: true },
		derived: true,
	});
});

Deno.test("live: a late-arriving session-closed re-derives the derived span", () => {
	const base = withEvents({
		...emptyDoc(),
		entities: {
			sessions: {
				s1: {
					a: attachedEndpoint("alice"),
					b: attachedEndpoint("bob"),
					codec: "capnp",
					captpVersion: "v1_0",
				},
			},
		},
	}, [
		{
			id: "e1",
			kind: "session-opened",
			t: 2,
			sessionId: "s1",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			codec: "capnp",
			captpVersion: "v1_0",
		},
	]);
	const once = projectFromObservations(base);
	once.recording?.sources[0]?.observations.push(
		{ id: "e2", kind: "session-closed", t: 20, sessionId: "s1" },
	);
	const twice = projectFromObservations(once);
	assertEquals(twice.entities?.sessions?.s1?.timing, {
		start: { value: 2, explicit: true },
		duration: { value: 18, explicit: true },
		derived: true,
	});
});

Deno.test("authored timing outranks observation growth", () => {
	// A user-authored span (no derived marker) is never touched, even
	// when a closure observation arrives for the same entity.
	const doc = withEvents({
		...emptyDoc(),
		entities: {
			peers: {
				alice: {
					profile: "glowcap",
					timing: {
						start: { value: 99, explicit: true },
						duration: { value: 11, explicit: true },
					},
				},
			},
		},
	}, [
		{
			id: "e1",
			kind: "peer-joined",
			t: 5,
			peerId: "alice",
			profile: "glowcap",
		},
		{ id: "e2", kind: "peer-left", t: 30, peerId: "alice" },
	]);
	const out = projectFromObservations(doc);
	assertEquals(out.entities?.peers?.alice?.timing, {
		start: { value: 99, explicit: true },
		duration: { value: 11, explicit: true },
	});
});

Deno.test("quiet re-projection keeps doc object identity", () => {
	// The engine keys layout rebinds on doc identity; a run over an
	// unchanged observation set must return the SAME object even
	// though derived spans are re-derived each run.
	const doc = withEvents({
		...emptyDoc(),
		entities: { peers: { alice: { profile: "glowcap" } } },
	}, [
		{
			id: "e1",
			kind: "peer-joined",
			t: 5,
			peerId: "alice",
			profile: "glowcap",
		},
		{ id: "e2", kind: "peer-left", t: 30, peerId: "alice" },
	]);
	const once = projectFromObservations(doc);
	const twice = projectFromObservations(once);
	if (twice !== once) {
		throw new Error("expected identical doc object on quiet re-projection");
	}
});

Deno.test("live sentinel: arrivalT === t takes the default flight", () => {
	// The live converter has no departure timestamp, so it stamps
	// arrivalT equal to t ("flight unobserved"). A zero flight is
	// invisible; the projection must substitute the default so the
	// message actually draws.
	const doc = withEvents({
		...emptyDoc(),
		entities: {
			messages: { m1: { sessionId: "s1", from: "alice", to: "bob" } },
		},
	}, [{
		id: "e1",
		kind: "message-sent",
		t: 10,
		messageId: "m1",
		sessionId: "s1",
		from: "alice",
		to: "bob",
		arrivalT: 10,
	}]);
	const out = projectFromObservations(doc);
	assertEquals(out.entities?.messages?.m1?.timing, {
		start: { value: 10, explicit: true },
		duration: { value: 500, explicit: true },
		derived: true,
	});
});

Deno.test("a message observation's payload stays off the synthesized def", () => {
	// The def carries identity; the frame is the observation itself,
	// and copying it would double every payload's retention in a
	// live doc. The Inspector reads the observation.
	const doc = withEvents(emptyDoc(), [{
		id: "e1",
		kind: "message-sent",
		t: 10,
		messageId: "m1",
		sessionId: "s1",
		from: "alice",
		to: "bob",
		arrivalT: 10,
		bytesB64: "U3lydXAh",
		byteLen: 6,
	}]);
	const out = projectFromObservations(doc);
	const def = out.entities?.messages?.m1 as Record<string, unknown>;
	assertEquals(def.bytesB64, undefined);
	assertEquals(def.byteLen, undefined);
});
