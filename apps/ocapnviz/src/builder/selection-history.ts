/**
 * Selection-aware history and whole-selection moves.
 *
 * A history step moves ids out from under the selection, so the step
 * and the walk that catches the selection up are one act. The arrow
 * keys and unpin-all are the same kind of act: they name every node
 * in the selection (or every pin on the stage) and write them in one
 * undo step.
 */

import type React from "react";
import type { Engine } from "../engine/engine.ts";
import { findNode } from "../engine/world.ts";
import { authoredPins } from "../engine/event-helpers.ts";
import { selectionPhrase, tallyByKind } from "../ui/inspector/selection-summary.ts";
import { type EntityRefKey, parseEntityKey, type SelectionAction } from "../interactions/types.ts";
import { nodeKindOf } from "../schema/session-end.ts";
import { asOneEdit } from "./as-one-edit.ts";

/**
 * Hand every pinned node back to the force layout.
 *
 * The same act the Inspector's position row offers one node at a time,
 * swept across the whole stage. Both kinds of pin go: a peer's authored
 * position and a session end's, which `authoredPins` reads together so this
 * cannot clear one kind and call the stage unpinned.
 *
 * One transaction, so the whole sweep is one undo step, because the reader
 * made one gesture. An empty stage dispatches nothing rather than opening a
 * transaction that would close on no change.
 */
export function clearAllPins(engine: Engine): void {
	const pins = authoredPins(engine.doc);
	if (pins.size === 0) return;
	asOneEdit(engine, "Unpin all", () => {
		for (const nodeId of pins.keys()) {
			if (nodeKindOf(nodeId) === "endpoint") {
				engine.dispatch({
					kind: "clear-endpoint-position",
					endpointId: nodeId,
				});
			} else {
				engine.dispatch({
					kind: "clear-peer-position",
					peerId: nodeId,
				});
			}
		}
	});
}

/**
 * Move every node in the selection by one step.
 *
 * A node is a peer or a session end nothing has attributed, which is the same
 * pair the stage lets you drag, so what the arrow keys move and what the
 * pointer moves are one set. Everything else in the selection sits still: a
 * session is drawn between its two ends and a message rides the wire, so
 * neither has a place of its own to be moved to.
 *
 * Every position is read before the first write, because repositioning one
 * node re-solves the layout around it: read as we go and a later node would
 * step off wherever the solver had just put it rather than off where the
 * reader saw it.
 *
 * One transaction, so a press moves the whole selection in a single undo
 * step, and the label names what actually moved. A press that moves nothing
 * answers `false` and hands the keystroke back, which is what lets an arrow
 * over a selection of sessions go on scrubbing time.
 */
export function nudgeSelection(
	engine: Engine,
	selection: ReadonlySet<EntityRefKey>,
	delta: { dx: number; dy: number },
): boolean {
	const moving: {
		key: EntityRefKey;
		kind: "peer" | "endpoint";
		id: string;
		to: { x: number; y: number };
	}[] = [];
	for (const key of selection) {
		const { kind, id } = parseEntityKey(key);
		if (kind !== "peer" && kind !== "endpoint") continue;
		const from = findNode(engine.world, id)?.position;
		if (from === undefined) continue;
		moving.push({
			key,
			kind,
			id,
			to: { x: from.x + delta.dx, y: from.y + delta.dy },
		});
	}
	if (moving.length === 0) return false;
	const moved = new Set<EntityRefKey>(moving.map((m) => m.key));
	asOneEdit(engine, `Nudge ${selectionPhrase(tallyByKind(moved))}`, () => {
		engine.repositionNodes(
			moving.map((m) => ({
				kind: m.kind,
				id: m.id,
				position: m.to,
			})),
		);
	});
	return true;
}

function reconcileSelection(
	engine: Engine,
	dispatchSelection: React.Dispatch<SelectionAction>,
): void {
	dispatchSelection({
		kind: "reconcile-with-doc",
		entities: engine.doc.entities,
	});
}

/**
 * Take history back, and walk the selection back with it.
 *
 * Undo moves ids out from under the selection. A rename taken back restores
 * the name the peer had before it, an undone paste takes its entities away
 * again, and a selection still naming what went is a selection pointing at
 * nothing, which the Inspector reads out as an unknown peer. So the two are
 * one act, and every surface that offers undo asks for it here instead of
 * reaching for the engine on its own.
 */
export function undoWithSelection(
	engine: Engine,
	dispatchSelection: React.Dispatch<SelectionAction>,
): void {
	engine.undo();
	reconcileSelection(engine, dispatchSelection);
}

/** Take history forward, and walk the selection with it. The mirror of
 *  `undoWithSelection`: redo moves ids under the selection exactly as undo
 *  does, so it takes the same pair of steps. */
export function redoWithSelection(
	engine: Engine,
	dispatchSelection: React.Dispatch<SelectionAction>,
): void {
	engine.redo();
	reconcileSelection(engine, dispatchSelection);
}

/**
 * Throw away every edit, and walk the selection back with them.
 *
 * The same pairing `undoWithSelection` makes, for the same reason and
 * more of it: a discard takes back every id an edit ever minted at
 * once, so a selection naming a peer the author added is a selection
 * pointing at nothing the moment the command runs.
 *
 * The engine's `discardAllEdits` is the reset, and unlike a step of
 * history it cannot be taken back: it empties the history along with
 * the edits, because the steps in it lead back through a document that
 * is no longer the one in front of you. That is what makes it the one
 * act in Build a reader cannot recover from, and why the affordance
 * asks first. A reader who wants their edits back afterwards wanted
 * `undoAllWithSelection` below.
 */
export function discardAllEdits(
	engine: Engine,
	dispatchSelection: React.Dispatch<SelectionAction>,
): void {
	engine.discardAllEdits();
	reconcileSelection(engine, dispatchSelection);
}

/**
 * Walk the whole history back, and walk the selection with it.
 *
 * "Undo all", which is undo held down: the same act
 * `undoWithSelection` performs, repeated until the history runs out,
 * so it takes the same second step for the same reason, a history
 * move takes ids out from under the selection, and taking many at once
 * takes more of them.
 *
 * The mild half of the pair with `discardAllEdits` above. It keeps the
 * history, so every step crosses to the redo side and the author can
 * walk forward again. What it cannot promise is the document the
 * buffer was built from, because the stack is bounded and restores
 * only the fields a `DocSnapshot` carries.
 */
export function undoAllWithSelection(
	engine: Engine,
	dispatchSelection: React.Dispatch<SelectionAction>,
): void {
	engine.undoAll();
	reconcileSelection(engine, dispatchSelection);
}
