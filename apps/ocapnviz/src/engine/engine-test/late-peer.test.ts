import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { Engine } from "../engine.ts";
import { findPeer } from "../world.ts";
import { engineTest } from "./harness.ts";

// ───────────── Guard authority + snapshot-coverage regressions ─────────────
//
// Every test in this section was written red against a confirmed
// defect before its fix landed: a no-op guard consulting the live
// world (or a stored bound the resolvers ignore) where the authored
// doc, the state the mutation writes, is the fact; the
// undo snapshot missing `doc.duration`; and the layout system
// holding the pre-projection doc object.

/** Doc whose only peer joins mid-timeline, at t=0 (where every
 *  dispatch in these tests happens) the peer exists in the authored
 *  doc but not in the materialized world. */
const latePeerDoc = () =>
	TimelineDocument.parse({
		id: "late-peer",
		duration: 60_000,
		events: [
			{
				id: "j1",
				t: 5_000,
				kind: "peer-joined",
				peerId: "late",
				profile: "glowcap",
			},
		],
	});

engineTest("update-peer reaches a peer outside the playhead window", () => {
	const e = new Engine(latePeerDoc());
	assertEquals(findPeer(e.world, "late"), undefined, "not in world at t=0");
	e.dispatch({
		kind: "update-peer",
		peerId: "late",
		patch: { label: "Renamed" },
	});
	assertEquals(
		e.doc.entities?.peers?.["late"]?.label,
		"Renamed",
		"the authored definition is editable regardless of the playhead",
	);
	assert(e.canUndo, "a real edit records history");
});

engineTest("reposition-peer pins a peer outside the playhead window", () => {
	const e = new Engine(latePeerDoc());
	e.dispatch({
		kind: "reposition-peer",
		peerId: "late",
		position: { x: 10, y: 20 },
	});
	assertEquals(
		e.doc.entities?.peers?.["late"]?.position,
		{ x: 10, y: 20 },
		"the pin lands on the definition regardless of the playhead",
	);
});

engineTest(
	"update-session reaches a session outside the playhead window",
	() => {
		const e = new Engine(TimelineDocument.parse({
			id: "late-session",
			duration: 60_000,
			events: [
				{
					id: "j1",
					t: 0,
					kind: "peer-joined",
					peerId: "a",
					profile: "glowcap",
				},
				{
					id: "j2",
					t: 0,
					kind: "peer-joined",
					peerId: "b",
					profile: "goblins",
				},
				{
					id: "s1o",
					t: 5_000,
					kind: "session-opened",
					sessionId: "s1",
					a: { peer: "a" },
					b: { peer: "b" },
					codec: "syrup",
					captpVersion: "v1_0",
				},
			],
		}));
		e.dispatch({
			kind: "update-session",
			sessionId: "s1",
			patch: { codec: "capnp" },
		});
		assertEquals(
			e.doc.entities?.sessions?.["s1"]?.codec,
			"capnp",
			"the authored definition is editable regardless of the playhead",
		);
		// Re-applying the value the definition already holds is a no-op.
		e.dispatch({
			kind: "update-session",
			sessionId: "s1",
			patch: { codec: "capnp" },
		});
		e.undo();
		assertEquals(e.doc.entities?.sessions?.["s1"]?.codec, "syrup");
		assert(!e.canUndo, "the repeat dispatch pushed no history entry");
	},
);

/** A document whose session is born open, so "the state it already
 *  carries" is a real value at every moment of its life and there is
 *  no keyframe standing anywhere. */
function bornOpenDoc() {
	return TimelineDocument.parse({
		id: "born-open",
		duration: 60_000,
		events: [
			{
				id: "j1",
				t: 0,
				kind: "peer-joined",
				peerId: "a",
				profile: "glowcap",
			},
			{
				id: "j2",
				t: 0,
				kind: "peer-joined",
				peerId: "b",
				profile: "goblins",
			},
			{
				id: "s1o",
				t: 0,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "a" },
				b: { peer: "b" },
				codec: "syrup",
				captpVersion: "v1_0",
				initialState: "open",
			},
		],
	});
}

const stateTrack = (e: Engine) => e.doc.entities?.sessions?.["s1"]?.keyframes?.state ?? [];

engineTest(
	"stating the state a session already carries declares it at that moment",
	() => {
		// The session is open at 2000 with nothing saying so there. Saying
		// it pins it: an edit to the genesis state stops reaching past
		// 2000. So it is a document change, and refusing it as "the value
		// is already that" refuses a thing the author can plainly mean.
		const e = new Engine(bornOpenDoc());
		e.seekTo(2_000);
		e.dispatch({
			kind: "update-session",
			sessionId: "s1",
			patch: { state: "open" },
		});
		assertEquals(
			stateTrack(e),
			[{ t: 2_000, value: "open" }],
			"restating the current state at the playhead declares it there",
		);
		assert(
			e.canUndo,
			"a declaration is a document change, so it is undoable",
		);
	},
);

engineTest(
	"one rule for both spellings of a session's state write",
	() => {
		// `update-session { state }` and `set-session-keyframe` are one
		// write reached by two names, so neither may refuse what the
		// other accepts. Run each from the same starting document and
		// compare what it produced: two rules for one fact show up here
		// as one empty track and one declaration.
		const viaPatch = new Engine(bornOpenDoc());
		viaPatch.seekTo(2_000);
		viaPatch.dispatch({
			kind: "update-session",
			sessionId: "s1",
			patch: { state: "open" },
		});
		const viaKeyframe = new Engine(bornOpenDoc());
		viaKeyframe.seekTo(2_000);
		viaKeyframe.dispatch({
			kind: "set-session-keyframe",
			sessionId: "s1",
			property: "state",
			t: 2_000,
			value: "open",
		});
		assertEquals(
			stateTrack(viaPatch),
			stateTrack(viaKeyframe),
			"both names for one write leave the same document",
		);
		assertEquals(
			viaPatch.canUndo,
			viaKeyframe.canUndo,
			"and the same history behind it",
		);
		// Whichever made the declaration, the other sees it and stands
		// down.
		viaKeyframe.dispatch({
			kind: "update-session",
			sessionId: "s1",
			patch: { state: "open" },
		});
		viaKeyframe.undo();
		assertEquals(
			stateTrack(viaKeyframe),
			[],
			"the second spelling restated the same declaration, so it did nothing",
		);
		assert(
			!viaKeyframe.canUndo,
			"the repeat dispatch pushed no history entry",
		);
	},
);

engineTest(
	"a second identical declaration at one instant does nothing, in both lanes",
	() => {
		// What the trajectory insert control does twice at one playhead:
		// the first press declares, the second would produce the document
		// the first already produced. Both lanes answer alike, because a
		// moment is the same thing on either.
		const e = new Engine(bornOpenDoc());
		e.dispatch({
			kind: "set-session-keyframe",
			sessionId: "s1",
			property: "state",
			t: 2_000,
			value: "open",
		});
		e.dispatch({
			kind: "set-session-keyframe",
			sessionId: "s1",
			property: "state",
			t: 2_000,
			value: "open",
		});
		e.undo();
		assertEquals(
			stateTrack(e),
			[],
			"the session lane refused the duplicate",
		);
		assert(!e.canUndo, "and pushed nothing for it");

		// The peer lane: `a` answers to its id, so stating that as its
		// name at 2000 is the insert control's own offer.
		e.dispatch({
			kind: "set-peer-update",
			peerId: "a",
			t: 2_000,
			property: "label",
			value: "a",
		});
		assertEquals(
			e.doc.entities?.peers?.["a"]?.keyframes?.label,
			[{ t: 2_000, value: "a" }],
			"restating the name the peer already answers to declares it there",
		);
		e.dispatch({
			kind: "set-peer-update",
			peerId: "a",
			t: 2_000,
			property: "label",
			value: "a",
		});
		e.undo();
		assertEquals(
			e.doc.entities?.peers?.["a"]?.keyframes?.label ?? [],
			[],
			"the peer lane refused the duplicate the same way",
		);
	},
);

engineTest(
	"taking away a declaration that was never made does nothing, in both lanes",
	() => {
		// The mirror of the rule above, and it has to be the same
		// question: a removal takes the declaration standing at that
		// instant, so an instant with none is an instant with nothing to
		// take. The session lane is the one that is easy to get wrong,
		// because the session is plainly in some state at 2000, but no
		// moment there says so.
		const e = new Engine(bornOpenDoc());
		e.dispatch({
			kind: "remove-session-keyframe",
			sessionId: "s1",
			property: "state",
			t: 2_000,
		});
		assert(!e.canUndo, "the session lane pushed no history entry");
		e.dispatch({
			kind: "remove-peer-update",
			peerId: "a",
			t: 2_000,
			property: "label",
		});
		assert(!e.canUndo, "and neither did the peer lane");
	},
);

engineTest(
	"set-peer-end measures the painted start, not the retained stored value",
	() => {
		// clear-peer-start keeps the last stored start (1000) for
		// toggle-back, but the painted start becomes the world's 0. The
		// mutation derives duration from the painted start, so the
		// guard must too, stored-value arithmetic declares a real edit
		// a no-op exactly when retained-start + duration lands on t.
		const e = new Engine(TimelineDocument.parse({
			id: "cleared-start-peer",
			duration: 60_000,
			events: [
				{
					id: "j1",
					t: 1_000,
					kind: "peer-joined",
					peerId: "p",
					profile: "glowcap",
				},
			],
		}));
		e.dispatch({ kind: "clear-peer-start", peerId: "p" });
		e.dispatch({ kind: "set-peer-end", peerId: "p", t: 1_500 });
		assertEquals(e.effectiveEnd("peers", "p"), 1_500);
		e.dispatch({ kind: "set-peer-end", peerId: "p", t: 2_500 });
		assertEquals(e.effectiveEnd("peers", "p"), 2_500);
	},
);

engineTest(
	"set-session-end measures the painted start, not the retained stored value",
	() => {
		const e = new Engine(TimelineDocument.parse({
			id: "cleared-start-session",
			duration: 60_000,
			events: [
				{
					id: "j1",
					t: 0,
					kind: "peer-joined",
					peerId: "a",
					profile: "glowcap",
				},
				{
					id: "j2",
					t: 0,
					kind: "peer-joined",
					peerId: "b",
					profile: "goblins",
				},
				{
					id: "s1o",
					t: 1_000,
					kind: "session-opened",
					sessionId: "s1",
					a: { peer: "a" },
					b: { peer: "b" },
					codec: "syrup",
					captpVersion: "v1_0",
				},
			],
		}));
		// Cleared start retains 1000; painted start cascades to the
		// peers' max join time, 0.
		e.dispatch({ kind: "clear-session-start", sessionId: "s1" });
		e.dispatch({ kind: "set-session-end", sessionId: "s1", t: 1_500 });
		assertEquals(e.effectiveEnd("sessions", "s1"), 1_500);
		e.dispatch({ kind: "set-session-end", sessionId: "s1", t: 2_500 });
		assertEquals(e.effectiveEnd("sessions", "s1"), 2_500);
	},
);

/** Peers at 0, session s1 opened at `openT`, message m1 in flight
 *  1000 → 1500. The message scenarios below all start here. */
