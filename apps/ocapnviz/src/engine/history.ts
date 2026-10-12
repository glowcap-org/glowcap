/**
 * Undo/redo stack for the engine's mutable doc state. Split from
 * `engine.ts` because it's a tight, self-contained collection that
 * has nothing to do with the engine's tick / world / clock
 * concerns, just snapshot push/pop bookkeeping.
 */

import type { TimelineDocument } from "./timeline.ts";
import { deepEqual } from "./deep-equal.ts";

/** Snapshot of the engine's mutable doc state. `rowOrder` and
 * the three `row*Hidden` arrays are per-category timeline-view
 * overrides (Flash-grade timeline) that the engine mutates through
 * `reorder-row` and the row-visibility intents, so they need to
 * round-trip through undo too. `duration` is authoring-mutable,
 * edits landing past the end grow it (`growDurationToFit` /
 * `commitEntityAuthoring`), so it rounds-trip too. Other doc
 * fields (id, layoutMode) are construction-time and not
 * snapshotted.
 *
 * The three hidden lists are MUTUALLY EXCLUSIVE per entity id,
 * `rowHidden` = both body+label off, `rowLabelHidden` = label
 * off only, `rowBodyHidden` = body off only. An id absent from
 * all three is fully visible on stage. */
export type DocSnapshot = {
	duration: TimelineDocument["duration"];
	rowOrder: TimelineDocument["rowOrder"];
	rowHidden: TimelineDocument["rowHidden"];
	rowLabelHidden: TimelineDocument["rowLabelHidden"];
	rowBodyHidden: TimelineDocument["rowBodyHidden"];
	allVisMode: TimelineDocument["allVisMode"];
	categoryVisMode: TimelineDocument["categoryVisMode"];
	/** Recording layer, `primaryObservations(doc)` writes into
	 *  `recording.sources[0].observations`, so the whole field must
	 *  round-trip through undo. Authoring mutates the per-source
	 *  observation arrays in place, snapshot/restore deep-clones so
	 *  rollback restores the exact pre-mutation list. */
	recording: TimelineDocument["recording"];
	/** Identity-side of the entity model (see `Entities` in
	 *  timeline.ts). Snapshotted so undo / redo round-trip the
	 *  "is this peer eternal-start" decision along with the
	 *  events that depend on it. */
	entities: TimelineDocument["entities"];
	/** What the document says about itself. Editing a title or a creator is a
	 *  document edit like any other, so it round-trips.
	 *
	 *  `dct:modified` rides along without being a problem, because nothing in the
	 *  edit path writes it: it is stamped when a document is saved
	 *  (`schema/provenance.ts`). Were it stamped per edit, every keystroke would
	 *  differ from the last and `endTransaction`'s no-op detection would push a
	 *  history entry for a transaction that changed nothing. */
	metadata: TimelineDocument["metadata"];
	/** Where the document opens. A document field like the rest, and it round-trips
	 *  for exactly that reason: setting it is an edit a reader presses for, so it is
	 *  an edit they can take back.
	 *
	 *  Nothing writes it as the camera moves. Looking around is not an edit, a
	 *  wheel gesture is one gesture and a reader who is only reading should not be
	 *  building a history, so the camera stays the camera until the Opens-at row's
	 *  button says to record it (`Engine.setOpeningView`). */
	initialView: TimelineDocument["initialView"];
};

/** History stack entry. `label` is the forward-direction action
 * name ("Add peer", "Move peer"). The UI prefixes it with "Undo "
 * / "Redo " for tooltips. */
export type HistoryEntry = {
	snapshot: DocSnapshot;
	label: string;
};

/**
 * Bounded undo/redo stack, text-editor model. `past` holds
 * snapshots recorded before each mutation, `future` holds entries
 * banked by `undo()`. A fresh action clears `future`. Oldest
 * entries drop off the bottom of `past` at the `limit`.
 */
export class History {
	#past: HistoryEntry[] = [];
	#future: HistoryEntry[] = [];
	readonly #limit: number;

	constructor(limit = 100) {
		this.#limit = limit;
	}

	recordBefore(snapshot: DocSnapshot, label: string): void {
		this.#past.push({ snapshot, label });
		if (this.#past.length > this.#limit) this.#past.shift();
		this.#future = [];
	}

	/** Pop the previous entry, banking the current snapshot for redo. */
	undo(currentSnapshot: DocSnapshot): HistoryEntry | undefined {
		const previous = this.#past.pop();
		if (!previous) return undefined;
		this.#future.push({ snapshot: currentSnapshot, label: previous.label });
		return previous;
	}

	/**
	 * Walk all the way back, in one move.
	 *
	 * Exactly the bookkeeping of pressing undo until it stops, every
	 * entry crosses to `future` with the state it was taken from, so
	 * redo walks forward again step by step and nothing is lost. What it
	 * saves is the walk itself: the caller applies one snapshot rather
	 * than every intermediate one, and each of those costs a layout
	 * derivation and a seek.
	 *
	 * Returns the oldest entry, which is the one to apply, or
	 * `undefined` when there was nothing to walk back.
	 */
	undoAll(currentSnapshot: DocSnapshot): HistoryEntry | undefined {
		let banked = currentSnapshot;
		let oldest: HistoryEntry | undefined;
		while (this.#past.length > 0) {
			oldest = this.#past.pop()!;
			this.#future.push({ snapshot: banked, label: oldest.label });
			banked = oldest.snapshot;
		}
		return oldest;
	}

	/** Pop the next entry, banking the current snapshot for undo. */
	redo(currentSnapshot: DocSnapshot): HistoryEntry | undefined {
		const next = this.#future.pop();
		if (!next) return undefined;
		this.#past.push({ snapshot: currentSnapshot, label: next.label });
		return next;
	}

	get canUndo(): boolean {
		return this.#past.length > 0;
	}
	get canRedo(): boolean {
		return this.#future.length > 0;
	}
	/** Label of the action that `undo()` would reverse, if any. */
	get nextUndoLabel(): string | undefined {
		return this.#past.at(-1)?.label;
	}
	/** Label of the action that `redo()` would re-apply, if any. */
	get nextRedoLabel(): string | undefined {
		return this.#future.at(-1)?.label;
	}

	clear(): void {
		this.#past = [];
		this.#future = [];
	}
}

/** Whether two snapshots say the same thing, used to drop a no-op
 * transaction (focused and did not type, dragged and returned to the
 * start) from the history stack.
 *
 * It compares the snapshot whole rather than field by field, so a
 * field added to `DocSnapshot` is compared without anyone remembering
 * to extend a list here, which is the defect this shape replaced: the
 * per-category row overrides had to be added by hand before a reorder
 * that changed nothing was recognized as changing nothing. `deepEqual`
 * owns what "the same" means for the shapes a document is made of. */
export function snapshotsEqual(a: DocSnapshot, b: DocSnapshot): boolean {
	return deepEqual(a, b);
}
