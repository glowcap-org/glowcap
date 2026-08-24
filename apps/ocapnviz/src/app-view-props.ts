/** Inputs published by the app state owner to the visual shell. */

import type { Dispatch } from "react";
import type { Engine } from "./engine/engine.ts";
import type { EntityRefKey, ModifierSet, SelectionAction } from "./interactions/types.ts";
import type { SelectMode, StageSelection, StageVisibility } from "./render/types.ts";
import type { Theme } from "./ui/tokens.ts";
import type { AppAction, AppMode, AppState, BufferSourceInfo, LayoutSizes } from "./state/app-state.ts";
import type { ShortcutSink } from "./state/hooks.ts";

export type AppViewProps = {
	engine: Engine;
	/** Source-of-truth doc engine. Distinct from `engine` (which
	 * routes to the LIVE engine while in Live mode). Save targets
	 * this; the discard-warning gates on this. */
	bufferEngine: Engine | null;
	/** What the buffer is (fixture / file / recording + edited) —
	 * displayed by the Source panel, derived up in App. */
	sourceInfo: BufferSourceInfo | null;
	/** Explicit source switch: drop the opened file, recording, and
	 * edited fork so the picked fixture actually becomes the buffer. */
	onClearSourceOverrides: () => void;
	/** Mode switch with the one-buffer contract: leaving Build with
	 * edits captures the working doc before the flip. */
	onModeChange: (mode: AppMode) => void;
	dispatch: Dispatch<AppAction>;
	state: AppState;
	liveConnected: boolean;
	/** At least one record has arrived on this Live dial. */
	liveObserved: boolean;
	/** True while the Record window is open (engine mounted). */
	liveRecording: boolean;
	onStartRecord: () => void;
	onStopRecord: () => void;
	onDiscardRecording: () => void;
	theme: Theme;
	onToggleTheme: () => void;
	sizes: LayoutSizes;
	/** `max(sizes.bottomPaneHeight, BOTTOM_PANE_MIN)` — the
	 *  visible pane height. Decoupled from `timelineIntrinsic`;
	 *  overflow scrolls inside the lanes region. */
	bottomPaneHeight: number;
	/** Snap the pane to the current timeline intrinsic height.
	 *  Wired to the resize handle's double-click and to a button
	 *  in the Timeline control row. */
	onFitPanelHeight: () => void;
	onResize: (
		updater: Partial<LayoutSizes> | ((s: LayoutSizes) => LayoutSizes),
	) => void;
	onResetLayout: () => void;
	/** Remount key for TimelinePanel — bumped by Reset Layout after
	 *  clearing timeline-view storage so expansions/gutter re-init. */
	timelineLayoutResetKey: number;
	visibility: StageVisibility;
	/** The `space-pan` claim: the key is down. Reads that speak
	 *  about the key take this — the tip, the gesture context the
	 *  resolver sees, the click gating. */
	spaceHeld: boolean;
	/** Where this view publishes its shortcut bindings. App owns the
	 *  one keyboard listener; the handlers a shortcut invokes are
	 *  defined down here, so they are published rather than passed
	 *  up. */
	shortcuts: ShortcutSink;
	/** Every modifier the global keyboard state watches — drives
	 *  modifier-preview cursors ("copy" for add, "no-drop" for
	 *  remove) on both empty stage and interactive sprites, and the
	 *  Timeline's own shift/alt reads. */
	modifiers: ModifierSet;
	onNew: () => void;
	onOpen: () => void;
	onTimelineIntrinsicChange: (px: number) => void;
	/** TimelinePanel publishes its collapsed-fit height here (chrome
	 *  + every category collapsed) so the drag clamp tracks that
	 *  floor rather than the live expansion. */
	onTimelineMinHeightChange: (px: number) => void;
	/** Floor used by the drag clamp — the collapsed-fit panel
	 *  height TimelinePanel publishes (`onMinHeightChange`). Fit /
	 *  auto-size use the live intrinsic separately. */
	timelineMinHeight: number;
	/** THE selection — the set of entities (peers, sessions,
	 * messages) the user has selected. Single source of truth
	 * across Stage, Timeline, and Inspector. Stage paints halos
	 * from it; Scrubber highlights events whose entityRef key is
	 * in this set; MultiSummary in the Inspector reads it for
	 * bulk-edit affordances. Group ops (delete, drag, nudge)
	 * iterate the events of every entity in this set. */
	selection: ReadonlySet<EntityRefKey>;
	/** Anchor — the "Inspector follow" entity (and range-extension
	 * pivot). StageSelection-shaped (`EntityRef | null`); consumers
	 * that previously read `state.selection` read this instead. */
	anchor: StageSelection;
	/** Raw selection-store dispatch — used by AppView for cases
	 * that need direct access (e.g. clearing on scenario change,
	 * tool-flow side effects). Higher-level helpers (`onSetSelection`,
	 * `onClearStoreSelection`) wrap the common verbs. */
	dispatchSelection: Dispatch<SelectionAction>;
	/** Stage rubber-band → selection-store bridge. App owns the
	 * dispatch; this is the wire that carries the committed set
	 * back. */
	onRubberBandCommit: (
		entities: ReadonlySet<EntityRefKey>,
		mode: "replace" | "add" | "remove",
	) => void;
	/** Clears the selection-store's multi + time + entity slots.
	 * AppView pairs this with its existing `state.selection` clear
	 * inside `handleDeselect` so Escape is one verb. */
	onClearStoreSelection: () => void;
	/** Stage entity-click → store bridge. `opts.mode` mirrors the
	 *  marquee commit modes: replace / add / remove. Missing = replace. */
	onStoreSelect: (
		sel: StageSelection,
		opts?: { mode?: SelectMode },
	) => void;
	/** Called after a successful Inspector rename. Caller (App)
	 *  re-anchors both selection subsystems (`state.selection` +
	 *  `storeSelection`) so the Inspector keeps tracking the
	 *  entity post-rename. */
	onEntityRenamed: (
		kind: "peer" | "session" | "message",
		oldId: string,
		newId: string,
	) => void;
	/** Replace the store's selection set. Used post-paste / -duplicate
	 *  so the user sees the newly minted entities highlighted as the
	 *  current selection (Cmd-V / Cmd-D feedback), by the Timeline
	 *  surface for Cmd-A / Escape, and by the Inspector's group panel
	 *  to narrow a mixed selection down to one kind. */
	onSetSelection: (entities: ReadonlySet<EntityRefKey>) => void;
	/** Timeline gesture → the one select-mode interpreter
	 * (`selectionActionFor`, timeline empty-space semantics). */
	onTimelineEditSelection: (
		entities: ReadonlySet<EntityRefKey>,
		mode: SelectMode,
	) => void;
};
