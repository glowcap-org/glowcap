/**
 * An end's trajectory: attaching from a moment, every attribution a
 * recording can hold, and dragging a session carrying those moments.
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../../engine.ts";
import { sessionEndpointAt, sessionEndpointPlaceAt } from "../../temporal/doc-resolver.ts";
import { attachedTo, backedBy, endpointAttachment, EndpointAttribution } from "../../../schema/session-end.ts";
import { engineTest, looseDoc, observations, sessionOf } from "./harness.ts";

// ── the endpoint properties ───────────────────────────────────────

engineTest("an end attaches to a peer from a moment onward", () => {
	const e = new Engine(looseDoc());
	e.setSessionKeyframe("s1", "b", 3000, "b");
	assertEquals(sessionOf(e).keyframes?.b, [{
		t: 3000,
		value: { peer: "b" },
	}]);
	// The end is loose before the moment and attached from it on, which
	// is the whole point of an attribution being temporal.
	assertEquals(
		sessionEndpointPlaceAt(e.doc, "s1", "b", 2999).peer,
		undefined,
	);
	assertEquals(sessionEndpointPlaceAt(e.doc, "s1", "b", 3000).peer, "b");
});

engineTest("every attribution a recording can hold can be authored", () => {
	// The claim Build mode makes, held mechanically rather than in prose.
	// A recording says what backed an end in two places, at the session's
	// birth and at the moment something backed it, and a live producer status-allow: state at observation
	// reaches only some of the words: `verified-handoff` arrives partway
	// through a session that opened loose, and nothing else can say it.
	// So both places are authored here, for every word the schema admits,
	// and an attribution added to the schema joins this test by being in
	// the enum.
	for (const attribution of EndpointAttribution.options) {
		const born = new Engine(looseDoc());
		born.updateSessionEndpoint("s1", "b", {
			peer: "b",
			attributedBy: attribution,
		});
		assertEquals(
			sessionEndpointPlaceAt(born.doc, "s1", "b", 0).attributedBy,
			attribution,
			`${attribution}: an end could not be born attributed by it`,
		);

		const later = new Engine(looseDoc());
		later.setSessionKeyframe("s1", "b", 3000, {
			peer: "b",
			attributedBy: attribution,
		});
		// The observation is the authority the track is re-derived from, so
		// the word has to be on it and not only on the definition.
		const stated = observations(later).find(
			(ev) => ev.kind === "session-endpoint-attributed",
		);
		assertEquals(
			stated !== undefined && "attributedBy" in stated ? stated.attributedBy : undefined,
			attribution,
			`${attribution}: the moment did not say what backed the attachment`,
		);
		later.seekTo(5000);
		later.seekTo(0);
		assertEquals(
			sessionEndpointPlaceAt(later.doc, "s1", "b", 3000).attributedBy,
			attribution,
			`${attribution}: a moment attributed by it did not survive projection`,
		);
		// And it is this end's own fact from this moment on: before it, the
		// end is loose and nothing backed anything.
		assertEquals(
			sessionEndpointPlaceAt(later.doc, "s1", "b", 2999).attributedBy,
			undefined,
		);
	}
});

engineTest(
	"restating an end's peer keeps what the author said backed it",
	() => {
		// The row edits one control at a time, and the pair is one value, so a
		// peer change must not quietly unsay the attribution beside it. The
		// genesis end has behaved this way since it had an attribution at all
		// (`updateSessionEndpoint` patches field by field), and a moment is the
		// same end at a later time, two answers here would be the same
		// question answered twice.
		const e = new Engine(looseDoc());
		e.setSessionKeyframe("s1", "b", 3000, {
			peer: "b",
			attributedBy: "verified-handoff",
		});
		// What the row's peer control does with the value it is holding.
		const held = sessionEndpointAt(e.doc, "s1", "b", 3000);
		const attachment = endpointAttachment(held);
		assert(attachment !== undefined, "the moment left the end loose");
		e.setSessionKeyframe("s1", "b", 3000, attachedTo(attachment, "a"));
		assertEquals(sessionOf(e).keyframes?.b, [{
			t: 3000,
			value: { peer: "a", attributedBy: "verified-handoff" },
		}]);
		// And the attribution control's converse: clearing it keeps the peer
		// and leaves an attachment nothing backed, which the one-way
		// invariant allows and an author may mean.
		e.setSessionKeyframe(
			"s1",
			"b",
			3000,
			backedBy(
				{ peer: "a", attributedBy: "verified-handoff" },
				undefined,
			),
		);
		assertEquals(sessionOf(e).keyframes?.b, [{
			t: 3000,
			value: { peer: "a" },
		}]);
	},
);

engineTest("an authored attachment survives the projection", () => {
	// The endpoint tracks are DERIVED from the observation stream on
	// every projection run, so an authored track written without its
	// observation would be erased the next time the engine re-projects.
	// The write mints the observation; this is what proves it.
	const e = new Engine(looseDoc());
	e.setSessionKeyframe("s1", "b", 3000, "b");
	const attribution = observations(e).find(
		(ev) => ev.kind === "session-endpoint-attributed",
	);
	assert(attribution !== undefined, "no attribution observation was minted");
	e.seekTo(5000);
	e.seekTo(0);
	assertEquals(sessionOf(e).keyframes?.b, [{
		t: 3000,
		value: { peer: "b" },
	}]);
});

engineTest("removing the moment leaves the end loose again", () => {
	const e = new Engine(looseDoc());
	e.setSessionKeyframe("s1", "b", 3000, "b");
	e.removeSessionKeyframe("s1", "b", 3000);
	assertEquals(sessionOf(e).keyframes?.b, undefined);
	assertEquals(
		sessionEndpointPlaceAt(e.doc, "s1", "b", 5000).peer,
		undefined,
	);
	assertEquals(
		observations(e).filter((ev) => ev.kind === "session-endpoint-attributed")
			.length,
		0,
		"the attribution observation outlived the moment",
	);
});

engineTest("an end cannot attach to a peer the document lacks", () => {
	const e = new Engine(looseDoc());
	e.setSessionKeyframe("s1", "b", 3000, "nobody");
	assertEquals(
		sessionOf(e).keyframes?.b,
		undefined,
		"a moment attached the end to a peer that is not there",
	);
});

engineTest("an attachment cannot land before the session opens", () => {
	const e = new Engine(looseDoc());
	e.setSessionStart("s1", 500);
	e.setSessionKeyframe("s1", "b", 100, "b");
	assertEquals(sessionOf(e).keyframes?.b, undefined);
});

engineTest("dragging a session carries its attributions with it", () => {
	// Every moment on a session's trajectory keeps its spacing from the
	// open. A state change already did; an attribution is a moment on
	// the same row and must too, or a dragged session drops its ends
	// back where they were.
	const e = new Engine(looseDoc());
	e.setSessionKeyframe("s1", "b", 3000, "b");
	e.dispatch({
		kind: "move-entity-span",
		move: {
			kind: "translate",
			ref: { kind: "session", id: "s1" },
			newT: 1000,
		},
	});
	assertEquals(sessionOf(e).keyframes?.b, [{
		t: 4000,
		value: { peer: "b" },
	}]);
});
