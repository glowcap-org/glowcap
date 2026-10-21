/**
 * Edit session, transactions, undo, and wholesale document restore.
 *
 * The History stack itself lives in `history.ts`. This module owns the
 * Engine-side orchestration that History cannot: nesting, the snapshot
 * captured at depth 1, deferred layout/seek until `endTransaction`, and
 * the post-restore rebuild (clock duration, layout, seek). Playback does
 * not know about any of this. Authoring seeks through here so a typing
 * burst is one history entry rather than one per keystroke.
 */

import { Clock } from "./clock.ts";
import { type DocSnapshot, History, snapshotsEqual } from "./history.ts";
import { resetDocumentTo, restoreSnapshotInto, takeSnapshot } from "./snapshot.ts";
import { KeyframeLayoutSystem } from "./systems/keyframe-layout-system.ts";
import type { TimelineDocument } from "./timeline.ts";

export type EditHost = {
	getDoc(): TimelineDocument;
	readonly clock: Clock;
	readonly layout: KeyframeLayoutSystem;
	notify(docChanged?: boolean): void;
	/** Rebuild the world at `t` without notifying. */
	seekWorld(t: number): void;
	/** The document this engine was built from, `discardAllEdits` target. */
	source(): TimelineDocument;
};

export class EditSession {
	#history = new History();
	// Transaction nesting + the snapshot/label captured at depth=1.
	// Mutations within a transaction coalesce into ONE history entry
	// (e.g. every keystroke between focus and blur).
	#txnDepth = 0;
	#txnSnapshot: DocSnapshot | null = null;
	#txnLabel = "";
	/** Layout must recompute when the transaction closes (pin clears,
	 *  deletes, other topology edits). Coalesces N cold anneals into one. */
	#txnLayoutDirty = false;
	/** Authoring seek deferred to transaction end. Null when none pending. */
	#txnSeekT: number | null = null;

	constructor(private readonly host: EditHost) {}

	get isOpen(): boolean {
		return this.#txnDepth > 0;
	}

	get txnSnapshot(): DocSnapshot | null {
		return this.#txnSnapshot;
	}

	get canUndo(): boolean {
		return this.#history.canUndo;
	}
	get canRedo(): boolean {
		return this.#history.canRedo;
	}
	/**
	 * Whether the history holds anything at all, in either direction.
	 *
	 * Distinct from `canUndo`, which asks whether there are steps LEFT
	 * TO WALK BACK. They come apart at the bottom of the stack: a reader
	 * who has undone their way to the start is at the beginning of a
	 * history that still exists, with every step of it sitting on the
	 * redo side. `undoAll` has nothing to do there and `discardAllEdits`
	 * does. It is the one that throws the history away, and there is a
	 * history to throw away.
	 */
	get hasHistory(): boolean {
		return this.#history.canUndo || this.#history.canRedo;
	}
	/**
	 * Name of the action `undo()` would reverse, drives the
	 * "Undo {label}" tooltip. `undefined` when nothing to undo. */
	get nextUndoLabel(): string | undefined {
		return this.#history.nextUndoLabel;
	}
	/** Name of the action `redo()` would re-apply, or `undefined`. */
	get nextRedoLabel(): string | undefined {
		return this.#history.nextRedoLabel;
	}

	takeSnapshot(): DocSnapshot {
		return takeSnapshot(this.host.getDoc());
	}

	/** Open a transaction, mutations dispatched while one is open
	 * coalesce into ONE history entry (peer drag, typing burst).
	 * `label` is the undo-tooltip name. Nested begins use the
	 * outermost label. */
	begin(label = "Edit"): void {
		if (this.#txnDepth === 0) {
			this.#txnSnapshot = this.takeSnapshot();
			this.#txnLabel = label;
			this.clearTxnStage();
		}
		this.#txnDepth += 1;
	}

	end(): void {
		if (this.#txnDepth === 0) return;
		this.#txnDepth -= 1;
		if (this.#txnDepth === 0 && this.#txnSnapshot) {
			// One layout solve and one world rebuild for the whole gesture,
			// Unpin all and multi-delete pay them once, not per member.
			this.flushTxnStage();
			// Skip the push when the transaction was a no-op (focused but
			// didn't type, dragged but returned to start position).
			const after = this.takeSnapshot();
			if (!snapshotsEqual(this.#txnSnapshot, after)) {
				this.#history.recordBefore(this.#txnSnapshot, this.#txnLabel);
				this.host.notify();
			}
			this.#txnSnapshot = null;
			this.#txnLabel = "";
			this.clearTxnStage();
		}
	}

	/** Recompute layout, deferred while a transaction is open. */
	requestLayoutRecompute(): void {
		if (this.#txnDepth > 0) {
			this.#txnLayoutDirty = true;
			return;
		}
		this.host.layout.recompute();
	}

	/**
	 * Authoring seek: rebuild the world at `t`. Inside a transaction the
	 * seek (and a layout recompute, because deletes otherwise leave
	 * stale keyframes) waits for `endTransaction`.
	 */
	authoringSeek(t: number): void {
		if (this.#txnDepth > 0) {
			this.#txnSeekT = t;
			this.#txnLayoutDirty = true;
			// Defer the rematerialize (N cold seeks → one at close) but still
			// wake world subscribers: timeline paint and scrub fields follow
			// the live doc mid-gesture the way placement does. `docVersion`
			// stays quiet until `endTransaction`.
			this.host.notify(false);
			return;
		}
		this.host.seekWorld(t);
		this.host.notify();
	}

	/**
	 * Remember a playhead rebuild for `endTransaction` without waking
	 * subscribers. Unpin inside an open gesture uses this: the layout is
	 * already marked dirty, and the close is the notify that counts.
	 */
	deferSeek(t: number): void {
		this.#txnSeekT = t;
	}

	/**
	 * Imperative seek needs a current layout if pin/topology writes
	 * deferred a recompute, and it cancels a pending authoring seek.
	 */
	flushLayoutForSeek(): void {
		if (this.#txnLayoutDirty) {
			this.host.layout.recompute();
			this.#txnLayoutDirty = false;
		}
		this.#txnSeekT = null;
	}

	flushTxnStage(): void {
		if (this.#txnLayoutDirty) {
			this.host.layout.recompute();
			this.#txnLayoutDirty = false;
		}
		if (this.#txnSeekT !== null) {
			const t = this.#txnSeekT;
			this.#txnSeekT = null;
			this.host.seekWorld(t);
		}
	}

	clearTxnStage(): void {
		this.#txnLayoutDirty = false;
		this.#txnSeekT = null;
	}

	applySnapshot(snap: DocSnapshot): void {
		restoreSnapshotInto(this.host.getDoc(), snap);
		this.afterDocReplaced();
	}

	recordIfClosed(snapshotBefore: DocSnapshot, label: string): void {
		if (this.#txnDepth === 0) {
			this.#history.recordBefore(snapshotBefore, label);
		}
	}

	undo(): void {
		const previous = this.#history.undo(this.takeSnapshot());
		if (previous) this.applySnapshot(previous.snapshot);
	}

	redo(): void {
		const next = this.#history.redo(this.takeSnapshot());
		if (next) this.applySnapshot(next.snapshot);
	}

	/**
	 * Walk the whole history back in one move, keeping it.
	 *
	 * "Undo all": the same place pressing undo until it stops would
	 * reach, and reversible in the same way. Every step crosses to the
	 * redo side, so the author can walk forward again. That is the whole
	 * difference from `discardAllEdits` below, and it is why both exist.
	 * Where it stops is what the HISTORY remembers, which is not always
	 * the document the buffer was built from: the stack holds a hundred
	 * entries, and each one restores the fields `DocSnapshot` carries
	 * rather than the whole document.
	 */
	undoAll(): void {
		const oldest = this.#history.undoAll(this.takeSnapshot());
		if (oldest) this.applySnapshot(oldest.snapshot);
	}

	/**
	 * Throw away every edit: the document becomes the one this engine
	 * was built from, and the history that got it here goes with it.
	 *
	 * The other half of the pair, and the strong one. It goes back to
	 * the WHOLE document however long ago it arrived, so it reaches
	 * past both of the limits `undoAll` runs into. The price is that it
	 * cannot be taken back, which is why it is not a `BuilderIntent`:
	 * an intent is an edit to the composition and every one of them is
	 * a step you can undo, a rule `undo-coverage.test.ts` holds over
	 * the whole union, one case per kind, refusing to compile when a
	 * new kind arrives without one. This is not an edit. It is a reset
	 * of the buffer, the same act as the buffer being built from a
	 * different source, which throws the same work away and empties
	 * Undo for the same reason: the steps in it lead back through a
	 * document that is no longer the one in front of you. status-allow: lifecycle transition
	 *
	 * Offered on `hasHistory` rather than on `canUndo`, which is what
	 * its neighbour `undoAll` reads. A reader sitting at the beginning
	 * of the history has nothing left to undo and still has a history,
	 * and this is the command that gets rid of one.
	 */
	discardAllEdits(): void {
		if (!this.hasHistory) return;
		resetDocumentTo(this.host.getDoc(), this.host.source());
		this.#history.clear();
		this.afterDocReplaced();
	}

	/** Bring the derived state back in step after the document has been
	 *  written wholesale, by an undo, a redo, a rollback, or a
	 *  discard.
	 *
	 *  The clock's upper bound follows `doc.duration` everywhere the doc
	 *  grows (`growDurationToFit` / `commitEntityAuthoring`), so a write
	 *  that shrinks it back must keep the pair in step or the transport
	 *  plays past the timeline's end. The layout re-derives every era whose
	 *  problem the replacement changed, keeping the arrangement it holds for the
	 *  eras the replacement left alone: an era's problem is what the solver was
	 *  asked, so an era the edit did not reach was asked the same question and has
	 *  the same answer. The seek rebuilds the world at the playhead and notifies.
	 */
	afterDocReplaced(): void {
		this.host.clock.setDuration(this.host.getDoc().duration);
		this.host.layout.recompute();
		this.host.seekWorld(this.host.clock.t);
		this.host.notify();
	}
}
