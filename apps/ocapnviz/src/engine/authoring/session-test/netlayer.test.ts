/**
 * The netlayer a session's bytes ride. An offer, not a domain: a
 * recording may name one this build has never heard of, and Build
 * still has to keep it, show it, and let an edit away from it undo.
 */

import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../../timeline.ts";
import { Engine } from "../../engine.ts";
import { TRANSPORT_OPTIONS } from "../../../schema/topology.ts";
import { buildDoc, engineTest, sessionOf } from "./harness.ts";

// ── the netlayer the session runs over ────────────────────────────

engineTest("a session can be given the netlayer it runs over", () => {
	// Build's claim is that every shape a recording can hold can be
	// authored, and a recording holds the netlayer each session's bytes
	// ride. A session nobody has said this about carries none, which is
	// the other shape and is equally reachable.
	const e = new Engine(buildDoc());
	assertEquals(sessionOf(e).transport, undefined);
	e.dispatch({
		kind: "update-session",
		sessionId: "s1",
		patch: { transport: "iroh" },
	});
	assertEquals(sessionOf(e).transport, "iroh");
	// And it survives the document: what Build writes is what a saved
	// scenario carries and a reload reads back.
	const reloaded = TimelineDocument.parse(JSON.parse(JSON.stringify(e.doc)));
	assertEquals(reloaded.entities?.sessions?.s1?.transport, "iroh");
});

engineTest("changing the netlayer is one step, and re-picking is none", () => {
	const e = new Engine(buildDoc());
	e.dispatch({
		kind: "update-session",
		sessionId: "s1",
		patch: { transport: "tcp" },
	});
	assertEquals(sessionOf(e).transport, "tcp", "the pick never landed");
	assert(e.canUndo, "the pick pushed no history entry");
	const v0 = e.version;
	e.dispatch({
		kind: "update-session",
		sessionId: "s1",
		patch: { transport: "tcp" },
	});
	assertEquals(
		e.version,
		v0,
		"re-picking the same netlayer still dispatched",
	);
	e.undo();
	assertEquals(
		sessionOf(e).transport,
		undefined,
		"one undo took the whole edit back",
	);
	assert(!e.canUndo, "the repeat dispatch pushed a second history entry");
});

engineTest("saying no netlayer is a write, and saying it twice is not", () => {
	const e = new Engine(buildDoc());
	e.dispatch({
		kind: "update-session",
		sessionId: "s1",
		patch: { transport: "tcp" },
	});
	assertEquals(sessionOf(e).transport, "tcp", "the pick never landed");
	const v1 = e.version;
	e.dispatch({
		kind: "update-session",
		sessionId: "s1",
		patch: { transport: null },
	});
	assert(e.version !== v1, "clearing a stated netlayer changed nothing");
	assert(
		!("transport" in sessionOf(e)),
		"clearing left the field behind holding undefined",
	);
	const v0 = e.version;
	e.dispatch({
		kind: "update-session",
		sessionId: "s1",
		patch: { transport: null },
	});
	assertEquals(
		e.version,
		v0,
		"clearing an unstated netlayer still dispatched",
	);
});

engineTest("a netlayer nobody offers is kept, shown, and editable", () => {
	// `TRANSPORT_OPTIONS` is an offer and not a domain: OCapN is
	// netlayer-plural and CapTP never names a transport, so a recording
	// may arrive over one this build has never heard of. The document
	// keeps it, the panel reads it back to hand to a picker that will
	// add it to what it offers, and an edit away from it is an ordinary
	// edit that undo reverses.
	const doc = TimelineDocument.parse({
		id: "unheard-of",
		duration: 10000,
		events: [
			{
				id: "p1",
				t: 0,
				kind: "peer-joined",
				peerId: "a",
				profile: "pancake",
			},
			{
				id: "p2",
				t: 0,
				kind: "peer-joined",
				peerId: "b",
				profile: "goblins",
			},
			{
				id: "so",
				t: 0,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "a" },
				b: { peer: "b" },
				transport: "carrier-pigeon",
				codec: "syrup",
				captpVersion: "v1_0",
			},
		],
	});
	assert(
		!TRANSPORT_OPTIONS.includes("carrier-pigeon"),
		"the picker turned out to offer this one after all",
	);
	const e = new Engine(doc);
	assertEquals(sessionOf(e).transport, "carrier-pigeon");
	// Re-picking what it already runs over changes nothing, offered or not.
	const v0 = e.version;
	e.dispatch({
		kind: "update-session",
		sessionId: "s1",
		patch: { transport: "carrier-pigeon" },
	});
	assertEquals(e.version, v0);
	e.dispatch({
		kind: "update-session",
		sessionId: "s1",
		patch: { transport: "tcp" },
	});
	assertEquals(sessionOf(e).transport, "tcp");
	e.undo();
	assertEquals(sessionOf(e).transport, "carrier-pigeon");
});
