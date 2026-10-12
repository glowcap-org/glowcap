/**
 * Top-bar controls, small icon-button clusters that live in the
 * App header in build mode. Each cluster is conceptually its own
 * widget. Grouped in one file because they share a visual idiom
 * (ghost-style icon button) and are all wired to engine actions.
 */

import { Engine } from "../engine/engine.ts";
import type { AppMode } from "../state/app-state.ts";
import { useDocVersion } from "./useDocVersion.ts";
import { FolderGlyph, NewDocGlyph, RedoGlyph, SaveGlyph, UndoGlyph } from "./glyphs.tsx";
import { segmentCellClass } from "./tokens.ts";

/**
 * Why a control refuses while a capture is in flight.
 *
 * Leaving Live drops the feed, and the capture cannot outlive the
 * connection it is recording, so an act that leaves Live ends the
 * recording. Rather than end it as a side effect of a click that
 * promised something else, those acts refuse and name the two controls
 * that DO end a recording, which are sitting in the same bar.
 *
 * Stop is the only control that claims a capture, Discard is the only
 * control that throws one away. Mode switching owns neither effect.
 */
function recordingHolds(act: string): string {
	return `Stop the recording before ${act} — Stop claims the capture, ` +
		`Discard throws it away.`;
}

/** Top-bar Live / Play / Build segmented control. Three siblings
 * operating on one shared document buffer, Live taps a feed,
 * Play replays the buffer, Build edits it.
 *
 * While a capture is running the two cells that would leave Live are
 * inert and say why. `recording` is passed in rather than inferred
 * from the mode and the engine, so this control and every other one
 * that has to respect a capture in flight are reading the same fact. */
export function ModeToggle(
	{ mode, recording, onChange }: {
		mode: AppMode;
		/** A capture is in flight. */
		recording: boolean;
		onChange: (mode: AppMode) => void;
	},
) {
	const options: { id: AppMode; label: string }[] = [
		{ id: "live", label: "Live" },
		{ id: "play", label: "Play" },
		{ id: "build", label: "Build" },
	];
	return (
		<div className="ocv-segment" role="radiogroup" aria-label="UI mode">
			{options.map((opt) => {
				const held = recording && opt.id !== "live";
				return (
					<button
						key={opt.id}
						type="button"
						role="radio"
						aria-checked={mode === opt.id}
						className={segmentCellClass(mode === opt.id)}
						disabled={held}
						{...(held ? { title: recordingHolds("leaving Live") } : {})}
						onClick={() => onChange(opt.id)}
					>
						{opt.label}
					</button>
				);
			})}
		</div>
	);
}

/** Top-bar undo / redo pair (build mode only). Subscribes via
 * `useDocVersion` so the disabled state tracks the history stack without
 * waking on every playback frame. Tooltips carry the action name
 * ("Undo Add peer") matching Photoshop / Figma convention.
 *
 * The engine is here to be read, never to be commanded: taking history
 * back also walks the selection back onto what the document then holds,
 * and this button is one of two surfaces that ask for it. Both ask
 * through the host, which is where that pair of steps lives. */
export function UndoRedoControls(
	{ engine, onUndo, onRedo }: {
		engine: Engine;
		onUndo: () => void;
		onRedo: () => void;
	},
) {
	useDocVersion(engine);
	const undoLabel = engine.nextUndoLabel ? `Undo ${engine.nextUndoLabel} (Cmd/Ctrl+Z)` : "Undo (Cmd/Ctrl+Z)";
	const redoLabel = engine.nextRedoLabel
		? `Redo ${engine.nextRedoLabel} (Cmd/Ctrl+Shift+Z)`
		: "Redo (Cmd/Ctrl+Shift+Z)";
	return (
		<>
			<button
				type="button"
				className="ocv-btn is-ghost is-icon"
				onClick={onUndo}
				disabled={!engine.canUndo}
				title={undoLabel}
				aria-label={undoLabel}
			>
				<UndoGlyph />
			</button>
			<button
				type="button"
				className="ocv-btn is-ghost is-icon"
				onClick={onRedo}
				disabled={!engine.canRedo}
				title={redoLabel}
				aria-label={redoLabel}
			>
				<RedoGlyph />
			</button>
		</>
	);
}

/** Top-bar New / Save / Open trio. Mirrors the ghost styling of
 * `UndoRedoControls` so the icon buttons read as one author-tools cluster.
 *
 * New sits first because that is the order the three are reached for, and it is
 * disabled during a capture for Open's reason: both replace the buffer, and
 * replacing it mid-capture would end a recording without saying so. */
export function SaveOpenControls(
	{ recording, onNew, onSave, onOpen }: {
		/** A capture is in flight. */
		recording: boolean;
		onNew: () => void;
		onSave: () => void;
		onOpen: () => void;
	},
) {
	return (
		<>
			<button
				type="button"
				className="ocv-btn is-ghost is-icon"
				onClick={onNew}
				disabled={recording}
				title={recording ? recordingHolds("starting a new document") : "New — start an empty document in Build"}
				aria-label="New"
			>
				<NewDocGlyph />
			</button>
			<button
				type="button"
				className="ocv-btn is-ghost is-icon"
				onClick={onSave}
				title="Save (Cmd/Ctrl+S) — download this timeline as a JSON file"
				aria-label="Save"
			>
				<SaveGlyph />
			</button>
			{
				/* Open is the other way out of Live: it replaces the buffer and
          lands in Play, so during a capture it would end one without
          saying so. Save stays live throughout. It reads the document
          and disturbs nothing. */
			}
			<button
				type="button"
				className="ocv-btn is-ghost is-icon"
				onClick={onOpen}
				disabled={recording}
				title={recording
					? recordingHolds("opening a file")
					: "Open (Cmd/Ctrl+O) — load a timeline from a JSON file"}
				aria-label="Open"
			>
				<FolderGlyph />
			</button>
		</>
	);
}
