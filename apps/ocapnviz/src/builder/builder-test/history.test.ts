/**
 * Taking history back or forward, and the selection that has to
 * walk with it. A step that moves ids out from under the Inspector
 * without catching the selection up leaves it pointing at a name
 * the document no longer answers to. status-allow: lifecycle transition
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../../engine/engine.ts";
import { asOneEdit } from "../as-one-edit.ts";
import { discardAllEdits, redoWithSelection, undoAllWithSelection, undoWithSelection } from "../selection-history.ts";
import { selectionReducer } from "../../interactions/selection-store.ts";
import {
	EMPTY_SELECTION,
	type EntityRefKey,
	type SelectionAction,
	type SelectionState,
} from "../../interactions/types.ts";
import { engineTest, looseDoc, peerPin, PIN_A } from "./harness.ts";

/** The selection store, driven the way the App drives it. */
function selectionHost(initial: Partial<SelectionState>) {
	let state: SelectionState = { ...EMPTY_SELECTION, ...initial };
	return {
		dispatch: (action: SelectionAction) => {
			state = selectionReducer(state, action);
		},
		get state(): SelectionState {
			return state;
		},
	};
}

engineTest("undo takes a rename back, and the selection lets go", () => {
	// The rename re-anchors the selection forward, so undo has to walk it
	// back. Left alone, the Inspector goes on pointing at a name the document
	// no longer answers to and reads out an unknown peer. status-allow: lifecycle transition
	const e = new Engine(looseDoc());
	const host = selectionHost({
		anchor: { kind: "peer", id: "carol" },
		selection: new Set<EntityRefKey>(["peer:carol"]),
	});
	e.dispatch({ kind: "rename-peer", oldId: "carol", newId: "caroline" });
	host.dispatch({
		kind: "rename-entity",
		entityKind: "peer",
		oldId: "carol",
		newId: "caroline",
	});
	assert(host.state.selection.has("peer:caroline"));

	undoWithSelection(e, host.dispatch);
	assert(e.doc.entities?.peers?.carol, "undo did not restore the old name");
	assertEquals(
		host.state.selection.has("peer:caroline"),
		false,
		"the selection still names a peer the document lost",
	);
	assertEquals(host.state.anchor, null);
});

engineTest("a peer an author added survives a step of history", () => {
	// An added peer is declared among the document's entities and mentioned by
	// no observation at all, so asking the observation stream whether the
	// document still holds it answers no, and clears the reader's selection
	// on the next Cmd-Z. The identity map is what answers this.
	const e = new Engine(looseDoc());
	const added = e.dispatch({
		kind: "add-peer",
		profile: "glowcap",
		position: { x: 10, y: 10 },
	});
	assert(added);
	const key: EntityRefKey = `peer:${added}`;
	e.dispatch({ kind: "reposition-peer", peerId: "carol", position: PIN_A });
	const host = selectionHost({
		anchor: { kind: "peer", id: added },
		selection: new Set<EntityRefKey>([key]),
	});

	undoWithSelection(e, host.dispatch);
	assertEquals(peerPin(e, "carol"), null, "the undo took back nothing");
	assert(host.state.selection.has(key), "the added peer lost its selection");
	assertEquals(host.state.anchor?.id, added);
});

engineTest("redo drops what going forward takes away", () => {
	// Redo moves ids under the selection exactly as undo does, so it walks the
	// selection the same way.
	const e = new Engine(looseDoc());
	e.dispatch({ kind: "delete-peer", peerId: "alice" });
	const host = selectionHost({});
	undoWithSelection(e, host.dispatch);
	assert(e.doc.entities?.peers?.alice, "undo did not bring the peer back");
	host.dispatch({
		kind: "set-selection",
		entities: new Set<EntityRefKey>(["peer:alice"]),
	});

	redoWithSelection(e, host.dispatch);
	assertEquals(host.state.selection.size, 0);
	assertEquals(host.state.anchor, null);
});

engineTest("a discard drops the selection it took the entities from", () => {
	// The strongest case of what undo does one step at a time: a discard
	// takes back every id an edit ever minted at once, so a selection
	// naming a peer the author added is left pointing at nothing.
	const e = new Engine(looseDoc());
	const added = e.dispatch({
		kind: "add-peer",
		profile: "glowcap",
		position: { x: 10, y: 10 },
	});
	assert(added);
	const key: EntityRefKey = `peer:${added}`;
	const host = selectionHost({
		anchor: { kind: "peer", id: added },
		selection: new Set<EntityRefKey>([key]),
	});

	discardAllEdits(e, host.dispatch);
	assertEquals(
		e.doc.entities?.peers?.[added],
		undefined,
		"the discard left the added peer in the document",
	);
	assertEquals(
		host.state.selection.has(key),
		false,
		"the selection still names a peer the discard took away",
	);
	assertEquals(host.state.anchor, null);
});

engineTest("undo all walks the selection back the way undo does", () => {
	// The same act, repeated, so it takes the same second step: the
	// history move that takes an added peer away has to take the
	// selection naming it away too.
	const e = new Engine(looseDoc());
	const added = e.dispatch({
		kind: "add-peer",
		profile: "glowcap",
		position: { x: 10, y: 10 },
	});
	assert(added);
	const key: EntityRefKey = `peer:${added}`;
	const host = selectionHost({
		anchor: { kind: "peer", id: added },
		selection: new Set<EntityRefKey>([key]),
	});

	undoAllWithSelection(e, host.dispatch);
	assertEquals(e.doc.entities?.peers?.[added], undefined);
	assertEquals(
		host.state.selection.has(key),
		false,
		"the selection still names a peer undo all took away",
	);
	// Unlike the discard, the way forward is still there.
	assert(e.canRedo, "undo all left no way forward");
});

engineTest("a discard with nothing to discard leaves the selection", () => {
	// The mirror of the case above, and the one a reader meets more
	// often: the command is inert, so nothing runs, and a selection made
	// while looking around is not disturbed by pressing it.
	const e = new Engine(looseDoc());
	const host = selectionHost({
		anchor: { kind: "peer", id: "alice" },
		selection: new Set<EntityRefKey>(["peer:alice"]),
	});

	discardAllEdits(e, host.dispatch);
	assert(host.state.selection.has("peer:alice"));
	assertEquals(host.state.anchor?.id, "alice");
	assertEquals(e.canUndo, false, "the refused discard spent a step");
});

// ─────────────── one gesture, one undo step, every way out ───────────────

engineTest("a run that throws still closes its undo step", () => {
	// The transaction depth is app-wide state: the engine records
	// history only at depth zero, so a run that opens one and escapes
	// without closing it does not merely lose its own step. It swallows
	// every dispatch after it, and from then on nothing in the app is
	// undoable, with nothing said.
	const e = new Engine(looseDoc());
	const before = e.canUndo;
	let escaped: unknown = null;
	try {
		asOneEdit(e, "Delete 2 peers", () => {
			e.dispatch({ kind: "delete-peer", peerId: "alice" });
			throw new Error("a bad key, halfway through the selection");
		});
	} catch (err) {
		escaped = err;
	}
	assert(escaped instanceof Error, "the throw was swallowed, not surfaced");
	// The proof that depth came back to zero: a later, unrelated edit
	// records a step of its own instead of vanishing into the open one.
	e.dispatch({ kind: "reposition-peer", peerId: "carol", position: PIN_A });
	assert(e.canUndo && !before, "the later edit landed in nobody's history");
	assertEquals(e.nextUndoLabel, "Move peer");
});

engineTest("a run that returns records one step for the whole run", () => {
	const e = new Engine(looseDoc());
	asOneEdit(e, "Unpin all", () => {
		e.dispatch({
			kind: "reposition-peer",
			peerId: "carol",
			position: PIN_A,
		});
		e.dispatch({
			kind: "reposition-peer",
			peerId: "alice",
			position: PIN_A,
		});
	});
	assertEquals(e.nextUndoLabel, "Unpin all");
	undoWithSelection(e, selectionHost({}).dispatch);
	assertEquals(peerPin(e, "carol"), null, "the step took back only half");
	assertEquals(peerPin(e, "alice"), null, "the step took back only half");
});
