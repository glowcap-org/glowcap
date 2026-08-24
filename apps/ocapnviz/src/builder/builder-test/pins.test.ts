/**
 * Unpin-all over every kind of pin the stage draws: a peer, and an
 * end nothing has attributed. A sweep that cleared only one would
 * leave the stage half-pinned while telling the reader it had not.
 */

import { assertEquals } from "@std/assert";
import { Engine } from "../../engine/engine.ts";
import { TimelineDocument } from "../../engine/timeline.ts";
import { authoredPins } from "../../engine/event-helpers.ts";
import { clearAllPins } from "../selection-history.ts";
import { endPin, engineTest, LOOSE_END, looseDoc, peerPin, PIN_A, PIN_B } from "./harness.ts";

/** Pin both kinds of node the stage draws: a peer, and the end nothing has
 *  attributed. `looseDoc` gives us one of each. */
function pinBoth(e: Engine): void {
	e.dispatch({ kind: "reposition-peer", peerId: "carol", position: PIN_A });
	e.dispatch({
		kind: "reposition-endpoint",
		endpointId: LOOSE_END,
		position: PIN_B,
	});
}

engineTest("Unpin all clears both kinds of pin", () => {
	// A sweep that cleared only peers would leave the stage half-pinned while
	// telling the reader it had unpinned everything, which is the failure this
	// control exists to not have.
	const e = new Engine(looseDoc());
	pinBoth(e);
	assertEquals(peerPin(e, "carol"), PIN_A);
	assertEquals(endPin(e), PIN_B);
	clearAllPins(e);
	assertEquals(peerPin(e, "carol"), null);
	assertEquals(endPin(e), null);
});

engineTest("Unpin all is one undo step, and it restores both pins", () => {
	const e = new Engine(looseDoc());
	pinBoth(e);
	clearAllPins(e);
	assertEquals(e.nextUndoLabel, "Unpin all");
	e.undo();
	assertEquals(
		peerPin(e, "carol"),
		PIN_A,
		"one undo did not bring the peer's pin back",
	);
	assertEquals(
		endPin(e),
		PIN_B,
		"one undo did not bring the end's pin back — the sweep was more than " +
			"one transaction",
	);
});

engineTest(
	"an unpinned stage reads as unpinned, and the sweep is inert",
	() => {
		// `authoredPins` is what tells the control whether to offer itself, so a
		// count that saw a pin where the document has none would leave the button
		// live on a stage with nothing to unpin — and pressing it would spend the
		// reader's undo on a press that changed nothing.
		const e = new Engine(looseDoc());
		assertEquals(authoredPins(e.doc).size, 0);
		clearAllPins(e);
		assertEquals(e.canUndo, false);
		// ...and it wakes for either kind of pin on its own.
		e.dispatch({
			kind: "reposition-peer",
			peerId: "carol",
			position: PIN_A,
		});
		assertEquals(authoredPins(e.doc).size, 1);
		e.dispatch({
			kind: "reposition-endpoint",
			endpointId: LOOSE_END,
			position: PIN_B,
		});
		assertEquals(authoredPins(e.doc).size, 2);
	},
);

engineTest("a peer pinned by its joining observation unpins too", () => {
	// A declared `entities.peers` entry wins over the event payload outright
	// (`TimelineDocument`'s transform never merges the two), so a document
	// that declares a peer AND records it joining somewhere else keeps its
	// only pin on the observation. `authoredPeerPosition` reads the
	// definition first and the observation second for exactly that shape, and
	// the sweep has to see the same pin the Inspector shows.
	const e = new Engine(TimelineDocument.parse({
		id: "joined-pin",
		duration: 10000,
		entities: { peers: { carol: { profile: "pancake" } } },
		events: [{
			id: "p1",
			t: 0,
			kind: "peer-joined",
			peerId: "carol",
			profile: "pancake",
			position: PIN_A,
		}],
	}));
	assertEquals(e.doc.entities?.peers?.carol?.position, undefined);
	assertEquals(peerPin(e, "carol"), PIN_A);
	clearAllPins(e);
	assertEquals(peerPin(e, "carol"), null);
});
