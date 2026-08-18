/**
 * ocapnviz App — buffer, mode, and which engine is live.
 *
 * The view of that engine lives in `AppView.tsx`. This module owns
 * the source order (edited fork, file, recording, fixture), the mode
 * flip that captures Build edits, and the Live capture that becomes
 * the buffer on Stop. Nothing here paints a pane.
 */

import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import { Engine } from "./engine/engine.ts";
import { docTitle, TimelineDocument } from "./engine/timeline.ts";
import { useStoreSelection } from "./interactions/use-store-selection.ts";
import { UnifiedCanvas } from "./render/UnifiedCanvas.tsx";
import { claimRecording } from "./engine/live/mode.ts";
import { BusErrorModal } from "./ui/error/ErrorModal.tsx";
import { ConfirmDialog } from "./ui/ConfirmDialog.tsx";
import { ErrorToast } from "./ui/error/ErrorToast.tsx";
import { useEngineErrors } from "./ui/error/useEngineErrors.ts";
import { pushError } from "./ui/error/error-bus.ts";
import { importError } from "./engine/errors.ts";
import { c, SPACE } from "./ui/tokens.ts";
import { scenarios } from "./fixtures/index.ts";
import {
  type AppMode,
  BOTTOM_PANE_MIN,
  type BufferSourceInfo,
  makeInitialAppState,
  reducer,
  TIMELINE_VIEW_STORAGE_KEY,
} from "./state/app-state.ts";
import {
  useAppStatePersistence,
  useBufferEngine,
  useKeyboardInput,
  useLayoutSizes,
  useLiveConnection,
  useOverStage,
  useStageVisibility,
  useTheme,
} from "./state/hooks.ts";
import { heldModifiers, isClaimed } from "./state/keyboard-input.ts";
import { newDocument } from "./builder/document-io.ts";
import { AppView } from "./AppView.tsx";

// `useClockSnapshot` is subscribed LOCALLY by `TimelinePanel`, not
// here — subscribing at the App root would re-reconcile the whole
// tree on every Pixi tick.

export function App() {
  const [state, dispatch] = useReducer(reducer, undefined, makeInitialAppState);
  useAppStatePersistence(state);

  const [theme, toggleTheme] = useTheme();
  const [sizes, setSizes, resetSizes] = useLayoutSizes();
  const [visibility, , resetVisibility] = useStageVisibility();
  // `timelineIntrinsic` hoisted above `resetUi` so the reset
  // handler can compose the intrinsic-aware bump in one go.
  const [timelineIntrinsic, setTimelineIntrinsic] = useState(0);
  // Dynamic floor published by TimelinePanel based on its measured
  // control-row height. Replaces the hardcoded `BOTTOM_PANE_MIN`
  // (which assumed a 40px control row but the actual chrome is
  // ~45px), so drag-down can't squash the Overview onto the ruler.
  const [timelineMinHeight, setTimelineMinHeight] = useState(
    BOTTOM_PANE_MIN,
  );
  const bottomPaneMin = Math.max(BOTTOM_PANE_MIN, timelineMinHeight);
  // Bumped on Reset Layout so TimelinePanel remounts with a fresh
  // view (expansions / gutter) after storage is cleared — otherwise
  // only the next reload would see the reset.
  const [timelineLayoutResetKey, setTimelineLayoutResetKey] = useState(0);
  // `timelineMinHeight` is the collapsed-fit height TimelinePanel
  // publishes (chrome + every category collapsed). That is the drag
  // floor. Fit / auto-size use `timelineIntrinsic` (live expansion)
  // separately — do not fold it into the drag clamp, or an expanded
  // panel refuses every downward drag.

  const {
    storeSelection,
    dispatchSelection,
    handleRubberBandCommit,
    handleTimelineEditSelection,
    handleClearStoreSelection,
    handleSetSelection,
    handleEntityRenamed,
    handleStoreSelect,
  } = useStoreSelection();

  // "Reset layout" is the whole-UI escape hatch, layer visibility
  // included. Reset enables auto-size on the timeline so the
  // bottom pane snaps to its intrinsic content height (instead
  // of writing an arbitrary static default) — the auto-size
  // effect below keeps it pinned as the user expands/collapses
  // categories afterwards.
  const resetUi = useCallback(() => {
    // Pin the bottom pane to the current intrinsic in the SAME
    // commit that writes the defaults — otherwise React paints
    // `BOTTOM_PANE_DEFAULT` first and the auto-size effect shrinks
    // to intrinsic on the next tick, producing a visible flash
    // (most obvious in Live mode where intrinsic ≪ 220).
    const fittedBottom = timelineIntrinsic > 0 ? Math.max(timelineIntrinsic, bottomPaneMin) : undefined;
    resetSizes(
      fittedBottom !== undefined ? { bottomPaneHeight: fittedBottom } : {},
    );
    resetVisibility();
    dispatch({ type: "set-auto-size-timeline", value: true });
    // Timeline view (expansions / gutter) is a layout pref like sizes
    // and visibility. Clear the store first, then remount the panel
    // so its initializer reloads defaults in this session — not only
    // on the next page load.
    globalThis.localStorage?.removeItem(TIMELINE_VIEW_STORAGE_KEY);
    setTimelineLayoutResetKey((k) => k + 1);
  }, [resetSizes, resetVisibility, timelineIntrinsic, bottomPaneMin, dispatch]);

  // Sources that can populate the buffer engine, in precedence
  // order: Build-edited fork → imported file → live capture →
  // scenario fixture. Exactly one is the buffer at a time, and the
  // Source panel says which (`sourceInfo` below) — a source change
  // (Open, leaving Live with a capture, fixture pick) clears
  // whatever it replaces, so nothing shadows silently.
  const [loadedFile, setLoadedFile] = useState<
    { name: string; doc: TimelineDocument } | null
  >(null);
  const [recordedDoc, setRecordedDoc] = useState<TimelineDocument | null>(null);
  // A document started from nothing by New. Its own slot for the same reason it
  // is its own source kind: it is not a file, and parking it in `loadedFile`
  // would have the panel name a file the reader never opened.
  const [newDoc, setNewDoc] = useState<TimelineDocument | null>(null);
  // The one-buffer contract across modes: leaving Build with edits
  // captures the working doc here, so Play replays what you built
  // and re-entering Build continues from it. Cleared when a new
  // source replaces the buffer.
  const [editedDoc, setEditedDoc] = useState<TimelineDocument | null>(null);

  // Bottom-pane sizing rule: the user's stored value IS the
  // visible pane height. No `min(stored, intrinsic)` coupling —
  // the previous rule made drag-up feel dead until you'd first
  // dragged down past intrinsic, and made the "drag to enable
  // overflow scroll" gesture undiscoverable. Symmetric resize
  // now; when intrinsic > pane, overflow scrolls inside the
  // lanes region (handled in `Scrubber`). A double-click on
  // the resize handle (and a button in the Timeline control
  // row, via `onFitPanelHeight`) snaps the pane to the current
  // intrinsic on demand.
  const bottomPaneHeight = Math.max(
    sizes.bottomPaneHeight,
    bottomPaneMin,
  );
  const fitPanelHeightToContent = useCallback(() => {
    if (timelineIntrinsic <= 0) return;
    setSizes((s) => ({
      ...s,
      bottomPaneHeight: Math.max(timelineIntrinsic, bottomPaneMin),
    }));
  }, [timelineIntrinsic, bottomPaneMin, setSizes]);

  // Auto-size effect: while the toggle is on, pin
  // `bottomPaneHeight` to the panel's current intrinsic — so
  // expanding/collapsing categories, swapping modes (which
  // remounts the panel and republishes intrinsic), or loading a
  // doc with more lanes all refit the pane. The user opts out
  // by dragging the resize handle (see `onDelta` below); the
  // first non-zero delta flips the toggle off and freezes the
  // stored height.
  //
  // Layout effect (not regular effect) so that on a category
  // expand/collapse the chain `Scrubber intrinsic publish →
  // TimelinePanel intrinsic publish → this pane resize` all runs
  // synchronously before paint. A regular useEffect ran each
  // link after a separate commit, producing a one-frame paint at
  // the *old* pane height with the *new* lane count (or vice
  // versa) — the visible stutter.
  useLayoutEffect(() => {
    if (!state.autoSizeTimeline) return;
    if (timelineIntrinsic <= 0) return;
    setSizes((s) => {
      const target = Math.max(timelineIntrinsic, bottomPaneMin);
      if (s.bottomPaneHeight === target) return s;
      return { ...s, bottomPaneHeight: target };
    });
    // `sizes.bottomPaneHeight` is in the deps so the effect re-
    // pins after any external write — notably `resetSizes()` from
    // Reset Layout, which writes `BOTTOM_PANE_DEFAULT` over the
    // already-pinned intrinsic. Without this dep a second Reset
    // click leaves the pane stuck at the default (e.g. 220px) even
    // though autoSize is on. The `target === s.bottomPaneHeight`
    // bail-out above keeps this from looping on its own writes.
  }, [
    state.autoSizeTimeline,
    timelineIntrinsic,
    bottomPaneMin,
    sizes.bottomPaneHeight,
    setSizes,
  ]);

  const fixtureDoc = useMemo(
    () => scenarios.find((s) => s.id === state.scenarioId) ?? null,
    [state.scenarioId],
  );
  const sourceDoc = editedDoc ?? newDoc ?? loadedFile?.doc ?? recordedDoc ??
    fixtureDoc;
  // What the buffer IS, for the Source panel. `edited` rides every
  // arm: the base source stays the identity, the edits are a state
  // of it.
  const sourceInfo: BufferSourceInfo | null = newDoc
    ? { kind: "new", edited: editedDoc !== null }
    : loadedFile
    ? { kind: "file", name: loadedFile.name, edited: editedDoc !== null }
    : recordedDoc
    ? { kind: "recording", edited: editedDoc !== null }
    : fixtureDoc
    ? {
      kind: "builtin",
      id: fixtureDoc.id,
      title: docTitle(fixtureDoc),
      edited: editedDoc !== null,
    }
    : null;

  const { bufferEngine } = useBufferEngine({ sourceDoc });

  // Whether a capture is running. The connection is a separate fact
  // and `useLiveConnection` owns it: entering Live dials, so a reader
  // can see the feed is there before deciding to record anything.
  //
  // Live still renders nothing until Record, because a capture is what
  // there is to render. The press mounts the capture engine on a fresh
  // dial, so its t=0 is the press and the producer's replay
  // materializes the topology alive at that moment as state inside it.
  // Stop unmounts the capture and leaves the connection standing.
  const [recording, setRecording] = useState(false);

  // Runs unconditionally (rules-of-hooks) — an empty url dials nothing
  // outside Live mode.
  const {
    connected: liveConnected,
    captureEngine,
  } = useLiveConnection({
    sturdyref: state.mode === "live" ? state.liveSturdyref : "",
    recording,
  });

  const recordingsClaimed = useRef(0);
  const handleStartRecord = useCallback(() => setRecording(true), []);
  const handleDiscardRecording = useCallback(() => setRecording(false), []);
  // Stop claims the recording as the unsaved buffer source and
  // lands in Play — record, stop, review. Consent to replace the
  // buffer was given at the Record press (the confirm lives in
  // LiveControls).
  const handleStopRecord = useCallback(() => {
    setRecording(false);
    const claimed = captureEngine !== null
      ? claimRecording(
        captureEngine.doc,
        `live-recording-${++recordingsClaimed.current}`,
      )
      : null;
    if (claimed === null) return;
    setRecordedDoc(claimed);
    setLoadedFile(null);
    setEditedDoc(null);
    setNewDoc(null);
    dispatch({ type: "set-mode", mode: "play" });
  }, [captureEngine, dispatch]);

  // Leaving Build with edits puts the working document ahead of the
  // fixture in the source order, so the picker names what you built
  // and a later reload of the same fixture cannot shadow it. A plain
  // mode flip with no edits keeps the source pristine.
  //
  // Leaving Live mid-recording used to stop and claim the capture from
  // here. It no longer can, because it no longer happens: the mode
  // toggle's other two cells are inert while a capture is in flight,
  // and so is Open, which is the other act that lands in Play. What
  // guarantees the capture is not silently abandoned is therefore not
  // a rescue on the way out — it is that there is no way out except
  // the two controls that mean it, Stop and Discard, which is where
  // the consent given at the Record press is actually spent.
  const handleModeChange = useCallback(
    (mode: AppMode) => {
      if (
        mode !== state.mode && state.mode === "build" &&
        bufferEngine?.canUndo
      ) {
        setEditedDoc(bufferEngine.doc);
      }
      dispatch({ type: "set-mode", mode });
    },
    [state.mode, bufferEngine, dispatch],
  );

  // A fixture pick (or any explicit source switch) replaces the
  // buffer wholesale. The one list of what the buffer can be, so a slot added to
  // the source order above is cleared everywhere by adding it here.
  const clearSourceOverrides = useCallback(() => {
    setLoadedFile(null);
    setRecordedDoc(null);
    setEditedDoc(null);
    setNewDoc(null);
  }, []);

  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const handleOpen = useCallback(() => fileInputRef.current?.click(), []);
  const handleNew = useCallback(() => {
    // Replaces the buffer wholesale, exactly as Open does, so nothing that was
    // loaded or captured shadows the empty document. Clearing first and setting
    // second, because the clear names `newDoc` too.
    clearSourceOverrides();
    setNewDoc(newDocument());
    // Build, not Play: there is nothing to play yet, and the reason to start an
    // empty document is to put something in it.
    dispatch({ type: "set-mode", mode: "build" });
  }, [clearSourceOverrides, dispatch]);
  const handleFileChange = useCallback(
    async (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0];
      e.target.value = "";
      if (!file) return;
      try {
        const parsed = TimelineDocument.parse(JSON.parse(await file.text()));
        setLoadedFile({ name: file.name, doc: parsed });
        // Open replaces the buffer wholesale — a prior capture or
        // edited fork would otherwise shadow the loaded file.
        setRecordedDoc(null);
        setEditedDoc(null);
        setNewDoc(null);
        // Open from Live needs to leave Live (Live doesn't render
        // the buffer); land on Play so the file actually plays.
        if (state.mode === "live") {
          dispatch({ type: "set-mode", mode: "play" });
        }
      } catch (caught) {
        const message = caught instanceof Error ? caught.message : String(caught);
        pushError({
          error: importError(
            `${file.name} could not be read: ${message}`,
            "Check that the file is a timeline document saved from this app, then try again.",
          ),
          source: "engine",
        });
      }
    },
    [dispatch, state.mode],
  );

  // Live before Record renders nothing, because a capture is what
  // there is to render and nobody has asked for one — the feed is
  // connected either way, and the connection dot says so. The shell
  // (top bar, mode toggle, the Record affordance) still needs an
  // engine to hang off, so idle Live gets a blank one: empty doc,
  // clock parked at 0, never played, nothing on stage or timeline.
  const idleLiveEngine = useMemo(
    () =>
      new Engine({
        id: "live-idle",
        duration: 60 * 60 * 1000,
        recording: {
          sources: [{
            id: "live",
            meta: { kind: "pancake-host" },
            observations: [],
          }],
        },
      }),
    [],
  );
  const engine = state.mode === "live" ? captureEngine ?? idleLiveEngine : bufferEngine;

  // Forward engine errors onto the app-wide error bus so the
  // top-level <ErrorToast /> and <ErrorModal /> can render them.
  // Window-level errors and Promise rejections are already routed
  // through the bus by the global handlers in main.tsx.
  useEngineErrors(engine);

  // Dev/test introspection hook. Tests and the browser console
  // can read the latest store selection AND the live engine
  // without poking React internals. Overwritten each render —
  // there's only ever one App.
  useEffect(() => {
    const g = globalThis as unknown as {
      __ocv?: Record<string, unknown>;
    };
    if (!g.__ocv) g.__ocv = {};
    g.__ocv.selection = storeSelection;
    g.__ocv.engine = engine;
  }, [storeSelection, engine]);

  // One keyboard listener for the whole app. It answers which
  // gestures are held right now, and hands anything no gesture
  // claimed to the shortcut table through `shortcuts`, which
  // AppView publishes its bindings into.
  const overStage = useOverStage();
  const { held, shortcuts } = useKeyboardInput({ overStage });
  // Space follows the hovered surface: over the stage it is the
  // temporary hand (any mode — panning mutates nothing), anywhere
  // else it is transport. A claim is the key's own lifetime, so
  // everything that speaks about the key reads it: the tip, the
  // FSM's gesture context, the click gating below.
  const spaceHeld = isClaimed(held, "space-pan");
  // Every modifier the pointer layer asks about, in one value derived from
  // the same held set. Which ones are watched at all is the held-gesture
  // table's answer, so nothing here restates it. Memoized on the held set,
  // which only turns on a key event: the surfaces below key effects on this
  // value, and a fresh object every render would run them every render.
  const modifiers = useMemo(() => heldModifiers(held), [held]);

  // Keep `UnifiedCanvas` mounted across engine transitions.
  // Otherwise Play→Build briefly nulls `engine`, unmounts the
  // subtree, and scene cleanups race `app.destroy()`.
  // Live mode always has an engine (the capture, or the blank idle one
  // above), so the only way to have none is a Play/Build buffer with no
  // source at all.
  const message = engine
    ? null
    : "Nothing is loaded. Pick a built-in example in the Source panel, or open a saved timeline.";

  return (
    <UnifiedCanvas theme={theme}>
      <ErrorToast />
      <BusErrorModal />
      {
        /* The one dialog every destructive act asks through. Here beside the
          error modal because both are app-wide and neither belongs to the
          surface that raises it. */
      }
      <ConfirmDialog />
      <input
        ref={fileInputRef}
        type="file"
        accept="application/json,.json"
        onChange={handleFileChange}
        style={{ display: "none" }}
      />
      {engine
        ? (
          <AppView
            engine={engine}
            bufferEngine={bufferEngine}
            sourceInfo={sourceInfo}
            onClearSourceOverrides={clearSourceOverrides}
            onModeChange={handleModeChange}
            dispatch={dispatch}
            state={state}
            liveConnected={liveConnected}
            liveRecording={recording}
            onStartRecord={handleStartRecord}
            onStopRecord={handleStopRecord}
            onDiscardRecording={handleDiscardRecording}
            theme={theme}
            onToggleTheme={toggleTheme}
            sizes={sizes}
            bottomPaneHeight={bottomPaneHeight}
            onFitPanelHeight={fitPanelHeightToContent}
            onResize={setSizes}
            onResetLayout={resetUi}
            timelineLayoutResetKey={timelineLayoutResetKey}
            visibility={visibility}
            spaceHeld={spaceHeld}
            shortcuts={shortcuts}
            modifiers={modifiers}
            onNew={handleNew}
            onOpen={handleOpen}
            onTimelineIntrinsicChange={setTimelineIntrinsic}
            onTimelineMinHeightChange={setTimelineMinHeight}
            timelineMinHeight={bottomPaneMin}
            selection={storeSelection.selection}
            anchor={storeSelection.anchor}
            dispatchSelection={dispatchSelection}
            onRubberBandCommit={handleRubberBandCommit}
            onClearStoreSelection={handleClearStoreSelection}
            onStoreSelect={handleStoreSelect}
            onEntityRenamed={handleEntityRenamed}
            onSetSelection={handleSetSelection}
            onTimelineEditSelection={handleTimelineEditSelection}
          />
        )
        : (
          <div
            style={{
              padding: SPACE.lg,
              color: c.textMuted,
              // Above the canvas (z-index 0), like the rest of the
              // app shell.
              position: "relative",
              zIndex: 1,
            }}
          >
            {message}
          </div>
        )}
    </UnifiedCanvas>
  );
}
