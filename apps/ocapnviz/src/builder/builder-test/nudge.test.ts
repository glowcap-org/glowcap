/**
 * Arrow-key nudges over the nodes the stage lets you drag: a peer,
 * or an end nothing has attributed. A press that moves nothing hands
 * the keystroke back so it can scrub time.
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../../engine/engine.ts";
import { findNode } from "../../engine/world.ts";
import { nudgeSelection } from "../selection-history.ts";
import type { EntityRefKey } from "../../interactions/types.ts";
import { endPin, engineTest, LOOSE_END, looseDoc, peerPin } from "./harness.ts";

/** Where the stage is holding a node right now, copied out of the world so a
 *  later write cannot move the value under the assertion. */
function nodeAt(e: Engine, id: string): { x: number; y: number } {
	const at = findNode(e.world, id)?.position;
	assert(at, `the stage is not holding ${id}`);
	return { x: at.x, y: at.y };
}

engineTest("an arrow key moves an end nothing has attributed", () => {
	// The end is draggable on the stage, so it is nudgeable too: an entity a
	// reader can move one way and not the other is the interaction model
	// saying two different things about one node.
	const e = new Engine(looseDoc());
	const at = nodeAt(e, LOOSE_END);
	assert(nudgeSelection(e, new Set([`endpoint:${LOOSE_END}`]), {
		dx: 1,
		dy: -1,
	}));
	assertEquals(endPin(e), { x: at.x + 1, y: at.y - 1 });
});

engineTest("a nudge is one undo step, named for what it moved", () => {
	// The session in the selection is drawn between its two ends and has no
	// place of its own, so the label counts the two nodes that moved rather
	// than the three things selected.
	const e = new Engine(looseDoc());
	const carolAt = nodeAt(e, "carol");
	const endAt = nodeAt(e, LOOSE_END);
	const selection = new Set<EntityRefKey>([
		"peer:carol",
		`endpoint:${LOOSE_END}`,
		"session:s1",
	]);
	assert(nudgeSelection(e, selection, { dx: 4, dy: 0 }));
	assertEquals(e.nextUndoLabel, "Nudge 1 peer and 1 session end");
	assertEquals(peerPin(e, "carol"), { x: carolAt.x + 4, y: carolAt.y });
	assertEquals(endPin(e), { x: endAt.x + 4, y: endAt.y });
	e.undo();
	assertEquals(peerPin(e, "carol"), null);
	assertEquals(endPin(e), null);
});

engineTest("a nudge that moves nothing hands the keystroke back", () => {
	// Which is what lets an arrow over a selection of sessions go on scrubbing
	// time instead of being swallowed by a move that never happened.
	const e = new Engine(looseDoc());
	assertEquals(
		nudgeSelection(e, new Set<EntityRefKey>(["session:s1"]), {
			dx: 1,
			dy: 0,
		}),
		false,
	);
	assertEquals(e.canUndo, false, "a nudge that moved nothing spent a step");
});
