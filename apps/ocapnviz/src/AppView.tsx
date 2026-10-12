/**
 * The ocapnviz shell: header, rails, stage, and timeline.
 *
 * `App` owns the buffer, the mode, and which engine is live. This
 * module owns the view of that engine. The commands the chrome
 * publishes, and the panes those commands fill.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { docTitle } from "./engine/timeline.ts";
import { allEntityKeys } from "./interactions/selection-store.ts";
import { parseEntityKey, type SurfaceGestureCtx } from "./interactions/types.ts";
import { DEFAULT_REFERENCE_SECTION, ReferenceDialog, type ReferenceSectionId } from "./ui/reference/Reference.tsx";
import { inspectorView } from "./ui/Sidebar.tsx";
import { bindBuilderEditor } from "./ui/inspector/bind-editor.ts";
import { deletionPhrase } from "./ui/inspector/selection-summary.ts";
import { CURRENT_SOURCE_OPTION } from "./ui/SourcePicker.tsx";
import { ToolDraftStore } from "./ui/ToolOptionsBar.tsx";
import { requestConfirm } from "./ui/confirm.ts";
import type { BuilderTool } from "./state/app-state.ts";
import { useShortcutBindings } from "./state/hooks.ts";
import { useSelectionClipboard } from "./state/use-selection-clipboard.ts";
import { asOneEdit } from "./builder/as-one-edit.ts";
import { downloadDocAsJson } from "./builder/document-io.ts";
import { nudgeSelection, redoWithSelection, undoWithSelection } from "./builder/selection-history.ts";
import { useStageBuildGestures } from "./builder/use-stage-build-gestures.ts";
import { appShellStyle } from "./ui/app-shell.ts";
import { AppHeader } from "./ui/AppHeader.tsx";
import { AppTimeline } from "./ui/AppTimeline.tsx";
import { InspectorRail } from "./ui/InspectorRail.tsx";
import { LeftRail } from "./ui/LeftRail.tsx";
import { StagePane } from "./ui/StagePane.tsx";
import type { AppViewProps } from "./app-view-props.ts";

export function AppView({
	engine,
	bufferEngine,
	sourceInfo,
	onClearSourceOverrides,
	onModeChange,
	dispatch,
	state,
	liveConnected,
	liveObserved,
	liveRecording,
	onStartRecord,
	onStopRecord,
	onDiscardRecording,
	theme,
	onToggleTheme,
	sizes,
	bottomPaneHeight,
	onFitPanelHeight,
	onResize,
	onResetLayout,
	timelineLayoutResetKey,
	visibility,
	onTimelineIntrinsicChange,
	onTimelineMinHeightChange,
	timelineMinHeight,
	spaceHeld,
	shortcuts,
	modifiers,
	onNew,
	onOpen,
	selection,
	anchor,
	dispatchSelection,
	onRubberBandCommit,
	onClearStoreSelection,
	onStoreSelect,
	onEntityRenamed,
	onSetSelection,
	onTimelineEditSelection,
}: AppViewProps) {
	// NOT subscribing to the clock here, that lives
	// in `TimelinePanel` where the value is consumed. App-level
	// reconciliation runs at human-interaction rate, not 60 Hz.

	const handleScenarioChange = useCallback(
		async (event: React.ChangeEvent<HTMLSelectElement>) => {
			const nextId = event.target.value;
			// The synthetic "current source" row is a label, not a
			// choice, re-selecting it changes nothing.
			if (nextId === CURRENT_SOURCE_OPTION) return;
			// Held now, before anything is awaited. `event.target` survives the
			// handler where `currentTarget` does not, and the picker below has to be
			// put back by hand: it is controlled, but a cancel changes no state, so
			// there is no re-render for React to re-sync its value on.
			const picker = event.target;
			// Switching source discards whatever the buffer holds, a
			// Build undo stack, an edited fork, an opened file, or a
			// recording. Ask when that loses user-made state; put the
			// picker back if they cancel.
			const discardsWork = (state.mode === "build" && engine?.canUndo) ||
				sourceInfo?.edited || sourceInfo?.kind !== "builtin";
			if (
				discardsWork &&
				!await requestConfirm({
					title: "Discard unsaved changes?",
					detail: "Switching source replaces what is loaded, so anything unsaved " +
						"in it goes.",
					confirmLabel: "Switch source",
				})
			) {
				picker.value = sourceInfo?.kind !== "builtin" ? CURRENT_SOURCE_OPTION : state.scenarioId;
				return;
			}
			// Picking a fixture explicitly clears anything that would
			// shadow it (opened file, recording, edited fork).
			onClearSourceOverrides();
			dispatch({ type: "select-scenario", id: nextId });
			// The new doc has a new entity universe. Any prior anchor /
			// selection is stale, clear the store so halos don't paint
			// for ids that no longer exist.
			onClearStoreSelection();
		},
		[
			dispatch,
			engine,
			state.mode,
			state.scenarioId,
			sourceInfo,
			onClearSourceOverrides,
			onClearStoreSelection,
		],
	);

	const handlePlayPause = useCallback(
		() => engine.enqueue({ kind: "toggle" }),
		[engine],
	);
	const handleRestart = useCallback(
		() => engine.enqueue({ kind: "restart" }),
		[engine],
	);
	const handleSetSpeed = useCallback(
		(speed: number) => engine.enqueue({ kind: "setSpeed", speed }),
		[engine],
	);
	const handleSeek = useCallback(
		(t: number) => engine.enqueue({ kind: "seekTo", t }),
		[engine],
	);
	const handleScrubStart = useCallback(
		() => engine.enqueue({ kind: "beginScrub" }),
		[engine],
	);
	const handleScrubEnd = useCallback(
		() => engine.enqueue({ kind: "endScrub" }),
		[engine],
	);
	// Tool-options-bar drafts. Owned here so the values survive
	// tool-switch, and held in a store rather than state because the
	// handlers below read them at the click that commits, not at
	// render: a captured copy is stale the moment a field changes
	// after the callback was built. Empty fields fall through to
	// engine-side autogeneration (peer-N etc.).
	const toolDraftsRef = useRef<ToolDraftStore | null>(null);
	toolDraftsRef.current ??= new ToolDraftStore();
	const toolDrafts = toolDraftsRef.current;

	const {
		handleSelect,
		handleAddPeer,
		handleOpenSessionToNewEnd,
		handleNodeDrag,
	} = useStageBuildGestures({
		engine,
		mode: state.mode,
		tool: state.tool,
		firstPickNodeId: state.firstPickNodeId,
		spaceHeld,
		dispatch,
		dispatchSelection,
		onStoreSelect,
		toolDrafts,
	});

	// Sub-selection focus (#16): id of the keyframe glyph the user
	// has parked attention on, or null when focus is clear. Sits
	// orthogonal to entity selection. A focused glyph lives inside
	// a session span, but the entity selection still rides on the
	// parent session (not the keyframe). Escape unwinds focus
	// before clearing the entity selection so the state machine
	// has a predictable inner→outer step.
	const [focusedEventId, setFocusedEventId] = useState<string | null>(null);

	// Which section of the Reference is open, or null when it is closed. It is
	// a view of the composition rather than a change to it, so it carries no
	// history and lives here rather than in the document.
	const [reference, setReference] = useState<ReferenceSectionId | null>(null);

	const handleDeselect = useCallback(() => {
		// Sub-selection state machine (#16): unwind inner→outer. If a
		// keyframe glyph is focused, Esc clears focus first and stops
		// there. The user is still parked on the entity. Second Esc
		// (focus now null) falls through to the entity / first-pick
		// clear. Matches the muscle memory of nested modals where
		// Esc closes one layer at a time.
		if (focusedEventId !== null) {
			setFocusedEventId(null);
			return;
		}
		if (state.firstPickNodeId !== null) {
			dispatch({ type: "set-first-pick", nodeId: null });
		}
		onClearStoreSelection();
	}, [
		focusedEventId,
		state.firstPickNodeId,
		dispatch,
		onClearStoreSelection,
	]);

	// Single source for every surface that resolves a gesture or draws a
	// cursor: the Stage, and the Timeline's two canvas hosts. One value, so a
	// tool's cursor and a modifier's selection preview do not stop at a panel
	// edge. Which modifiers are watched at all is the held-gesture table's
	// answer (`heldModifiers`), so nothing here restates it.
	const gestureCtx = useMemo<SurfaceGestureCtx>(
		() => ({ spaceHeld, activeTool: state.tool, modifiers }),
		[spaceHeld, state.tool, modifiers],
	);

	// Sidebar editor binding. `beginEdit` / `endEdit` brackets a
	// focus session so a typing burst becomes one undo step.
	const builderEditor = useMemo(
		() =>
			bindBuilderEditor(engine, {
				onEntityRenamed,
				onClearStoreSelection,
			}),
		[engine, onClearStoreSelection, onEntityRenamed],
	);

	const handlePickTool = useCallback(
		(tool: BuilderTool) => dispatch({ type: "set-tool", tool }),
		[dispatch],
	);
	const handleDeleteSelection = useCallback(
		() => {
			// Group delete first: if the store has a multi-selection,
			// delete every member (peer / session / message) inside one
			// engine transaction so undo restores the whole group as a
			// unit. Falls through to the single-entity path only when
			// the group is empty, when the Inspector's single-entity path owns it.
			if (selection.size > 0) {
				// What the loop below actually takes, which is not always the
				// whole selection: a session end has no delete of its own, so
				// a selection holding nothing else deletes nothing at all.
				// The same phrase the Inspector's trash wears, so the two ways
				// of asking for one act report one act.
				const takes = deletionPhrase(selection);
				if (takes === null) return;
				asOneEdit(engine, `Delete ${takes}`, () => {
					for (const key of selection) {
						const { kind, id } = parseEntityKey(key);
						if (kind === "peer") {
							engine.dispatch({
								kind: "delete-peer",
								peerId: id,
							});
						} else if (kind === "session") {
							engine.dispatch({
								kind: "delete-session",
								sessionId: id,
							});
						} else if (kind === "message") {
							engine.dispatch({
								kind: "delete-message",
								messageId: id,
							});
						}
					}
				});
				onClearStoreSelection();
				return;
			}
			builderEditor.onDelete(anchor);
		},
		[
			builderEditor,
			anchor,
			selection,
			engine,
			onClearStoreSelection,
		],
	);
	// Save always writes the BUFFER, never the live monitor. In
	// Live mode the active `engine` is the live engine (transient
	// monitor doc); the user's mental model of "save" is "save what
	// I've recorded / loaded", which is the buffer.
	const handleSave = useCallback(
		() => {
			if (bufferEngine) downloadDocAsJson(bufferEngine.doc);
		},
		[bufferEngine],
	);
	// Undo and redo are the app's, not the engine's, because taking
	// history back moves ids out from under the selection and something
	// has to walk the selection back onto what the document then holds.
	// Both surfaces that offer the command, the top bar's buttons and
	// the Cmd-Z binding, come through this pair, so there is one place
	// the act is spelled and one place it can gain a step.
	const handleUndo = useCallback(
		() => undoWithSelection(engine, dispatchSelection),
		[engine, dispatchSelection],
	);
	const handleRedo = useCallback(
		() => redoWithSelection(engine, dispatchSelection),
		[engine, dispatchSelection],
	);
	// Arrow-key nudge: the arrows move every node in the selection by
	// one step, ten with Shift. World coords are in pixel-equivalent
	// units, so a step matches what the user sees on the stage at 1:1
	// zoom. Returning `true` claims the gesture; `false` falls back to
	// the global time-scrub behavior (arrows = seek).
	// "Non-empty selection wins" stands in for explicit panel focus,
	// the user's intent is whichever surface they last selected on.
	const handleNudgeSelection = useCallback(
		(dx: number, dy: number, opts: { shift: boolean }): boolean => {
			const step = opts.shift ? 10 : 1;
			return nudgeSelection(engine, selection, {
				dx: dx * step,
				dy: dy * step,
			});
		},
		[selection, engine],
	);
	const handleSelectAll = useCallback(
		() => onSetSelection(allEntityKeys(engine.doc.entities)),
		[engine, onSetSelection],
	);
	const {
		handleCopySelection,
		handlePasteClipboard,
		handleDuplicateSelection,
	} = useSelectionClipboard(engine, selection, onSetSelection);

	useShortcutBindings(shortcuts, {
		engine,
		mode: state.mode,
		onDeselect: handleDeselect,
		onDelete: handleDeleteSelection,
		onSelectAll: handleSelectAll,
		onSave: handleSave,
		onOpen,
		onPickTool: handlePickTool,
		onUndo: handleUndo,
		onRedo: handleRedo,
		onCopySelection: handleCopySelection,
		onPasteClipboard: handlePasteClipboard,
		onDuplicateSelection: handleDuplicateSelection,
		onNudgeSelection: handleNudgeSelection,
	});

	// Flash convention: pause the clock when entering Build so the
	// playhead is stable for authoring; play has to be deliberate.
	useEffect(() => {
		if (state.mode === "build") engine.enqueue({ kind: "pause" });
	}, [state.mode, engine]);

	const scenarioTitle = docTitle(engine.doc);

	// What the Inspector is showing, which is not always what is logically
	// selected: a selection is kept across a mode switch so returning restores it,
	// and while Live is up it names entities the live stream has never mentioned.
	// Derived once here and read by every part of the pane, including its section
	// titles (`inspectorView` argues why at the declaration).
	const shown = inspectorView(engine, anchor, selection);

	// Same selection → same key → no remount → no fade. Different
	// selection → remount → `ocv-inspector-swap` runs. Keyed on what is SHOWN, so
	// the fade runs when the pane's content actually changes.
	const inspectorKey = shown.anchor ? `${shown.anchor.kind}:${shown.anchor.id}` : "none";

	return (
		<div
			className="ocv-app-root"
			style={appShellStyle(sizes, bottomPaneHeight)}
		>
			<AppHeader
				title={scenarioTitle}
				mode={state.mode}
				liveRecording={liveRecording}
				engine={engine}
				onModeChange={onModeChange}
				onUndo={handleUndo}
				onRedo={handleRedo}
				onNew={onNew}
				onSave={handleSave}
				onOpen={onOpen}
				onResetLayout={onResetLayout}
				theme={theme}
				onToggleTheme={onToggleTheme}
				onOpenReference={() => setReference(DEFAULT_REFERENCE_SECTION)}
			/>

			<LeftRail
				mode={state.mode}
				tool={state.tool}
				onPickTool={(tool) => dispatch({ type: "set-tool", tool })}
				scenarioId={state.scenarioId}
				source={sourceInfo}
				engine={engine}
				liveSturdyref={state.liveSturdyref}
				liveConnected={liveConnected}
				liveObserved={liveObserved}
				liveRecording={liveRecording}
				onScenarioChange={handleScenarioChange}
				onLiveSturdyrefChange={(sturdyref) => dispatch({ type: "set-live-sturdyref", sturdyref })}
				editor={state.mode === "build" ? builderEditor : undefined}
				dispatchSelection={dispatchSelection}
				onOpenReference={() => setReference(DEFAULT_REFERENCE_SECTION)}
				onResize={onResize}
			/>

			<StagePane
				engine={engine}
				mode={state.mode}
				tool={state.tool}
				firstPickNodeId={state.firstPickNodeId}
				spaceHeld={spaceHeld}
				theme={theme}
				visibility={visibility}
				gestureCtx={gestureCtx}
				selection={selection}
				anchor={anchor}
				toolDrafts={toolDrafts}
				onSelect={handleSelect}
				onAddPeer={handleAddPeer}
				onOpenSessionToNewEnd={handleOpenSessionToNewEnd}
				onNodeDrag={handleNodeDrag}
				onDeselect={handleDeselect}
				onRubberBandCommit={onRubberBandCommit}
			/>

			<InspectorRail
				engine={engine}
				shown={shown}
				inspectorKey={inspectorKey}
				onSelect={handleSelect}
				editor={state.mode === "build" ? builderEditor : undefined}
				onNarrowSelection={onSetSelection}
				onResize={onResize}
			/>

			{
				/* Timeline panel, always rendered so the bottom bar
          doesn't disappear-and-reappear on mode switches. In
          Live mode the panel still shows the live-feed events
          and the live edge, but interaction is disabled: no
          scrub / seek / play (the feed is forward-only). The
          `disabled` prop mutes the chrome and short-circuits
          the pointer handlers, visually the user reads
          "timeline is here, just not yours to steer right now,"
          which is the honest live semantic. */
			}
			{engine && (
				<AppTimeline
					engine={engine}
					bufferEngine={bufferEngine}
					mode={state.mode}
					editor={state.mode === "build" ? builderEditor : undefined}
					selection={selection}
					anchor={anchor}
					onSelectEvent={handleSelect}
					focusedEventId={focusedEventId}
					onFocusEvent={setFocusedEventId}
					onEditSelection={onTimelineEditSelection}
					gestureCtx={gestureCtx}
					liveConnected={liveConnected}
					liveRecording={liveRecording}
					onStartRecord={onStartRecord}
					onStopRecord={onStopRecord}
					onDiscardRecording={onDiscardRecording}
					timelineLayoutResetKey={timelineLayoutResetKey}
					onFitPanelHeight={onFitPanelHeight}
					onResize={onResize}
					onIntrinsicHeightChange={onTimelineIntrinsicChange}
					onMinHeightChange={onTimelineMinHeightChange}
					timelineMinHeight={timelineMinHeight}
					autoSizeTimeline={state.autoSizeTimeline}
					onSetAutoSizeTimeline={(value) => dispatch({ type: "set-auto-size-timeline", value })}
					onPlayPause={handlePlayPause}
					onRestart={handleRestart}
					onSetSpeed={handleSetSpeed}
					onSeek={handleSeek}
					onScrubStart={handleScrubStart}
					onScrubEnd={handleScrubEnd}
				/>
			)}

			{reference !== null && (
				<ReferenceDialog
					section={reference}
					onPick={setReference}
					onClose={() => setReference(null)}
				/>
			)}
		</div>
	);
}
