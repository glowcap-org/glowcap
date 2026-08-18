/**
 * TimelinePanel — the bottom bar's canvas regions and the view they
 * share.
 *
 * Layout: the [`TimelineToolbar`] control row, then the [`Overview`]
 * strip and [`Scrubber`] stacked in a flexible slot that the unified
 * canvas paints into.
 *
 * Owns the [`TimelineView`] state via `useReducer` so scrub +
 * wheel updates don't round-trip through the App reducer. Selection
 * keyboard verbs live in `use-timeline-selection-keys.ts`. The
 * durable prefs (expanded lanes / categories, gutter width) persist
 * across sessions; the window resets to fit-all only when a
 * different document loads (by doc id — growth of the same live
 * doc keeps the user's zoom).
 */

import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import type { MoveIntent, MoveSpanIntent } from "../../engine/authoring/moves.ts";
import type { Engine } from "../../engine/engine.ts";
import type { TimelineEvent } from "../../engine/timeline.ts";
import { observationsOf } from "../../engine/temporal/recording-access.ts";
import { formatClockTime as formatTime } from "../format.ts";
import type { StageSelection } from "../../render/types.ts";
import { type EntityRefKey, type SelectMode, type SurfaceGestureCtx } from "../../interactions/types.ts";
import { useClockSnapshot } from "../useClockSnapshot.ts";
import { useDocVersion } from "../useDocVersion.ts";
import { loadPersistedTimelineView, savePersistedTimelineView } from "../../state/app-state.ts";
import { c, FONT, SIZE } from "../tokens.ts";
import { Overview, OVERVIEW_HEIGHT } from "./Overview.tsx";
import { MAX_LIVE_WINDOW_MS, Scrubber } from "./Scrubber.tsx";
import type { LaneKind } from "./state.ts";
import { defaultView, MIN_WINDOW_MS, type TimelineView, zoomAround } from "./state.ts";
import { type TimelineLive, TimelineToolbar } from "./timeline-toolbar.tsx";
import { useTimelineSelectionKeys } from "./use-timeline-selection-keys.ts";

/** React-`setState`-shaped view setter. The updater form is
 * required by wheel handlers — they fire faster than React
 * renders, so deltas need to stack on the latest state, not a
 * closure-captured snapshot. */
export type SetView = (
  next: TimelineView | ((current: TimelineView) => TimelineView),
) => void;

/** Reducer intent. Scrubber + toolbar funnel through one
 * mutation point. The legacy `set-follow-live` / `live-advance`
 * intents are gone — Live mode renders its own UI without the
 * Timeline panel, so the "follow the live edge while scrubbing"
 * machinery is unreachable. */
type TimelineIntent =
  | { kind: "set-view"; view: TimelineView }
  | { kind: "set-view-fn"; fn: (s: TimelineView) => TimelineView }
  | { kind: "toggle-lane"; lane: LaneKind }
  /** Flash-grade timeline: flip whether a category lane renders
   * as today's stacked-spans summary or expands into per-entity
   * rows. */
  | { kind: "toggle-category"; category: Exclude<LaneKind, "ruler"> };

function reducer(state: TimelineView, action: TimelineIntent): TimelineView {
  switch (action.kind) {
    case "set-view":
      return action.view;
    case "set-view-fn":
      return action.fn(state);
    case "toggle-lane": {
      const next = new Set(state.expandedLanes);
      if (next.has(action.lane)) next.delete(action.lane);
      else next.add(action.lane);
      return { ...state, expandedLanes: next };
    }
    case "toggle-category": {
      const next = new Set(state.expandedCategories);
      if (next.has(action.category)) next.delete(action.category);
      else next.add(action.category);
      return { ...state, expandedCategories: next };
    }
  }
}

export type TimelinePanelProps = {
  /** Subscribed locally via `useClockSnapshot` so the rest of the
   * app doesn't re-reconcile on every Pixi tick. */
  engine: Engine;
  onPlayPause: () => void;
  onRestart: () => void;
  onSetSpeed: (speed: number) => void;
  onSeek: (t: number) => void;
  onScrubStart: () => void;
  onScrubEnd: () => void;
  /** Current entity selection — drawn as a halo on matching
   * Scrubber spans / glyphs. */
  selection: StageSelection;
  /** Phase 1 — click an event in the Scrubber to select its
   * parent entity. Optional: when undefined the Scrubber falls
   * through to scrub-on-click everywhere. The explicit `|
   * undefined` is required under `exactOptionalPropertyTypes`. */
  onSelectEvent?: ((selection: StageSelection) => void) | undefined;
  /** Sub-selection state machine (#16). Forwarded straight to the
   *  Scrubber — TimelinePanel doesn't otherwise care about glyph
   *  focus, but owning the prop here keeps App's wiring symmetric
   *  with `selection` / `onSelectEvent`. */
  focusedEventId?: string | null;
  onFocusEvent?: ((eventId: string | null) => void) | undefined;
  /** Phase 2 / 3 — drag an event pill (or right-edge handle on
   * a message) to retime via the engine's `move-event` intent. */
  onMoveEvent?: ((move: MoveIntent) => void) | undefined;
  onMoveEntitySpan?: ((move: MoveSpanIntent) => void) | undefined;
  /** Engine transaction bracket; collapses a drag burst into one
   * undo step. */
  beginEdit?: ((label: string) => void) | undefined;
  endEdit?: (() => void) | undefined;
  /** Flash-grade timeline — row-management dispatchers. Undefined
   * outside Build mode so the chevron / eyeballs / row-drag are
   * decorative (Play mode shows expanded rows but doesn't mutate
   * row order or visibility from the timeline). */
  cycleRowVisibility?:
    | ((category: "peers" | "sessions" | "messages", entityId: string) => void)
    | undefined;
  cycleCategoryVisibility?:
    | ((category: "peers" | "sessions" | "messages") => void)
    | undefined;
  /** Master "all rows" cycle — same 4-state vocabulary as the
   * per-row / per-category eyeballs, applied across every entity
   * in every category. The eyeball lives in the Overview's
   * gutter next to its "overview" label so all the gutter
   * eyeballs (all → category → entity) stack into one control
   * column. Mode is read from `engine.allVisMode()` here and
   * forwarded to `Overview` — it already subscribes to engine
   * version, so the glyph stays in lockstep with the doc. */
  cycleAllVisibility?: (() => void) | undefined;
  commitRowReorder?:
    | ((
      category: "peers" | "sessions" | "messages",
      order: string[],
    ) => void)
    | undefined;
  /** Bulk-delete every selected entity (and its events) in one
   * transaction. Undefined outside Build mode. */
  onBulkDelete?: ((entities: ReadonlySet<EntityRefKey>) => void) | undefined;
  /** Unified entity selection (selection-store §6). The Scrubber
   * highlights every event whose entityRef key is in this set;
   * keyboard verbs (Cmd-A / Escape / Delete) read it; rubber-band
   * + click toggles write back via the callbacks below. */
  selectionSet: ReadonlySet<EntityRefKey>;
  /** Replace the entire entity selection. Used by Cmd-A
   * (select-visible), Escape (clear), and Scrubber rubber-band
   * commits (additive mode computes the union at the call
   * site). */
  onSetSelection: (entities: ReadonlySet<EntityRefKey>) => void;
  /** Selection gesture on a pill or the marquee — forwarded to the
   * one select-mode interpreter (`selectionActionFor`). */
  onEditSelection: (
    entities: ReadonlySet<EntityRefKey>,
    mode: SelectMode,
  ) => void;
  /** The App's gesture context, forwarded to both canvas surfaces so their
   * cursors come from the same value the Stage's does. */
  gestureCtx: SurfaceGestureCtx;
  /** Toggle a single entity in the selection (shift/cmd-click
   * on an event in the Scrubber). */
  /** Report the minimum panel height needed to render the
   * current expansion state without dropping rows off the
   * bottom. App uses this to drive the "fit to content"
   * affordance — the pane is no longer auto-grown. */
  onIntrinsicHeightChange?: ((px: number) => void) | undefined;
  /** Report the collapsed-fit panel height — chrome plus the
   *  scrubber with every category collapsed. That is App's drag
   *  floor: expand a category and you can drag between this and
   *  the live intrinsic; you cannot drag below this. */
  onMinHeightChange?: ((px: number) => void) | undefined;
  /** Current state of the persistent "auto-size pane to content"
   * toggle. The panel renders a checkbox in the topbar bound to
   * this; toggling fires `onSetAutoSizeTimeline`. While true,
   * App's effect pins the pane height to the live intrinsic
   * (current expansion). Drag floors at the collapsed-fit height
   * from `onMinHeightChange` instead. */
  autoSizeTimeline?: boolean | undefined;
  onSetAutoSizeTimeline?: ((value: boolean) => void) | undefined;
  /** Live mode flag — when true, the panel renders normally
   * (so the bottom bar doesn't pop in / out on mode switches)
   * but interaction is suppressed: control-row buttons are
   * disabled, the Scrubber's pointer handlers no-op, and a
   * "LIVE" badge in the control row makes the state legible.
   * The events lane + playhead still update from the live
   * feed so the user sees the feed advancing — it's just not
   * theirs to steer. */
  disabled?: boolean | undefined;
  /** Live-mode bundle. Carries everything the control row needs
   * to render Live's Record / Stop verb and the connection
   * badge in one place. Provided iff `disabled` is true; when
   * absent, the control row falls back to Play / Build's
   * scrubable playback buttons. */
  live?: TimelineLive | undefined;
};

export function TimelinePanel(
  {
    engine,
    onPlayPause,
    onRestart,
    onSetSpeed,
    onSeek,
    onScrubStart,
    onScrubEnd,
    selection,
    onSelectEvent,
    focusedEventId,
    onFocusEvent,
    onMoveEvent,
    onMoveEntitySpan,
    beginEdit,
    endEdit,
    cycleRowVisibility,
    cycleCategoryVisibility,
    cycleAllVisibility,
    commitRowReorder,
    disabled,
    live,
    onBulkDelete,
    selectionSet,
    onSetSelection,
    onEditSelection,
    gestureCtx,
    onIntrinsicHeightChange,
    onMinHeightChange,
    autoSizeTimeline,
    onSetAutoSizeTimeline,
  }: TimelinePanelProps,
) {
  // Subscribe to the document version (for edits like rowHidden /
  // rowOrder / event mutations) and the clock (for the playhead).
  // `useEngineVersion` would also wake on every playback frame's
  // layout tick; `useDocVersion` stays quiet while the clock alone
  // runs, and a mid-drag placement inside a transaction does not
  // bump it either — the gesture's endTransaction is the edit.
  useDocVersion(engine);
  const doc = engine.doc;
  const clock = useClockSnapshot(engine);
  const [view, dispatch] = useReducer(
    reducer,
    null,
    () => {
      // Persisted view overlays the doc-relative default. Window
      // start/end aren't restored (they depend on doc duration);
      // expanded sets + gutter width ARE — those are user choices
      // that should survive a reload like the other UI prefs.
      const base = defaultView(doc.duration);
      const persisted = loadPersistedTimelineView();
      if (!persisted) return base;
      return {
        ...base,
        ...(persisted.expandedLanes ? { expandedLanes: new Set(persisted.expandedLanes) } : {}),
        ...(persisted.expandedCategories ? { expandedCategories: new Set(persisted.expandedCategories) } : {}),
        ...(typeof persisted.gutterWidth === "number" ? { gutterWidth: persisted.gutterWidth } : {}),
      };
    },
  );

  // Persist the durable UI bits of the view — expanded lanes /
  // categories / gutter width — same idiom as `useLayoutSizes` and
  // `useStageVisibility`. Done in an effect (not in the reducer)
  // so the persistence path stays out of the hot update loop.
  useEffect(() => {
    savePersistedTimelineView({
      expandedLanes: [...view.expandedLanes],
      expandedCategories: [...view.expandedCategories],
      ...(typeof view.gutterWidth === "number" ? { gutterWidth: view.gutterWidth } : {}),
    });
  }, [view.expandedLanes, view.expandedCategories, view.gutterWidth]);

  // Dev / test introspection — the current timeline view sits on
  // `__ocv.timelineView` so probes can verify gutter-resize and
  // other view edits without re-implementing React internals.
  useEffect(() => {
    const g = globalThis as unknown as {
      __ocv?: Record<string, unknown>;
    };
    if (!g.__ocv) g.__ocv = {};
    g.__ocv.timelineView = view;
  }, [view]);

  useTimelineSelectionKeys({
    doc,
    windowStart: view.windowStart,
    windowEnd: view.windowEnd,
    selectionSet,
    onSetSelection,
    onBulkDelete,
  });

  // Hover-ghost t lifted up so Overview and Scrubber share one t.
  // The ghost is one conceptual playhead drawn across both
  // surfaces. A box rather than state: both surfaces write it on
  // every pointermove, and the only readers are their own Pixi
  // tickers, which read it once a frame. Nothing renders it, so as
  // state it reconciled this whole panel at pointer-event rate —
  // worst while paused, where the engine only notifies on change
  // and hover was then the only thing re-rendering at all.
  const hoverTRef = useRef<number | null>(null);

  // Reset the doc-relative half of the view (the window) when a
  // DIFFERENT document loads — a scenario switch, an opened file.
  // Identity is the doc's `id`, never the object reference: a live
  // doc grows through a fresh object on every arriving event, and
  // growth must not eject the user from their zoom. The durable
  // user prefs (expanded lanes / categories, gutter width) always
  // carry over — they belong to the user, not the document; only
  // the window depends on the doc's duration.
  const lastDocIdRef = useRef(doc.id);
  useEffect(() => {
    if (lastDocIdRef.current !== doc.id) {
      lastDocIdRef.current = doc.id;
      dispatch({
        kind: "set-view-fn",
        fn: (cur) => ({
          ...defaultView(doc.duration),
          expandedLanes: cur.expandedLanes,
          expandedCategories: cur.expandedCategories,
          ...(cur.gutterWidth !== undefined ? { gutterWidth: cur.gutterWidth } : {}),
        }),
      });
    }
  }, [doc]);

  // Measure the scrubber slot width — drives `pxPerMs`. Height is
  // tracked by the Scrubber itself via `height: 100%`.
  const scrubberSlotRef = useRef<HTMLDivElement | null>(null);
  const [scrubberWidth, setScrubberWidth] = useState(0);
  useLayoutEffect(() => {
    const el = scrubberSlotRef.current;
    if (!el) return;
    const measure = () => setScrubberWidth(el.clientWidth);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Control-row chrome height + Scrubber intrinsic ⇒ total
  // TimelinePanel intrinsic. Measured (rather than constant)
  // because the control-row wraps at narrow widths.
  const controlRowRef = useRef<HTMLDivElement | null>(null);
  const [controlRowHeight, setControlRowHeight] = useState(40);
  useLayoutEffect(() => {
    const el = controlRowRef.current;
    if (!el) return;
    const measure = () => setControlRowHeight(el.offsetHeight);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const [scrubberIntrinsic, setScrubberIntrinsic] = useState(0);
  const [scrubberCollapsed, setScrubberCollapsed] = useState(0);

  // View bounds, single source of truth — wired to BOTH the
  // Overview and the Scrubber so wheel / drag / zoom on either
  // surface honors the same window-shape rules. Live mode opens
  // both ceilings up (1-week zoom-out floor, unbounded pan-right
  // — the timeline has no end); Play / Build use the captured
  // duration for both so wheeling either surface lands inside
  // `[0, duration]` (Flash convention).
  const viewMaxWidth = disabled ? MAX_LIVE_WINDOW_MS : clock.duration;
  const viewPanMaxT = disabled ? Number.POSITIVE_INFINITY : clock.duration;
  // Aggregate intrinsic = control row + overview + scrubber's
  // own intrinsic + 1px panel border. Forward to App so Fit /
  // auto-size can pin to the current expansion. Reset to 0 on
  // unmount so Live-mode (which hides this panel) lets the
  // bottom pane return to the user's preferred size.
  // Layout effect (not regular effect) so the App-side auto-size
  // pin runs before paint — see the matching note in Scrubber on
  // collapsing the expand/collapse paint chain into one frame.
  useLayoutEffect(() => {
    const total = controlRowHeight + OVERVIEW_HEIGHT + scrubberIntrinsic + 1;
    onIntrinsicHeightChange?.(total);
    return () => onIntrinsicHeightChange?.(0);
  }, [controlRowHeight, scrubberIntrinsic, onIntrinsicHeightChange]);

  // Drag floor = chrome + collapsed scrubber. Expanding a category
  // raises the live intrinsic above this; the reader can then drag
  // the pane between the two. Folding the live intrinsic into this
  // floor made an expanded panel refuse every downward drag.
  useLayoutEffect(() => {
    const min = controlRowHeight + OVERVIEW_HEIGHT + scrubberCollapsed + 1;
    onMinHeightChange?.(min);
    return () => onMinHeightChange?.(0);
  }, [controlRowHeight, scrubberCollapsed, onMinHeightChange]);

  const setView = useCallback<SetView>(
    (next) => {
      if (typeof next === "function") {
        dispatch({ kind: "set-view-fn", fn: next });
      } else {
        dispatch({ kind: "set-view", view: next });
      }
    },
    [],
  );

  const isPlaying = clock.state === "playing";

  // One scrub-start/scrub-end pair per drag.
  const scrubbingRef = useRef(false);
  const beginScrub = useCallback(() => {
    if (scrubbingRef.current) return;
    scrubbingRef.current = true;
    onScrubStart();
  }, [onScrubStart]);
  const endScrub = useCallback(() => {
    if (!scrubbingRef.current) return;
    scrubbingRef.current = false;
    onScrubEnd();
  }, [onScrubEnd]);

  const resetView = useCallback(() => {
    dispatch({
      kind: "set-view",
      view: defaultView(doc.duration),
    });
  }, [doc.duration]);

  // Zoom factor: 1× fits the full document; higher = tighter
  // window. Ceiling at `duration / MIN_WINDOW_MS` (tighter
  // degenerates the ruler ticks).
  const visibleWindow = view.windowEnd - view.windowStart;
  const zoom = visibleWindow > 0 ? doc.duration / visibleWindow : 1;
  const zoomMin = 1;
  const zoomMax = Math.max(1, doc.duration / MIN_WINDOW_MS);
  const setZoom = useCallback(
    (next: number) => {
      const center = (view.windowStart + view.windowEnd) / 2;
      const currentWidth = view.windowEnd - view.windowStart || 1;
      const currentZoom = doc.duration / currentWidth;
      const factor = next / currentZoom;
      // Use the same `viewMaxT` / `viewMaxWidth` bounds the
      // wheel handler uses, so the slider can't push the view
      // anywhere the wheel can't. Slider lives in Play / Build
      // only (Live mode hides it), so `clock.duration` is the
      // right ceiling for both bounds here.
      dispatch({
        kind: "set-view",
        view: zoomAround(
          view,
          center,
          factor,
          doc.duration,
          doc.duration,
        ),
      });
    },
    [view, doc.duration],
  );

  const visibleRangeLabel = useMemo(
    () => `${formatTime(view.windowStart)} – ${formatTime(view.windowEnd)}`,
    [view.windowStart, view.windowEnd],
  );

  return (
    <div style={panel}>
      <TimelineToolbar
        rowRef={controlRowRef}
        disabled={disabled}
        live={live}
        isPlaying={isPlaying}
        onPlayPause={onPlayPause}
        onRestart={onRestart}
        expandedLanes={view.expandedLanes}
        onToggleLane={(lane) => dispatch({ kind: "toggle-lane", lane })}
        visibleRangeLabel={visibleRangeLabel}
        zoom={zoom}
        zoomMin={zoomMin}
        zoomMax={zoomMax}
        setZoom={setZoom}
        resetView={resetView}
        autoSizeTimeline={autoSizeTimeline}
        onSetAutoSizeTimeline={onSetAutoSizeTimeline}
        t={clock.t}
        duration={clock.duration}
        speed={clock.speed}
        onSetSpeed={onSetSpeed}
      />

      {
        /*
        Overview strip + detail scrubber stacked. Both share the
        slot's measured width so canvases stay crisp on resize.
        Phase 2: overview rectangle reflects + drives `view`.
      */
      }
      {
        /* Scrubber slot. In Live mode the interaction set narrows
          (no scrub, no seek, no double-click-to-fit), but
          everything else stays live: wheel zoom + pan, marquee
          select, click entity to select, gutter chevron /
          eyeball / row reorder. Per-gesture gating happens
          inside `Scrubber` via the `disabledScrub` prop. We
          DON'T put `pointer-events: none` on the slot because
          that would kill wheel + gutter interaction too. */
      }
      <div
        ref={scrubberSlotRef}
        style={scrubberSlot}
        aria-disabled={disabled || undefined}
      >
        {live && !live.recording
          ? (
            <div style={liveIdleHint}>
              Record captures from the feed from the moment you press it. The connection is already open.
            </div>
          )
          : scrubberWidth > 0 && (
            <>
              <Overview
                view={view}
                clock={clock}
                width={scrubberWidth}
                hoverTRef={hoverTRef}
                onSetView={setView}
                allVisMode={cycleAllVisibility ? engine.allVisMode() : undefined}
                onCycleAllVisibility={cycleAllVisibility}
                viewMaxWidth={viewMaxWidth}
                viewPanMaxT={viewPanMaxT}
                gestureCtx={gestureCtx}
              />
              <Scrubber
                view={view}
                clock={clock}
                doc={doc}
                events={observationsOf(doc) as readonly TimelineEvent[]}
                entities={doc.entities}
                expandedLanes={view.expandedLanes}
                expandedCategories={view.expandedCategories}
                rowOrder={doc.rowOrder}
                rowHidden={doc.rowHidden}
                rowLabelHidden={doc.rowLabelHidden}
                rowBodyHidden={doc.rowBodyHidden}
                categoryVisMode={doc.categoryVisMode}
                selectionSet={selectionSet}
                onEditSelection={onEditSelection}
                gestureCtx={gestureCtx}
                width={scrubberWidth}
                scrubbing={scrubbingRef.current}
                hoverTRef={hoverTRef}
                onSetView={setView}
                onSeek={(t) => {
                  beginScrub();
                  onSeek(t);
                }}
                onScrubStart={beginScrub}
                onScrubEnd={endScrub}
                selection={selection}
                onSelectEvent={onSelectEvent}
                focusedEventId={focusedEventId ?? null}
                onFocusEvent={onFocusEvent}
                onMoveEvent={onMoveEvent}
                onMoveEntitySpan={onMoveEntitySpan}
                beginEdit={beginEdit}
                endEdit={endEdit}
                toggleCategory={(cat) => dispatch({ kind: "toggle-category", category: cat })}
                cycleRowVisibility={cycleRowVisibility}
                cycleCategoryVisibility={cycleCategoryVisibility}
                commitRowReorder={commitRowReorder}
                disabledScrub={disabled}
                viewMaxWidth={viewMaxWidth}
                viewPanMaxT={viewPanMaxT}
                onIntrinsicHeightChange={setScrubberIntrinsic}
                onCollapsedHeightChange={setScrubberCollapsed}
              />
            </>
          )}
      </div>
    </div>
  );
}

const liveIdleHint = {
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  height: "100%",
  color: c.textSubtle,
  fontSize: SIZE.sm,
} satisfies React.CSSProperties;

// Sans by default (chrome). Data sites that want mono (timeReadout,
// visibleRange, ScrubInput values, scrubber tick / pill labels)
// declare it inline. The earlier "mono cascades to descendants for
// uniform panel vocabulary" intent conflated the data axis with
// the chrome axis: under any pixel-grid mono font (Departure Mono)
// the leak makes Play / Restart / Fit / segmented-control labels
// render in mono and read as data, which they aren't.
const panel = {
  display: "flex",
  flexDirection: "column",
  fontFamily: FONT.sans,
  color: c.text,
  fontSize: SIZE.sm,
  // Fill the grid row so the scrubber slot has measurable
  // height to stretch into. No `minHeight` here: the bottom
  // grid row already enforces `BOTTOM_PANE_MIN`, and a panel-
  // level floor LARGER than the grid row makes the panel
  // overflow the bar (the ruler clips off-screen when the row
  // count is small — the "phantom container pushing the ruler
  // down" symptom).
  height: "100%",
} satisfies React.CSSProperties;

const scrubberSlot = {
  width: "100%",
  // `minHeight: 0` lets `flex: 1` shrink below content size.
  flex: 1,
  minHeight: 0,
  // Column flex so Overview (fixed height at top) and Scrubber
  // (`flex: 1`, fills the rest) stack and the Scrubber's bottom
  // pins to the slot's bottom. Without this, Scrubber as a block
  // child with `height: 100%` would extend past the slot bottom
  // and the ruler would paint off-viewport.
  display: "flex",
  flexDirection: "column",
} satisfies React.CSSProperties;
