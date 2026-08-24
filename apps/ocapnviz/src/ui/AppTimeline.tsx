/**
 * The app's timeline bar — the bottom pane, its seam, and the panel
 * it hosts.
 *
 * TimelinePanel owns the canvases and the view reducer. This module
 * owns how the app drives that panel: playback, visibility cycling,
 * row reorder, live capture chrome, and the drag that sizes the pane.
 * The per-entity eyeball uses the same `nextVisCycleStep` the
 * category and all-rows eyeballs already used, so three clicks on
 * one row cannot invent a fourth mode.
 */

import type { Engine } from "../engine/engine.ts";
import { observationsOf } from "../engine/temporal/recording-access.ts";
import { nextVisCycleStep } from "../engine/visibility.ts";
import { asOneEdit } from "../builder/as-one-edit.ts";
import { type EntityRefKey, type SelectMode, type SurfaceGestureCtx } from "../interactions/types.ts";
import type { AppMode, LayoutSizes } from "../state/app-state.ts";
import type { StageSelection } from "../render/types.ts";
import { bottomBar } from "./app-shell.ts";
import type { EditorBindings } from "./inspector/bindings.ts";
import { ResizeHandle } from "./ResizeHandle.tsx";
import { TimelinePanel } from "./Timeline/TimelinePanel.tsx";

export function AppTimeline({
	engine,
	bufferEngine,
	mode,
	editor,
	selection,
	anchor,
	onSelectEvent,
	focusedEventId,
	onFocusEvent,
	onEditSelection,
	gestureCtx,
	liveConnected,
	liveRecording,
	onStartRecord,
	onStopRecord,
	onDiscardRecording,
	timelineLayoutResetKey,
	onFitPanelHeight,
	onResize,
	onIntrinsicHeightChange,
	onMinHeightChange,
	timelineMinHeight,
	autoSizeTimeline,
	onSetAutoSizeTimeline,
	onPlayPause,
	onRestart,
	onSetSpeed,
	onSeek,
	onScrubStart,
	onScrubEnd,
}: {
	engine: Engine;
	bufferEngine: Engine | null;
	mode: AppMode;
	editor: EditorBindings | undefined;
	selection: ReadonlySet<EntityRefKey>;
	anchor: StageSelection;
	onSelectEvent: (sel: StageSelection) => void;
	focusedEventId: string | null;
	onFocusEvent: (id: string | null) => void;
	onEditSelection: (
		entities: ReadonlySet<EntityRefKey>,
		mode: SelectMode,
	) => void;
	gestureCtx: SurfaceGestureCtx;
	liveConnected: boolean;
	liveRecording: boolean;
	onStartRecord: () => void;
	onStopRecord: () => void;
	onDiscardRecording: () => void;
	timelineLayoutResetKey: number;
	onFitPanelHeight: () => void;
	onResize: (
		updater: Partial<LayoutSizes> | ((s: LayoutSizes) => LayoutSizes),
	) => void;
	onIntrinsicHeightChange: (px: number) => void;
	onMinHeightChange: (px: number) => void;
	timelineMinHeight: number;
	autoSizeTimeline: boolean;
	onSetAutoSizeTimeline: (value: boolean) => void;
	onPlayPause: () => void;
	onRestart: () => void;
	onSetSpeed: (speed: number) => void;
	onSeek: (t: number) => void;
	onScrubStart: () => void;
	onScrubEnd: () => void;
}) {
	const build = mode === "build";
	return (
		<div style={bottomBar}>
			<ResizeHandle
				axis="y"
				edge="top"
				label="Timeline panel height"
				title="Drag or use the up and down arrow keys to resize. Double-click or press Enter to fit the panel to its content."
				onDoubleClick={onFitPanelHeight}
				onDelta={(d) => {
					// `useResizeHandle` only emits non-zero deltas, so
					// any call here means the user actually moved the
					// handle — flip auto-size off so the pane stays at
					// the manually-chosen height instead of snapping
					// back to intrinsic on the next lane expand.
					if (autoSizeTimeline) onSetAutoSizeTimeline(false);
					// Drag UP = pane grows (pointer y delta positive
					// going down, so subtract). Drag DOWN shrinks the
					// pane; when intrinsic > pane the lanes region
					// overflows with internal scroll (handled in the
					// Scrubber). Hard floor is the collapsed-fit height
					// TimelinePanel publishes — expand a category and
					// you can drag between that and the live intrinsic;
					// you cannot drag below collapsed-fit.
					onResize((s) => ({
						...s,
						bottomPaneHeight: Math.max(
							timelineMinHeight,
							s.bottomPaneHeight - d,
						),
					}));
				}}
			/>
			<TimelinePanel
				key={timelineLayoutResetKey}
				engine={engine}
				onPlayPause={onPlayPause}
				onRestart={onRestart}
				onSetSpeed={onSetSpeed}
				onSeek={onSeek}
				onScrubStart={onScrubStart}
				onScrubEnd={onScrubEnd}
				selection={anchor}
				onSelectEvent={onSelectEvent}
				focusedEventId={focusedEventId}
				onFocusEvent={onFocusEvent}
				onMoveEvent={build ? editor?.onMoveEvent : undefined}
				onMoveEntitySpan={build ? editor?.onMoveEntitySpan : undefined}
				beginEdit={build ? editor?.beginEdit : undefined}
				endEdit={build ? editor?.endEdit : undefined}
				cycleRowVisibility={(category, entityId) => {
					// Per-entity eyeball cycle: visible → label-hidden →
					// body-hidden → both-hidden → visible. The order
					// starts with the most reversible / lowest-impact
					// hide (just the label) so the first click on a
					// pristine row is gentle.
					//
					// Available in every mode: visibility is a
					// display-state concern (what's painted on the
					// stage), not a doc-content concern, so Play and
					// Live should let the user filter too.
					engine.dispatch({
						kind: "set-row-vis-mode",
						category,
						id: entityId,
						mode: nextVisCycleStep(
							engine.rowVisMode(category, entityId),
						),
					});
				}}
				cycleCategoryVisibility={(category) => {
					// Category eyeball: same 4-mode cycle as the per-
					// entity eyeball (visible → label → body → both →
					// visible) — applies uniformly to every entity in
					// the category. Mixed state collapses to "visible"
					// first so the user gets a clean-slate reset, and
					// the next click starts the deterministic cycle.
					engine.dispatch({
						kind: "set-category-vis-mode",
						category,
						mode: nextVisCycleStep(
							engine.categoryVisMode(category),
						),
					});
				}}
				cycleAllVisibility={() => {
					// Master "all rows" eyeball — same cycle as the
					// per-category one, applied across every category.
					// Same lossy / opt-in semantics: the user accepts
					// wiping per-entity overrides for the convenience.
					engine.dispatch({
						kind: "set-all-vis-mode",
						mode: nextVisCycleStep(engine.allVisMode()),
					});
				}}
				commitRowReorder={build
					? (category, order) =>
						asOneEdit(engine, "Reorder timeline rows", () => {
							engine.dispatch({
								kind: "reorder-row",
								category,
								order,
							});
						})
					: undefined}
				selectionSet={selection}
				onEditSelection={onEditSelection}
				gestureCtx={gestureCtx}
				onIntrinsicHeightChange={onIntrinsicHeightChange}
				onMinHeightChange={onMinHeightChange}
				autoSizeTimeline={autoSizeTimeline}
				onSetAutoSizeTimeline={onSetAutoSizeTimeline}
				disabled={mode === "live"}
				live={mode === "live"
					? {
						connected: liveConnected,
						recording: liveRecording,
						bufferHasContent: (bufferEngine ? observationsOf(bufferEngine.doc).length : 0) >
							0,
						onStartRecord,
						onStopRecord,
						onDiscardRecording,
					}
					: undefined}
			/>
		</div>
	);
}
