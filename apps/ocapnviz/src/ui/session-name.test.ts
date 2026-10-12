/**
 * What a session is called, and what one of its ends is called.
 *
 * One rule, read by the Inspector's heading and pickers and by the
 * timeline's pills and row labels, so the assertions here are about the
 * string every one of those surfaces shows.
 */

import { assertEquals } from "@std/assert";
import { Engine } from "../engine/engine.ts";
import { TimelineDocument } from "../engine/timeline.ts";
import { sessionEndName, sessionPairName } from "./session-name.ts";

/** Engine construction runs d3-force, whose timer Deno's sanitizer
 *  flags. Same workaround as the other engine-constructing tests. */
function engineTest(name: string, fn: () => void): void {
	Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

/** Alice and Bob hold one session from t=100. Bob answers to its
 *  locator until t=200 and to "carol" after. */
function pairDoc(): TimelineDocument {
	return TimelineDocument.parse({
		id: "session-name-pair",
		duration: 1000,
		events: [
			{
				id: "e1",
				t: 100,
				kind: "peer-joined",
				peerId: "alice",
				profile: "glowcap",
			},
			{
				id: "e2",
				t: 100,
				kind: "peer-joined",
				peerId: "bob",
				profile: "glowcap",
				label: "127.0.0.1:0",
			},
			{
				id: "e3",
				t: 100,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "alice" },
				b: { peer: "bob" },
				codec: "syrup",
				captpVersion: "v1_0",
				initialState: "negotiating",
			},
			{
				id: "e4",
				t: 200,
				kind: "peer-updated",
				peerId: "bob",
				label: "carol",
			},
		],
	});
}

engineTest(
	"a session is named by the pair it joins, at the moment read",
	() => {
		const engine = new Engine(pairDoc());
		// The name follows the name in force at the moment being read, because
		// a name a reader recognizes is the one they are looking at.
		assertEquals(
			sessionPairName(engine.doc, "s1", 150),
			"alice · 127.0.0.1:0",
		);
		assertEquals(sessionPairName(engine.doc, "s1", 300), "alice · carol");
	},
);

engineTest("an end nobody is on is named by its claim, or says so", () => {
	const engine = new Engine(TimelineDocument.parse({
		id: "session-name-end-names",
		duration: 1000,
		events: [
			{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "host",
				profile: "glowcap",
			},
			{
				id: "e2",
				t: 100,
				kind: "session-opened",
				sessionId: "s-claim",
				a: { peer: "host", attributedBy: "self-reported" },
				b: { designator: "tcp://who:9000" },
				codec: "syrup",
				captpVersion: "v1_0",
			},
			{
				id: "e3",
				t: 100,
				kind: "session-opened",
				sessionId: "s-bare",
				a: { peer: "host", attributedBy: "self-reported" },
				b: {},
				codec: "syrup",
				captpVersion: "v1_0",
			},
		],
	}));
	// A claim is a string the network chose, so it is marked opaque and the
	// pair form shortens it. An end that claims nothing says that in words.
	assertEquals(sessionEndName(engine.doc, "s-claim", "b", 200), {
		text: "tcp://who:9000",
		opaque: true,
	});
	assertEquals(sessionEndName(engine.doc, "s-bare", "b", 200), {
		text: "unnamed end",
		opaque: false,
	});
	assertEquals(
		sessionPairName(engine.doc, "s-claim", 200),
		"host · tcp://who:9000",
	);
	assertEquals(
		sessionPairName(engine.doc, "s-bare", 200),
		"host · unnamed end",
	);
});

engineTest("a peer wearing its own id is shortened like any other key", () => {
	// What a live recording produces: `StageLedger` keys a peer by the name
	// it answers to on the wire, so an unnamed peer's id IS its designator,
	// and for a keyed netlayer that is sixty-four characters. Nothing in an
	// authored fixture has this shape, which is why it is asserted here.
	const key = "3c".repeat(32);
	const engine = new Engine(TimelineDocument.parse({
		id: "session-name-keyed-peer",
		duration: 1000,
		events: [
			{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: key,
				profile: "glowcap",
			},
			{
				id: "e2",
				t: 100,
				kind: "session-opened",
				sessionId: "s-keyed",
				a: { peer: key, attributedBy: "self-reported" },
				b: {},
				codec: "syrup",
				captpVersion: "v1_0",
			},
		],
	}));
	// The end holds a string the network chose, so it says so, and the pair
	// form cuts it in the middle rather than carrying it into a sentence
	// whole.
	assertEquals(sessionEndName(engine.doc, "s-keyed", "a", 200), {
		text: key,
		opaque: true,
	});
	assertEquals(
		sessionPairName(engine.doc, "s-keyed", 200),
		"3c3c3c3c…3c3c3c3c · unnamed end",
	);
});
