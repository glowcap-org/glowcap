import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";
import { Engine } from "./engine/engine.ts";
import { docTitle, TimelineDocument } from "./engine/timeline.ts";
import {
  selectionActionFor,
  selectionReducer,
} from "./interactions/selection-store.ts";
import {
  EMPTY_SELECTION,
  entityKey,
  type EntityRefKey,
  isTwoClickTool,
  type ModifierSet,
  parseEntityKey,
  type SelectionAction,
  type SurfaceGestureCtx,
} from "./interactions/types.ts";
import { Stage } from "./render/Stage.tsx";
import type {
  SelectMode,
  StageSelection,
  StageVisibility,
} from "./render/types.ts";
import { UnifiedCanvas } from "./render/UnifiedCanvas.tsx";
import { TimelinePanel } from "./ui/Timeline/TimelinePanel.tsx";
import { LegendBody, LegendReferenceButton } from "./ui/Legend.tsx";
import {
  DEFAULT_REFERENCE_SECTION,
  ReferenceButton,
  ReferenceDialog,
  type ReferenceSectionId,
} from "./ui/reference/Reference.tsx";
import {
  connectionsSectionTitle,
  type EditorBindings,
  EntityConnections,
  EntityDetails,
  inspectorView,
} from "./ui/Sidebar.tsx";
import { deletionPhrase } from "./ui/inspector/selection-summary.ts";
import { Brandmark } from "./ui/Brandmark.tsx";
import { Section } from "./ui/Section.tsx";
import { ThemeToggle } from "./ui/ThemeToggle.tsx";
import { CURRENT_SOURCE_OPTION, SourcePicker } from "./ui/SourcePicker.tsx";
import { claimRecording } from "./engine/live-mode.ts";
import { ResizeHandle } from "./ui/ResizeHandle.tsx";
import { StageControls } from "./ui/StageControls.tsx";
import { ToolPalette } from "./ui/ToolPalette.tsx";
import {
  DiscardAllButton,
  ToolCommandRow,
  UndoAllButton,
  UnpinAllButton,
} from "./ui/ToolCommands.tsx";
import { ToolDraftStore, ToolOptionsBar } from "./ui/ToolOptionsBar.tsx";
import { BusErrorModal } from "./ui/error/ErrorModal.tsx";
import { ConfirmDialog } from "./ui/ConfirmDialog.tsx";
import { requestConfirm } from "./ui/confirm.ts";
import { ErrorToast } from "./ui/error/ErrorToast.tsx";
import { useEngineErrors } from "./ui/error/useEngineErrors.ts";
import { pushError } from "./ui/error/error-bus.ts";
import { importError } from "./engine/errors.ts";
import { observationsOf } from "./engine/temporal/recording-access.ts";
import type { ClipboardPayload } from "./engine/schema/clipboard.ts";
import type { IdRemap } from "./engine/schema/paste.ts";
import {
  ModeToggle,
  SaveOpenControls,
  UndoRedoControls,
} from "./ui/topbar.tsx";
import {
  c,
  FONT,
  PANEL,
  SIZE,
  SPACE,
  type Theme,
  WEIGHT,
} from "./ui/tokens.ts";
import { nextVisCycleStep } from "./engine/visibility.ts";
import { scenarios } from "./fixtures/index.ts";
import {
  type AppAction,
  type AppMode,
  type AppState,
  BOTTOM_PANE_MIN,
  type BufferSourceInfo,
  type BuilderTool,
  type LayoutSizes,
  makeInitialAppState,
  reducer,
  TIMELINE_VIEW_STORAGE_KEY,
  TOP_BAR_HEIGHT,
} from "./state/app-state.ts";
import {
  type ShortcutSink,
  useAppStatePersistence,
  useBufferEngine,
  useKeyboardInput,
  useLayoutSizes,
  useLiveConnection,
  useOverStage,
  useShortcutBindings,
  useStageVisibility,
  useTheme,
} from "./state/hooks.ts";
import { heldModifiers, isClaimed } from "./state/keyboard-input.ts";
import { asNodeRef } from "./interactions/gesture-resolver.ts";
import {
  advanceTwoClick,
  armedNodeLabel,
  asOneEdit,
  downloadDocAsJson,
  newDocument,
  nudgeSelection,
  openSessionToNewEnd,
  redoWithSelection,
  twoClickAccepts,
  undoWithSelection,
} from "./builder/helpers.ts";
import { ToolHint } from "./ui/ToolHint.tsx";

function appShellStyle(
  sizes: LayoutSizes,
  bottomPaneHeight: number,
): React.CSSProperties {
  return {
    display: "grid",
    gridTemplateColumns:
      `${sizes.leftPaneWidth}px 1fr ${sizes.rightPaneWidth}px`,
    gridTemplateRows:
      `${TOP_BAR_HEIGHT}px minmax(0, 1fr) ${bottomPaneHeight}px`,
    width: "100vw",
    height: "100vh",
    fontFamily: FONT.sans,
    color: c.text,
    fontSize: SIZE.base,
    // Transparent shell so the unified PixiJS canvas (z-index 0)
    // shows through where panels don't cover. Stacking context via
    // z-index 1 so the resize-handle z-indexes layer above the
    // canvas. `pointer-events: none` so empty (center-pane) area
    // passes events through to the canvas — each opaque panel
    // re-claims `pointerEvents: "auto"`.
    background: "transparent",
    position: "relative",
    zIndex: 1,
    pointerEvents: "none",
  };
}

const topBar = {
  gridColumn: "1 / -1",
  display: "flex",
  alignItems: "center",
  gap: SPACE.md,
  height: TOP_BAR_HEIGHT,
  paddingInline: SPACE.md,
  background: c.surface,
  borderBottom: `1px solid ${c.border}`,
  // See `appShellStyle.pointerEvents`.
  pointerEvents: "auto",
} satisfies React.CSSProperties;

const brand = {
  display: "flex",
  alignItems: "center",
  gap: SPACE.sm,
  minWidth: 0,
} satisfies React.CSSProperties;

const wordmark = {
  fontSize: SIZE.lg,
  fontWeight: WEIGHT.semibold,
  letterSpacing: -0.2,
  color: c.text,
} satisfies React.CSSProperties;

const breadcrumbSep = {
  fontSize: SIZE.lg,
  color: c.textSubtle,
  marginInline: 2,
  fontWeight: WEIGHT.regular,
} satisfies React.CSSProperties;

const breadcrumbCurrent = {
  fontSize: SIZE.base,
  color: c.textMuted,
  fontWeight: WEIGHT.medium,
  letterSpacing: 0.01,
  whiteSpace: "nowrap",
  overflow: "hidden",
  textOverflow: "ellipsis",
} satisfies React.CSSProperties;

const headerSpacer = { flex: 1 } satisfies React.CSSProperties;

/**
 * The Tools section's own recessed block.
 *
 * Every other section in this rail keeps its content in one: the document's rows,
 * each of the Legend's mappings, every group in the Inspector. The tool strip and
 * the commands under it were the last thing sitting on the bare pane, which read
 * as the rail starting somewhere above where it does.
 *
 * Its two rows are ruled apart by `.ocv-tools-panel` in `styles.css`, which is
 * the same hairline the Inspector's field rows use, and the gap here is the same
 * 5px that sits above it — so the line has equal air on both sides, as it does in
 * every other panel. Every mode offers at least Select and Hand
 * (`toolsForMode`), so the box can never be empty.
 */
const toolsPanel = {
  ...PANEL,
  display: "flex",
  flexDirection: "column",
  gap: 5,
} satisfies React.CSSProperties;

const leftPane = {
  background: c.surface,
  borderRight: `1px solid ${c.border}`,
  overflowY: "auto",
  minHeight: 0,
  position: "relative",
  // See `appShellStyle.pointerEvents`.
  pointerEvents: "auto",
} satisfies React.CSSProperties;

// Center pane is the transparent layout slot for the Stage region.
// `pointer-events: none` lets clicks pass through to the canvas;
// the Stage marker div inside is also `none` for the same reason.
//
// Flex column so the ToolOptionsBar (when rendered in build mode)
// takes its natural height at the top and the Stage marker fills
// the remaining space — without that, Stage's `height: 100%` would
// overlap the bar (both stack to 100% of the pane).
const centerPane = {
  display: "flex",
  flexDirection: "column",
  position: "relative",
  minHeight: 0,
  minWidth: 0,
  pointerEvents: "none",
} satisfies React.CSSProperties;

// The Stage marker uses `height: 100%`; in a flex column its
// container needs `flex: 1` so "100%" resolves to "remaining space
// after the bar." `min-height: 0` lets it shrink correctly.
const stageSlot = {
  flex: "1 1 0",
  minHeight: 0,
  position: "relative",
  pointerEvents: "none",
} satisfies React.CSSProperties;

const rightPane = {
  background: c.surface,
  borderLeft: `1px solid ${c.border}`,
  overflowY: "auto",
  minHeight: 0,
  position: "relative",
  // See `appShellStyle.pointerEvents`.
  pointerEvents: "auto",
} satisfies React.CSSProperties;

const bottomBar = {
  gridColumn: "1 / -1",
  // Transparent so the Timeline's Overview / Scrubber paint
  // through; the toolbar inside carries its own opaque surface.
  // `position: relative` is for the top-edge `ResizeHandle`;
  // `minHeight: 0` lets the panel honor the grid row.
  background: "transparent",
  borderTop: `1px solid ${c.border}`,
  position: "relative",
  minHeight: 0,
  overflow: "hidden",
  // See `appShellStyle.pointerEvents`.
  pointerEvents: "auto",
} satisfies React.CSSProperties;

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
  // The floor a DRAG may reach, which is the height the panel fits itself to.
  //
  // `scrubberHeight` calls itself the floor for whoever sizes the panel, and
  // the fit button and Reset Layout both honour it; the drag handle used to
  // clamp at the chrome-only minimum instead, so a hand could put the panel
  // below the height its own content needs. What that produced was the rows
  // the panel could not show being clipped rather than absent, which is the
  // half-drawn bottom edge read from the other direction: fitting had been
  // taught to land on a row boundary, and dragging had not been taught
  // anything.
  //
  // A reader who wants a shorter panel has the remedy the rows answer to:
  // collapse a category, or toggle a lane off. Both change what the content is
  // rather than hiding part of it.
  const bottomPaneFloor = Math.max(bottomPaneMin, timelineIntrinsic);

  // Selection-store (interaction-model § 6). Single source of truth
  // for time-range, anchor (Inspector follow), and multi-selection.
  // `anchor` is the StageSelection-shaped slot consumers like Stage,
  // TimelinePanel, and Sidebar read; `selection` is the entity-key
  // set the marquee + bulk ops write through.
  const [storeSelection, dispatchSelection] = useReducer(
    selectionReducer,
    EMPTY_SELECTION,
  );
  // Rubber-band commit (interaction-model § 4.7): drag-end on
  // empty stage hands back the set of entity keys + a mode.
  // Modifier latches captured during the drag pick the mode:
  // plain → replace, shift → add, shift+option → remove.
  const handleRubberBandCommit = useCallback(
    (entities: ReadonlySet<EntityRefKey>, mode: SelectMode) => {
      const action = selectionActionFor(mode, entities, "stage");
      if (action) dispatchSelection(action);
    },
    [],
  );
  // The timeline's counterpart — same interpreter, timeline
  // empty-space semantics (clears the time range, keeps the
  // anchor).
  const handleTimelineEditSelection = useCallback(
    (entities: ReadonlySet<EntityRefKey>, mode: SelectMode) => {
      const action = selectionActionFor(mode, entities, "timeline");
      if (action) dispatchSelection(action);
    },
    [],
  );
  // Escape clears EVERY selection slot — anchor, multi-selection,
  // and time range — so the user sees one coherent "clear" verb.
  const handleClearStoreSelection = useCallback(
    () => dispatchSelection({ kind: "clear-all" }),
    [],
  );
  // Direct-write bridges to the store for surfaces that already
  // think in entity-key space (the Scrubber's rubber-band /
  // shift-click after unification, TimelinePanel's Cmd-A / Escape /
  // Delete). Stage's marquee already routes through
  // `handleRubberBandCommit`; these mirror that wiring for the
  // Timeline surface so both halves of the selection bus speak the
  // same store actions.
  const handleSetSelection = useCallback(
    (entities: ReadonlySet<EntityRefKey>) =>
      dispatchSelection({ kind: "set-selection", entities }),
    [],
  );
  // Single `rename-entity` dispatch — see `selection-store.ts`
  // for the anchor-stomp regression that motivates a dedicated
  // action over delete-then-add via `set-selection`.
  const handleEntityRenamed = useCallback(
    (
      kind: "peer" | "session" | "message",
      oldId: string,
      newId: string,
    ) => {
      dispatchSelection({
        kind: "rename-entity",
        entityKind: kind,
        oldId,
        newId,
      });
    },
    [],
  );
  // Single bridge from a Stage entity click to the store. Keeps
  // the store's `selection` in lockstep with the visible halo,
  // the mode's meaning has one home: `selectionActionFor` in the
  // selection store. This wrapper only shapes the stage's
  // single-entity click into a hit set.
  const handleStoreSelect = useCallback(
    (sel: StageSelection, opts?: { mode?: SelectMode }) => {
      const entities = sel
        ? new Set<EntityRefKey>([entityKey({ kind: sel.kind, id: sel.id })])
        : new Set<EntityRefKey>();
      const action = selectionActionFor(
        opts?.mode ?? "replace",
        entities,
        "stage",
      );
      if (action) dispatchSelection(action);
    },
    [],
  );

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
    const fittedBottom = timelineIntrinsic > 0
      ? Math.max(timelineIntrinsic, bottomPaneMin)
      : undefined;
    resetSizes(
      fittedBottom !== undefined ? { bottomPaneHeight: fittedBottom } : {},
    );
    resetVisibility();
    dispatch({ type: "set-auto-size-timeline", value: true });
    // Persisted timeline view (expansions / gutter width) is a
    // layout pref like sizes and visibility — Reset Layout drops
    // it too, so a reload starts fresh. The in-memory view stays
    // until next mount; clearing storage is what makes "reset"
    // actually reset across sessions.
    globalThis.localStorage?.removeItem(TIMELINE_VIEW_STORAGE_KEY);
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
    url: state.mode === "live" ? state.liveUrl : "",
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
        const message = caught instanceof Error
          ? caught.message
          : String(caught);
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
  const engine = state.mode === "live"
    ? captureEngine ?? idleLiveEngine
    : bufferEngine;

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
            visibility={visibility}
            spaceHeld={spaceHeld}
            shortcuts={shortcuts}
            modifiers={modifiers}
            onNew={handleNew}
            onOpen={handleOpen}
            onTimelineIntrinsicChange={setTimelineIntrinsic}
            onTimelineMinHeightChange={setTimelineMinHeight}
            timelineMinHeight={bottomPaneFloor}
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

function AppView({
  engine,
  bufferEngine,
  sourceInfo,
  onClearSourceOverrides,
  onModeChange,
  dispatch,
  state,
  liveConnected,
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
}: {
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
  dispatch: React.Dispatch<AppAction>;
  state: AppState;
  liveConnected: boolean;
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
  /** TimelinePanel publishes its dynamic minimum height (chrome
   *  + Overview + ruler band) here so the drag clamp tracks the
   *  measured control-row height instead of the hardcoded
   *  `BOTTOM_PANE_MIN`. */
  onTimelineMinHeightChange: (px: number) => void;
  /** Resolved floor used by the drag clamp — max of
   *  `BOTTOM_PANE_MIN` and the published dynamic min. */
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
  dispatchSelection: React.Dispatch<SelectionAction>;
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
}) {
  // Intentionally NOT subscribing to the clock here — that lives
  // in `TimelinePanel` where the value is consumed. App-level
  // reconciliation runs at human-interaction rate, not 60 Hz.

  const handleScenarioChange = useCallback(
    async (event: React.ChangeEvent<HTMLSelectElement>) => {
      const nextId = event.target.value;
      // The synthetic "current source" row is a label, not a
      // choice — re-selecting it changes nothing.
      if (nextId === CURRENT_SOURCE_OPTION) return;
      // Held now, before anything is awaited. `event.target` survives the
      // handler where `currentTarget` does not, and the picker below has to be
      // put back by hand: it is controlled, but a cancel changes no state, so
      // there is no re-render for React to re-sync its value on.
      const picker = event.target;
      // Switching source discards whatever the buffer holds — a
      // Build undo stack, an edited fork, an opened file, or a
      // recording. Ask when that loses user-made state; put the
      // picker back if they cancel.
      const discardsWork = (state.mode === "build" && engine?.canUndo) ||
        sourceInfo?.edited || sourceInfo?.kind !== "builtin";
      if (
        discardsWork &&
        !await requestConfirm({
          title: "Discard unsaved changes?",
          detail:
            "Switching source replaces what is loaded, so anything unsaved " +
            "in it goes.",
          confirmLabel: "Switch source",
        })
      ) {
        picker.value = sourceInfo?.kind !== "builtin"
          ? CURRENT_SOURCE_OPTION
          : state.scenarioId;
        return;
      }
      // Picking a fixture explicitly clears anything that would
      // shadow it (opened file, recording, edited fork).
      onClearSourceOverrides();
      dispatch({ type: "select-scenario", id: nextId });
      // The new doc has a new entity universe — any prior anchor /
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

  const handleSelect = useCallback(
    (selection: StageSelection, opts?: { mode?: SelectMode }) => {
      // A pan affordance (space held, or the Hand tool) means
      // clicks mustn't change selection or advance a two-click
      // flow. Existing first-pick is preserved across the pan so
      // dropping the affordance puts the user back where they were.
      // (Sprites are already pointer-silent under a pan affordance;
      // this guard is the belt.)
      if (spaceHeld || state.tool === "hand") return;
      // In a two-click tool, only clicks on a stage NODE advance the flow —
      // a peer, or an end nothing has attributed, which Send Message can
      // name. A click on a message or a session is ignored rather than
      // treated as a flow-break: a message-in-flight resting at its sender at
      // t=0 occludes the peer underneath, so clicking "the peer" can actually
      // hit the message, and cancelling there would leave the user with a
      // stale armed first pick and no way to reach the second. Empty canvas
      // is not ignored under Open Session — `handleOpenSessionToNewEnd` runs
      // the session out to a new end standing where the click landed — and it
      // still clears the selection under every other tool. Escape cancels the
      // flow, switching tools cancels it, and re-clicking the armed node
      // cancels inside `advanceTwoClick`.
      const twoClickTool = state.mode === "build" && isTwoClickTool(state.tool)
        ? state.tool
        : null;
      if (twoClickTool !== null) {
        // Whether this tool takes this node is asked in one place, the same
        // one the cursor and the hover ring read. A refused node is inert
        // here: the pointer already read not-allowed on the way in, and a
        // click that armed it anyway would make the picture a liar.
        const node = asNodeRef(selection);
        if (
          node !== null &&
          twoClickAccepts(engine, twoClickTool, state.firstPickNodeId, node) ===
            "takes"
        ) {
          // Read at the click, never from a copy this callback
          // captured: the user picks the first peer, then edits a
          // field, then picks the second, and only the value in
          // front of them at that second click is the one they
          // meant.
          const drafts = toolDrafts.read();
          const parsedFlight = drafts.messageFlightMs.length > 0
            ? Number(drafts.messageFlightMs)
            : NaN;
          advanceTwoClick(
            engine,
            twoClickTool,
            state.firstPickNodeId,
            node.id,
            dispatch,
            dispatchSelection,
            {
              codec: drafts.sessionCodec,
              captpVersion: drafts.sessionCaptpVersion,
              initialState: drafts.sessionInitialState,
              ...(drafts.messageLabel.length > 0
                ? { messageLabel: drafts.messageLabel }
                : {}),
              ...(Number.isFinite(parsedFlight)
                ? { flightMs: parsedFlight }
                : {}),
            },
          );
        }
        return;
      }
      // Plain click replaces the selection with `[entity]`;
      // shift-click toggles in/out; empty click clears. The store's
      // `anchor` slot follows the latest entity, which is what the
      // Inspector reads.
      onStoreSelect(selection, opts);
    },
    [
      engine,
      state.mode,
      state.tool,
      state.firstPickNodeId,
      spaceHeld,
      dispatch,
      dispatchSelection,
      onStoreSelect,
      toolDrafts,
    ],
  );

  // Sub-selection focus (#16): id of the keyframe glyph the user
  // has parked attention on, or null when focus is clear. Sits
  // orthogonal to entity selection — a focused glyph lives inside
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
    // there — the user is still parked on the entity. Second Esc
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

  // Builder mutations all flow through `engine.dispatch` so undo /
  // redo / future external-director piping has one funnel.
  const handleAddPeer = useCallback(
    (worldX: number, worldY: number) => {
      const drafts = toolDrafts.read();
      const typedId = drafts.peerId.trim();
      const typedLabel = drafts.peerLabel.trim();
      const newId = engine.dispatch({
        kind: "add-peer",
        profile: drafts.peerProfile,
        position: { x: worldX, y: worldY },
        ...(typedId.length > 0 ? { id: typedId } : {}),
        ...(typedLabel.length > 0 ? { label: typedLabel } : {}),
      });
      // On successful create with a user-typed id, clear the field
      // so the next drop doesn't double-fire the same id and trip
      // the collision check. (Empty → engine resumes peer-N
      // autogen on the next click.) Profile sticks because the
      // user often drops several of the same kind in a row.
      if (
        newId !== undefined && (typedId.length > 0 || typedLabel.length > 0)
      ) {
        toolDrafts.update({ peerId: "", peerLabel: "" });
      }
    },
    [engine, toolDrafts],
  );

  /** Second click of Open Session landing on empty canvas: run the session
   *  out to an end nothing has attributed, standing where the click landed.
   *  Only offered while a peer is armed, because a session needs somewhere
   *  to run FROM; with nothing armed an empty click still clears. */
  const handleOpenSessionToNewEnd = useCallback(
    (worldX: number, worldY: number) => {
      const from = state.firstPickNodeId;
      if (from === null) return;
      const drafts = toolDrafts.read();
      openSessionToNewEnd(
        engine,
        from,
        { x: worldX, y: worldY },
        dispatch,
        dispatchSelection,
        {
          codec: drafts.sessionCodec,
          captpVersion: drafts.sessionCaptpVersion,
          initialState: drafts.sessionInitialState,
        },
      );
    },
    [engine, state.firstPickNodeId, toolDrafts, dispatch, dispatchSelection],
  );

  // Node drag bracketed in an engine transaction so the many
  // pointermove snapshots collapse into a single undo step. A node is a
  // peer or a session end nothing has attributed; both take an authored
  // position. Multi-select arrives as one `group` and lands through
  // `repositionNodes` so the layout solves once per pointermove, not once
  // per selected node.
  const handleNodeDrag = useCallback(
    (
      kind: "peer" | "endpoint",
      nodeId: string,
      phase: "start" | "move" | "end",
      worldX: number,
      worldY: number,
      group?: ReadonlyArray<{
        kind: "peer" | "endpoint";
        id: string;
        x: number;
        y: number;
      }>,
    ) => {
      if (phase === "end") {
        engine.endTransaction();
        return;
      }
      if (phase === "start") {
        engine.beginTransaction(
          group !== undefined && group.length > 1
            ? "Move selection"
            : kind === "peer"
            ? "Move peer"
            : "Move session end",
        );
      }
      const members = group ?? [{ kind, id: nodeId, x: worldX, y: worldY }];
      engine.repositionNodes(
        members.map((m) => ({
          kind: m.kind,
          id: m.id,
          position: { x: m.x, y: m.y },
        })),
      );
    },
    [engine],
  );

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
  const builderEditor = useMemo<EditorBindings>(
    () => ({
      onUpdatePeer: (peerId, patch) =>
        engine.dispatch({ kind: "update-peer", peerId, patch }),
      onRepositionPeer: (peerId, position) =>
        engine.dispatch({ kind: "reposition-peer", peerId, position }),
      onUnpinPeer: (peerId) =>
        engine.dispatch({ kind: "clear-peer-position", peerId }),
      onRepositionEndpoint: (endpointId, position) =>
        engine.dispatch({ kind: "reposition-endpoint", endpointId, position }),
      onUnpinEndpoint: (endpointId) =>
        engine.dispatch({ kind: "clear-endpoint-position", endpointId }),
      onUpdateSession: (sessionId, patch) =>
        engine.dispatch({ kind: "update-session", sessionId, patch }),
      onUpdateMessage: (messageId, patch) =>
        engine.dispatch({ kind: "update-message", messageId, patch }),
      onMoveEvent: (move) => engine.dispatch({ kind: "move-event", move }),
      onMoveEntitySpan: (move) =>
        engine.dispatch({ kind: "move-entity-span", move }),
      onSetPeerDuration: (peerId, duration) =>
        engine.dispatch({ kind: "set-peer-duration", peerId, duration }),
      onClearPeerEnd: (peerId) =>
        engine.dispatch({ kind: "clear-peer-end", peerId }),
      onSetPeerStart: (peerId, t) =>
        engine.dispatch({ kind: "set-peer-start", peerId, t }),
      onClearPeerStart: (peerId) =>
        engine.dispatch({ kind: "clear-peer-start", peerId }),
      onSetSessionStart: (sessionId, t) =>
        engine.dispatch({ kind: "set-session-start", sessionId, t }),
      onClearSessionStart: (sessionId) =>
        engine.dispatch({ kind: "clear-session-start", sessionId }),
      onSetMessageStart: (messageId, t) =>
        engine.dispatch({ kind: "set-message-start", messageId, t }),
      onClearMessageStart: (messageId) =>
        engine.dispatch({ kind: "clear-message-start", messageId }),
      onSetMessageDuration: (messageId, duration) =>
        engine.dispatch({ kind: "set-message-duration", messageId, duration }),
      onSetSessionDuration: (sessionId, duration) =>
        engine.dispatch({ kind: "set-session-duration", sessionId, duration }),
      onClearSessionEnd: (sessionId) =>
        engine.dispatch({ kind: "clear-session-end", sessionId }),
      onSetSessionKeyframe: (sessionId, property, t, value) =>
        engine.dispatch({
          kind: "set-session-keyframe",
          sessionId,
          property,
          t,
          value,
        }),
      onRemoveSessionKeyframe: (sessionId, property, t) =>
        engine.dispatch({
          kind: "remove-session-keyframe",
          sessionId,
          property,
          t,
        }),
      onUpdateSessionEndpoint: (sessionId, side, patch) =>
        engine.dispatch({
          kind: "update-session-endpoint",
          sessionId,
          side,
          patch,
        }),
      onSetPeerUpdate: (peerId, t, property, value) =>
        engine.dispatch({
          kind: "set-peer-update",
          peerId,
          t,
          property,
          value,
        }),
      onRemovePeerUpdate: (peerId, t, property) =>
        engine.dispatch({ kind: "remove-peer-update", peerId, t, property }),
      onSetSessionInitialState: (sessionId, state) =>
        engine.dispatch({
          kind: "set-session-initial-state",
          sessionId,
          state,
        }),
      beginEdit: (label) => engine.beginTransaction(label),
      endEdit: () => engine.endTransaction(),
      validateRename: (kind, oldId, newId) =>
        engine.validate({ kind: `rename-${kind}`, oldId, newId }),
      onRename: (kind, oldId, newId) => {
        // Pre-flight so we don't go through dispatch's bus path
        // for the inline-shown case. The Inspector renders the
        // returned error via <FieldError>; no toast.
        const v = engine.validate({ kind: `rename-${kind}`, oldId, newId });
        if (!v.ok) return v;
        engine.dispatch({ kind: `rename-${kind}`, oldId, newId });
        // Re-anchor the selection at the new id so the Inspector
        // keeps tracking the entity post-rename.
        onEntityRenamed(kind, oldId, newId);
        return v;
      },
      onDelete: (selection) => {
        if (!selection) return;
        // An unattributed end is not deletable: it is one of the two ends
        // its session HAS, so removing it would leave a session with one.
        // Deleting the session takes it, which is the act the user means.
        if (selection.kind === "endpoint") return;
        if (selection.kind === "peer") {
          engine.dispatch({ kind: "delete-peer", peerId: selection.id });
        } else if (selection.kind === "session") {
          engine.dispatch({ kind: "delete-session", sessionId: selection.id });
        } else {
          engine.dispatch({ kind: "delete-message", messageId: selection.id });
        }
        onClearStoreSelection();
      },
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
      // the group is empty (preserves the prior behavior for
      // legacy Inspector-driven deletes).
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
              engine.dispatch({ kind: "delete-peer", peerId: id });
            } else if (kind === "session") {
              engine.dispatch({ kind: "delete-session", sessionId: id });
            } else if (kind === "message") {
              engine.dispatch({ kind: "delete-message", messageId: id });
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
  // Both surfaces that offer the command — the top bar's buttons and
  // the Cmd-Z binding — come through this pair, so there is one place
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
  // "Non-empty selection wins" stands in for explicit panel focus —
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
  // Clipboard slot for Cmd-C / Cmd-V. Lives in a ref so it survives
  // re-renders without forcing them; survives mode changes (Build →
  // Play → Build) so a copy still pastes after a quick mode jaunt.
  // Cleared by closing/reloading the tab — same as system clipboards
  // on session boundaries.
  const clipboardRef = useRef<ClipboardPayload | null>(null);

  const selectionToPayloadInput = useCallback(() => {
    const peers = new Set<string>();
    const sessions = new Set<string>();
    const messages = new Set<string>();
    for (const key of selection) {
      const { kind, id } = parseEntityKey(key);
      if (kind === "peer") peers.add(id);
      else if (kind === "session") sessions.add(id);
      else if (kind === "message") messages.add(id);
    }
    return { peers, sessions, messages };
  }, [selection]);

  const remapToSelectionKeys = useCallback(
    (remap: IdRemap): Set<EntityRefKey> => {
      const out = new Set<EntityRefKey>();
      for (const [, newId] of remap.peer) out.add(`peer:${newId}`);
      for (const [, newId] of remap.session) out.add(`session:${newId}`);
      for (const [, newId] of remap.message) out.add(`message:${newId}`);
      return out;
    },
    [],
  );

  const handleCopySelection = useCallback(() => {
    if (!engine || selection.size === 0) return;
    clipboardRef.current = engine.extractPayload(selectionToPayloadInput());
  }, [engine, selection, selectionToPayloadInput]);

  const handlePasteClipboard = useCallback(() => {
    if (!engine || !clipboardRef.current) return;
    const r = engine.paste(clipboardRef.current);
    if (r.ok) {
      const newKeys = remapToSelectionKeys(r.value.remap);
      if (newKeys.size > 0) onSetSelection(newKeys);
    }
  }, [engine, onSetSelection, remapToSelectionKeys]);

  const handleDuplicateSelection = useCallback(() => {
    if (!engine || selection.size === 0) return;
    const r = engine.duplicate(selectionToPayloadInput());
    if (r.ok) {
      const newKeys = remapToSelectionKeys(r.value.remap);
      if (newKeys.size > 0) onSetSelection(newKeys);
    }
  }, [
    engine,
    selection,
    selectionToPayloadInput,
    onSetSelection,
    remapToSelectionKeys,
  ]);

  useShortcutBindings(shortcuts, {
    engine,
    mode: state.mode,
    onDeselect: handleDeselect,
    onDelete: handleDeleteSelection,
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
  const inspectorKey = shown.anchor
    ? `${shown.anchor.kind}:${shown.anchor.id}`
    : "none";

  return (
    <div
      className="ocv-app-root"
      style={appShellStyle(sizes, bottomPaneHeight)}
    >
      <header style={topBar}>
        <div style={brand}>
          <Brandmark size={20} />
          <span style={wordmark}>ocapnviz</span>
          <span style={breadcrumbSep} aria-hidden="true">/</span>
          <span style={breadcrumbCurrent}>{scenarioTitle}</span>
        </div>
        <span style={headerSpacer} />
        <ModeToggle
          mode={state.mode}
          recording={liveRecording}
          onChange={onModeChange}
        />
        {state.mode === "build" && engine && (
          <UndoRedoControls
            engine={engine}
            onUndo={handleUndo}
            onRedo={handleRedo}
          />
        )}
        {
          /* New/Save/Open available in all modes — Save persists the
            buffer (recording / fixture / file), and New and Open both
            replace it. */
        }
        <SaveOpenControls
          recording={liveRecording}
          onNew={onNew}
          onSave={handleSave}
          onOpen={onOpen}
        />
        <button
          type="button"
          className="ocv-btn is-ghost"
          onClick={onResetLayout}
          title="Reset panel sizes, layer visibility, and the timeline view"
        >
          Reset layout
        </button>
        <ThemeToggle theme={theme} onToggle={onToggleTheme} />
        <ReferenceButton
          onOpen={() => setReference(DEFAULT_REFERENCE_SECTION)}
        />
      </header>

      <aside style={leftPane} className="ocv-pane">
        <Section title="Tools">
          <div style={toolsPanel} className="ocv-tools-panel">
            <ToolPalette
              mode={state.mode}
              tool={state.tool}
              onPick={(tool) => dispatch({ type: "set-tool", tool })}
            />
            {
              /* Commands, not tools, so they sit under the strip with text
                labels rather than inside the radiogroup. They belong in
                this section because Tools is where the left pane keeps what
                acts on the composition; Source and Legend describe it. In
                rising order of what they take away. */
            }
            <ToolCommandRow mode={state.mode}>
              <UnpinAllButton engine={engine} mode={state.mode} />
              <UndoAllButton
                engine={engine}
                mode={state.mode}
                dispatchSelection={dispatchSelection}
              />
              <DiscardAllButton
                engine={engine}
                mode={state.mode}
                dispatchSelection={dispatchSelection}
              />
            </ToolCommandRow>
          </div>
        </Section>
        {
          /* Live has no document — it has a connection and a stream — so the
            panel says what there is to say in each case, and its own title
            names which. `DocumentFields` carries the description in Play and
            Build, so there is no second copy of it here. */
        }
        <Section title={state.mode === "live" ? "Connection" : "Document"}>
          <SourcePicker
            mode={state.mode}
            scenarioId={state.scenarioId}
            source={sourceInfo}
            engine={engine}
            liveUrl={state.liveUrl}
            liveConnected={liveConnected}
            liveRecording={liveRecording}
            onScenarioChange={handleScenarioChange}
            onLiveUrlChange={(url) => dispatch({ type: "set-live-url", url })}
            editor={state.mode === "build" ? builderEditor : undefined}
          />
        </Section>
        <Section
          title="Legend"
          action={
            <LegendReferenceButton
              onOpen={() => setReference(DEFAULT_REFERENCE_SECTION)}
            />
          }
        >
          <LegendBody />
        </Section>
        <ResizeHandle
          axis="x"
          edge="right"
          label="Left panel width"
          title="Drag or use the left and right arrow keys to resize"
          onDelta={(d) =>
            onResize((s) => ({ ...s, leftPaneWidth: s.leftPaneWidth + d }))}
        />
      </aside>

      <section style={centerPane}>
        {
          /* Every mode gets the bar: it names the active tool and
            its gesture tip above the stage; the authoring option
            fields only exist for authoring tools, which only exist
            in Build. */
        }
        {engine && (
          <div style={{ pointerEvents: "auto" }}>
            <ToolOptionsBar
              tool={state.tool}
              engine={engine}
              drafts={toolDrafts}
              armedLabel={armedNodeLabel(engine, state.firstPickNodeId)}
              onCancelArmed={handleDeselect}
            />
          </div>
        )}
        <div style={stageSlot}>
          <Stage
            engine={engine}
            onSelect={handleSelect}
            theme={theme}
            visibility={visibility}
            // An empty-canvas click means something to two tools. Add Peer
            // places one. Open Session, once a peer is armed, runs the
            // session out to an end nothing has attributed — the shape a
            // recording holds when a peer has dialed and nothing has yet
            // answered for who answered.
            onCanvasClick={state.mode !== "build" || spaceHeld
              ? undefined
              : state.tool === "add-peer"
              ? handleAddPeer
              : state.tool === "open-session" && state.firstPickNodeId !== null
              ? handleOpenSessionToNewEnd
              : undefined}
            // Drag-to-reposition is a Select-tool gesture. With any
            // other build tool, a click that strays > 4px between
            // pointerdown and pointerup would otherwise convert into
            // a peer reposition, swallowing the two-click pick — a
            // surprisingly easy way to misfire when the cursor is
            // tracking marching ants. Keep peer drag scoped to Select.
            // Also gated on spacebar: hand-tool override beats peer
            // drag (Adobe convention), so a pan that starts on a peer
            // body actually pans the view instead of grabbing the
            // peer underneath.
            onNodeDrag={state.mode === "build" && state.tool === "select" &&
                !spaceHeld
              ? handleNodeDrag
              : undefined}
            armedNode={state.mode === "build" && state.firstPickNodeId &&
                (state.tool === "open-session" ||
                  state.tool === "send-message")
              ? { nodeId: state.firstPickNodeId, tool: state.tool }
              : undefined}
            // Single source for the resolver, the hover preview, the
            // canvas cursor, and layer pointer-events (§ 7): while a
            // pan affordance is active the whole stage goes
            // event-transparent so the FSM's pan verbs get the
            // pointerdown even on a peer body.
            //
            // The App's one gesture context — the Timeline's surfaces read
            // the same value, so the two agree by construction.
            gestureCtx={gestureCtx}
            selection={selection}
            anchor={anchor ? `${anchor.kind}:${anchor.id}` : null}
            onRubberBandCommit={onRubberBandCommit}
          />
          {
            /* Every mode: the banner's pan notice follows Space,
              which pans over the stage everywhere; its two-click
              flow hints only speak for authoring tools, which only
              exist in Build. */
          }
          {engine && (
            <ToolHint
              tool={state.tool}
              armedNodeLabel={armedNodeLabel(engine, state.firstPickNodeId)}
              spaceHeld={spaceHeld}
            />
          )}
          {
            /* Every mode: a camera is a camera whether the buffer came from a
              file, a recording, or the wire, and reading a crowded stage is
              exactly when Live wants a zoom out. Gated on `engine` only because
              with no buffer there is no stage to aim at. */
          }
          {engine && <StageControls />}
        </div>
      </section>

      <aside style={rightPane} className="ocv-pane">
        <ResizeHandle
          axis="x"
          edge="left"
          label="Right panel width"
          title="Drag or use the left and right arrow keys to resize"
          onDelta={(d) =>
            onResize((s) => ({ ...s, rightPaneWidth: s.rightPaneWidth - d }))}
        />
        {
          /* Section title swaps: "DETAILS" when nothing is
            selected (consistent with sibling sections — the pane
            reads as a labeled empty placeholder), then *replaced*
            by the entity's own heading (name + pill, rendered
            inside the body) once a selection lands. The two
            never coexist — when a heading is present it IS the
            label, so a "DETAILS" header above it would only
            duplicate the FieldGroup "Details" rectangle title
            further down.

            Decided from `shown`, not from the selection: in Live the
            selection is kept so returning to Play restores it, and
            it names entities the live stream has never heard of.
            Every part of the pane reads `shown` for that reason —
            `inspectorView` is where the two are told apart, and a
            part that asked for itself is how a titleless empty pane
            got in. */
        }
        <Section {...(shown.anchor ? {} : { title: "Details" })}>
          <div className="ocv-inspector-swap" key={`details-${inspectorKey}`}>
            <EntityDetails
              engine={engine}
              anchor={shown.anchor}
              onSelect={handleSelect}
              editor={state.mode === "build" ? builderEditor : undefined}
              entitySelection={shown.selection}
              onNarrowSelection={onSetSelection}
            />
          </div>
        </Section>
        <Section
          title={connectionsSectionTitle(engine, shown.anchor)}
        >
          <div
            className="ocv-inspector-swap"
            key={`connections-${inspectorKey}`}
          >
            <EntityConnections
              engine={engine}
              anchor={shown.anchor}
              onSelect={handleSelect}
              entitySelection={shown.selection}
            />
          </div>
        </Section>
      </aside>

      {
        /* Timeline panel — always rendered so the bottom bar
          doesn't disappear-and-reappear on mode switches. In
          Live mode the panel still shows the live-feed events
          and the live edge, but interaction is disabled: no
          scrub / seek / play (the feed is forward-only). The
          `disabled` prop mutes the chrome and short-circuits
          the pointer handlers — visually the user reads
          "timeline is here, just not yours to steer right now,"
          which is the honest live semantic. */
      }
      {engine && (
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
              if (state.autoSizeTimeline) {
                dispatch({ type: "set-auto-size-timeline", value: false });
              }
              // Drag UP = pane grows (pointer y delta positive
              // going down, so subtract). Drag DOWN shrinks the
              // pane; when intrinsic > pane the lanes region
              // overflows with internal scroll (handled in the
              // Scrubber). Hard floor at `BOTTOM_PANE_MIN`
              // keeps control row + ruler always visible.
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
            engine={engine}
            onPlayPause={handlePlayPause}
            onRestart={handleRestart}
            onSetSpeed={handleSetSpeed}
            onSeek={handleSeek}
            onScrubStart={handleScrubStart}
            onScrubEnd={handleScrubEnd}
            selection={anchor}
            onSelectEvent={handleSelect}
            focusedEventId={focusedEventId}
            onFocusEvent={setFocusedEventId}
            onMoveEvent={state.mode === "build"
              ? builderEditor.onMoveEvent
              : undefined}
            onMoveEntitySpan={state.mode === "build"
              ? builderEditor.onMoveEntitySpan
              : undefined}
            beginEdit={state.mode === "build"
              ? builderEditor.beginEdit
              : undefined}
            endEdit={state.mode === "build" ? builderEditor.endEdit : undefined}
            cycleRowVisibility={engine
              ? (category, entityId) => {
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
                const current = engine.rowVisMode(category, entityId);
                const next = current === "visible"
                  ? "label"
                  : current === "label"
                  ? "body"
                  : current === "body"
                  ? "both"
                  : "visible";
                engine.dispatch({
                  kind: "set-row-vis-mode",
                  category,
                  id: entityId,
                  mode: next,
                });
              }
              : undefined}
            cycleCategoryVisibility={engine
              ? (category) => {
                // Category eyeball: same 4-mode cycle as the per-
                // entity eyeball (visible → label → body → both →
                // visible) — applies uniformly to every entity in
                // the category. Mixed state collapses to "visible"
                // first so the user gets a clean-slate reset, and
                // the next click starts the deterministic cycle.
                const next = nextVisCycleStep(engine.categoryVisMode(category));
                engine.dispatch({
                  kind: "set-category-vis-mode",
                  category,
                  mode: next,
                });
              }
              : undefined}
            cycleAllVisibility={engine
              ? () => {
                // Master "all rows" eyeball — same cycle as the
                // per-category one, applied across every category.
                // Same lossy / opt-in semantics: the user accepts
                // wiping per-entity overrides for the convenience.
                const next = nextVisCycleStep(engine.allVisMode());
                engine.dispatch({ kind: "set-all-vis-mode", mode: next });
              }
              : undefined}
            commitRowReorder={state.mode === "build"
              ? (category, order) =>
                asOneEdit(engine, "Reorder timeline rows", () => {
                  engine.dispatch({ kind: "reorder-row", category, order });
                })
              : undefined}
            selectionSet={selection}
            onSetSelection={onSetSelection}
            onEditSelection={onTimelineEditSelection}
            gestureCtx={gestureCtx}
            onIntrinsicHeightChange={onTimelineIntrinsicChange}
            onMinHeightChange={onTimelineMinHeightChange}
            autoSizeTimeline={state.autoSizeTimeline}
            onSetAutoSizeTimeline={(value) =>
              dispatch({ type: "set-auto-size-timeline", value })}
            disabled={state.mode === "live"}
            live={state.mode === "live"
              ? {
                connected: liveConnected,
                recording: liveRecording,
                bufferHasContent:
                  (bufferEngine ? observationsOf(bufferEngine.doc).length : 0) >
                    0,
                onStartRecord,
                onStopRecord,
                onDiscardRecording,
              }
              : undefined}
            onBulkDelete={state.mode === "build"
              ? (entities) =>
                // N delete-* dispatches as one undo step, because the
                // reader asked for one thing. Cascading deletes (a
                // peer taking its sessions and their messages) de-dup
                // naturally via the engine's own no-op guard.
                asOneEdit(
                  engine,
                  entities.size === 1
                    ? "Delete entity"
                    : `Delete ${entities.size} entities`,
                  () => {
                    for (const key of entities) {
                      const ref = parseEntityKey(key);
                      if (ref.kind === "peer") {
                        engine.dispatch({
                          kind: "delete-peer",
                          peerId: ref.id,
                        });
                      } else if (ref.kind === "session") {
                        engine.dispatch({
                          kind: "delete-session",
                          sessionId: ref.id,
                        });
                      } else if (ref.kind === "message") {
                        engine.dispatch({
                          kind: "delete-message",
                          messageId: ref.id,
                        });
                      }
                    }
                  },
                )
              : undefined}
          />
        </div>
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
