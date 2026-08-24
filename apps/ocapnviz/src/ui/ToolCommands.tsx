/**
 * The commands in the Tools pane — the row of text buttons under the
 * tool strip, and the one button face they share.
 *
 * A tool is a mode you sit in and a command is an act that runs once,
 * so a command is not another icon square in the strip: a sixth square
 * would read as a sixth tool. They are text buttons, because none of
 * these three has a picture a reader would recognize, and they share a
 * wrapping row for the same reason the tool strip above them does —
 * they fit across the pane at its usual width, and a pane dragged down
 * to its 200px floor wraps them rather than shaving their labels.
 * They wear the bordered button face their neighbours in this section
 * wear rather than the top bar's ghost face, because in a pane of
 * labels and swatches a borderless control reads as a caption.
 *
 * All three live here rather than in a file each, so a fourth extends
 * this home instead of re-spelling it nearby, and so the pane's whole
 * command vocabulary is one read.
 *
 * Build only, because a command mutates the document and Build is the
 * mode that holds mutation authority — the rule `toolsForMode` already
 * states for the authoring tools. Deciding it in the shared button
 * rather than at each call site means a command added later cannot
 * forget it.
 *
 * Nothing to do leaves a button inert with a tooltip saying so, rather
 * than hiding it: a reader who has never pinned a node or made an edit
 * still learns the command is there, and the row does not reflow when
 * the first one lands. `whenInert` is required for that reason. A
 * command cannot ship an inert state with nothing to explain it, which
 * is the shape a refusal takes when it is allowed to be silent.
 *
 * `confirm` is where the two whole-composition commands part company,
 * and it is the app's existing rule rather than a new one: switching
 * source asks before it discards a Build undo stack, and Record asks
 * before it replaces the buffer. An act a reader can take back does
 * not ask, because a dialog in front of an undoable act buys nothing
 * and teaches the habit of clicking through the dialogs that guard the
 * acts that are not.
 */

import { useMemo } from "react";
import type React from "react";
import type { Engine } from "../engine/engine.ts";
import { authoredPins } from "../engine/event-helpers.ts";
import { clearAllPins, discardAllEdits, undoAllWithSelection } from "../builder/selection-history.ts";
import type { AppMode } from "../state/app-state.ts";
import type { SelectionAction } from "../interactions/types.ts";
import { useDocVersion } from "./useDocVersion.ts";
import { type ConfirmRequest, requestConfirm } from "./confirm.ts";
import { SIZE, SPACE } from "./tokens.ts";

/** The row the commands sit in. Renders nothing outside Build, so the
 *  section closes up rather than leaving a gap under the tool strip. */
export function ToolCommandRow(
	{ mode, children }: { mode: AppMode; children: React.ReactNode },
) {
	if (mode !== "build") return null;
	return <div style={commandRow}>{children}</div>;
}

export function ToolCommandButton(
	{ mode, label, ready, whenReady, whenInert, confirm, onRun }: {
		mode: AppMode;
		/** What the button says: an imperative verb and what it acts on. */
		label: string;
		/** Whether the command has anything to do right now. */
		ready: boolean;
		/** Tooltip while it does — what running it would change. */
		whenReady: string;
		/** Tooltip while it does not — why, in a sentence. */
		whenInert: string;
		/** Asked before running, for a command that cannot be taken back.
		 *  Absent means the act is recoverable and asks nothing. */
		confirm?: ConfirmRequest;
		onRun: () => void;
	},
) {
	if (mode !== "build") return null;
	return (
		<button
			type="button"
			className="ocv-btn"
			// Asking is a dialog now rather than the browser's blocking one, so the
			// click runs in two parts with the reader's answer in between. A command
			// with nothing to ask still runs before the first await, so nothing about
			// the recoverable ones waits on a turn of the event loop.
			onClick={async () => {
				if (confirm !== undefined && !await requestConfirm(confirm)) {
					return;
				}
				onRun();
			}}
			disabled={!ready}
			title={ready ? whenReady : whenInert}
			style={buttonStyle}
		>
			{label}
		</button>
	);
}

const commandRow = {
	display: "flex",
	flexWrap: "wrap",
	gap: SPACE.xs,
} satisfies React.CSSProperties;

// Each button takes an equal share of the row and may grow past its
// label, but never shrinks below it — which is what makes the row wrap
// at a narrow pane instead of clipping "Discard all" to "Discard a…".
const buttonStyle = {
	flex: "1 1 auto",
	fontSize: SIZE.base,
} satisfies React.CSSProperties;

/**
 * Hand every pinned node on the stage back to automatic placement.
 *
 * The Inspector position row's ✕ swept across the composition: same
 * verb, same two kinds of pin (a peer's authored position and a
 * session end's), one undo step. The sweep is `clearAllPins` in
 * `builder/selection-history.ts`; this is the affordance.
 */
export function UnpinAllButton(
	{ engine, mode }: { engine: Engine; mode: AppMode },
) {
	// Subscribe so the inert state tracks the document: pinning the
	// first node has to wake the button, and the sweep has to put it
	// back to sleep.
	const version = useDocVersion(engine);
	const pinned = useMemo(
		() => authoredPins(engine.doc).size,
		[engine, version],
	);
	return (
		<ToolCommandButton
			mode={mode}
			label="Unpin all"
			ready={pinned > 0}
			whenReady="Return every pinned peer and session end to automatic placement"
			whenInert="Nothing is pinned. Every node is already placed automatically."
			onRun={() => clearAllPins(engine)}
		/>
	);
}

/**
 * Walk the whole history back — undo, held down.
 *
 * The recoverable one of the two whole-composition commands: every
 * step crosses to the redo side, so the author can walk forward again,
 * and it asks nothing before it runs. What it reaches is where the
 * history ends, which is the document the buffer was built from only
 * while the stack has not overflowed. `DiscardAllButton` below is the
 * one that promises the document itself.
 */
export function UndoAllButton(
	{ engine, mode, dispatchSelection }: {
		engine: Engine;
		mode: AppMode;
		dispatchSelection: React.Dispatch<SelectionAction>;
	},
) {
	// Whether any step is left to walk back, so it goes inert once the
	// reader reaches the beginning — where `DiscardAllButton` is still
	// live, because the history it would throw away is still there.
	const version = useDocVersion(engine);
	const steps = useMemo(() => engine.canUndo, [engine, version]);
	return (
		<ToolCommandButton
			mode={mode}
			label="Undo all"
			ready={steps}
			whenReady="Take every step back, as far as the history goes. Redo walks forward again."
			whenInert="You are at the beginning of the history."
			onRun={() => undoAllWithSelection(engine, dispatchSelection)}
		/>
	);
}

/**
 * Put the composition back to the document the buffer was built from.
 *
 * The strong half of the pair. Where `UndoAllButton` walks the history
 * back and keeps it, this goes to the whole document as it arrived —
 * past both of the limits the history runs into, since the stack holds
 * a hundred entries and each restores only the fields a `DocSnapshot`
 * carries — and throws the history away with the edits. That is what
 * it costs, so this is the one command in Build that asks before it
 * runs, exactly as switching source does for the same loss.
 */
export function DiscardAllButton(
	{ engine, mode, dispatchSelection }: {
		engine: Engine;
		mode: AppMode;
		dispatchSelection: React.Dispatch<SelectionAction>;
	},
) {
	// Whether there is a history at all, which is not the question
	// `UndoAllButton` asks. At the beginning of the history there is
	// nothing left to undo and there is still a history, and this is the
	// command that gets rid of one.
	const version = useDocVersion(engine);
	const anyHistory = useMemo(() => engine.hasHistory, [engine, version]);
	return (
		<ToolCommandButton
			mode={mode}
			label="Discard all"
			ready={anyHistory}
			whenReady="Go back to the document this was built from, and clear the history. This cannot be undone."
			whenInert="There is no history to discard."
			confirm={DISCARD_CONFIRM}
			onRun={() => discardAllEdits(engine, dispatchSelection)}
		/>
	);
}

export const DISCARD_CONFIRM: ConfirmRequest = {
	title: "Discard every edit?",
	detail: "This puts the composition back to the document it was built from " +
		"and clears the history, so it cannot be undone.",
	confirmLabel: "Discard all",
};
