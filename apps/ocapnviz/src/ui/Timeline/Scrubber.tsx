/**
 * Scrubber — the timeline's detail strip. Paints the visible
 * window (`view.windowStart` → `view.windowEnd`) with adaptive
 * ticks, per-lane span pills + glyphs, a playhead line, and a
 * click-to-seek surface. Lives in the unified PixiJS canvas; the
 * DOM marker is layout + React event capture only.
 *
 * Interactions:
 *  - Wheel over the plot: zoom around the cursor's t.
 *  - Shift+wheel over the plot: pan the window (trackpad deltaX
 *    pans without Shift).
 *  - Wheel over the gutter: scroll the lane stack vertically.
 *  - Drag in the scrub zone (ruler / below the last row): seek.
 *  - Alt+drag on empty lane space: pan the view — horizontal
 *    slides the time window, vertical scrolls the lane stack, so
 *    one gesture feels like grabbing the whole strip. Shift alone
 *    is for selection (marquee add), so it is not the pan key.
 *  - Double-click: fit-all.
 *
 * Pointer press, move, and release live in `use-scrubber-pointers.ts`.
 * The Pixi scene and paint ticker live in `use-scrubber-scene.ts`.
 */

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from "react";
import type { ClockSnapshot } from "../../engine/clock.ts";
import type { MoveIntent, MoveSpanIntent } from "../../engine/authoring/moves.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { applyRowOrder } from "../../engine/event-helpers.ts";
import { type SelectMode, type StageSelection } from "../../render/types.ts";
import { type EntityRefKey, type SurfaceGestureCtx } from "../../interactions/types.ts";
import { laneRowEntityIds } from "./lane-bundle.ts";
import { MIN_LANE_HEIGHT, rowStackHeight, RULER_HEIGHT, RULER_TOP_PAD } from "./row-layout.ts";
import { applyWheel, canvasPxToT, fitAll, gutterWidthOf, type LaneKind, type TimelineView } from "./state.ts";
import { type DragMode } from "./scrubber-drag.ts";
import { useScrubberPointers } from "./use-scrubber-pointers.ts";
import { useScrubberScene } from "./use-scrubber-scene.ts";
/** Default host `title` when the pointer is not on a gutter eyeball. */
const SCRUBBER_HOST_TITLE =
  "Wheel = zoom · Shift+wheel = pan · gutter wheel = scroll · drag ruler = scrub · Alt+drag = pan (time + rows) · double-click = fit";

/** Maximum visible window width in Live mode — the zoom-out
 *  floor expressed as "what fits in the timeline at min zoom."
 *  At min zoom exactly 1 week of time spans the visible area.
 *
 *  This is ONLY a width cap; it does NOT cap pan. `viewPanMaxT`
 *  stays `Infinity` in Live so the user can pan past the live
 *  edge indefinitely — Live time is unbounded on the right
 *  (just never goes below zero on the left, which `clampView`
 *  enforces via `windowStart >= 0`). The 1-week width is just
 *  a floor on the zoom factor so it never reaches zero.
 *
 *  The tick cascade in `ticks.ts` shifts units (s → min → hr →
 *  day → mo → yr) so the ruler stays readable at every
 *  width the user can reach. */
export const MAX_LIVE_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Intrinsic minimum scrubber height — the floor for callers sizing the panel.
 *
 * The rows come from `rowStackHeight`, which walks the same `iterateRows` the
 * painter and every hit-test walk, so this height covers exactly the rows that
 * get drawn. It used to reimplement the walk and skip a category holding
 * nothing, on the reasoning that a lane toggle means "show this kind when it
 * exists"; the painter never agreed, drew the row regardless, and the panel had
 * no room for it. Reserving the row is not a new phantom, then. The row was
 * always there and only the height pretended otherwise.
 *
 * Measured at `MIN_LANE_HEIGHT` because this is the floor. The paint pass asks
 * the same function at whatever lane height the panel actually has.
 *
 * Pass `expandedCategories: new Set()` for the collapsed-fit height — the
 * drag clamp's floor. Fit / auto-size pass the live expansion set instead.
 */
export function scrubberHeight(
  expanded: ReadonlySet<LaneKind>,
  details?: {
    expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>;
    orderedEntities: Record<Exclude<LaneKind, "ruler">, readonly string[]>;
  },
): number {
  const rows = details === undefined ? { peers: [], sessions: [], messages: [] } : details.orderedEntities;
  return RULER_HEIGHT + RULER_TOP_PAD +
    rowStackHeight(
      expanded,
      details?.expandedCategories ?? new Set(),
      rows,
      MIN_LANE_HEIGHT,
    );
}

/** Categories fully collapsed — the scrubber height a drag may shrink to. */
const COLLAPSED_CATEGORIES: ReadonlySet<Exclude<LaneKind, "ruler">> = new Set();

/** Scrubber height with every category collapsed (lanes still as toggled).
 *  That is the panel's drag floor: expand a category, and you can drag
 *  between this and the live intrinsic; you cannot drag below this. */
export function scrubberCollapsedHeight(
  expandedLanes: ReadonlySet<LaneKind>,
  orderedEntities: Record<Exclude<LaneKind, "ruler">, readonly string[]>,
): number {
  return scrubberHeight(expandedLanes, {
    expandedCategories: COLLAPSED_CATEGORIES,
    orderedEntities,
  });
}

// Gutter and rubber-band live in `./hit-test.ts`; a point in a lane
// is `./event-hit.ts`. Per-frame paint (`drawScrubberScene`) lives
// in `./scrubber-paint.ts`. Pointer-drag modes live in `./scrubber-drag.ts`;
// the pointer host is `./use-scrubber-pointers.ts`. The Pixi scene is
// `./use-scrubber-scene.ts`.

export type ScrubberProps = {
  view: TimelineView;
  clock: ClockSnapshot;
  /** The full doc — needed by the lane-bundle builder to resolve
   *  `entity.timing` through the effective-range resolvers
   *  (`peerEffective` / `sessionEffective` / `messageEffective`).
   *  Replaces the pre-Behavior-layer flow where spans were derived
   *  from observation `t` directly. */
  doc: TimelineDocument;
  events: readonly TimelineEvent[];
  /** Identity-side of the entity model — see
   *  `doc.entities` in `timeline.ts`. Drives the gutter
   *  rendering for eternal entities: peers / sessions present
   *  here without a matching creation event in `events` get a
   *  row with a span anchored to the cascade-resolved bounds
   *  (peer → world; session → max-of-endpoints), instead of
   *  being invisible in the timeline. */
  entities: TimelineDocument["entities"];
  /** Lane expansion set from `view.expandedLanes`. */
  expandedLanes: ReadonlySet<LaneKind>;
  /** Width hint for the marker div's CSS size; the actual paint
   * width comes from the region rect each frame. */
  width: number;
  /** Dims the playhead during scrubbing. */
  scrubbing: boolean;
  /** Where the ghost playhead's time lives, shared with the
   * Overview via `TimelinePanel`. A mutable box rather than a
   * value, for the reason `rubberBandRef` and `snapLineRef` below
   * are: both surfaces write it on every pointermove and the only
   * reader is each surface's own Pixi ticker, so as state it
   * re-rendered the whole timeline at pointer-event rate to move
   * one number into two mutable slots. */
  hoverTRef: React.RefObject<number | null>;
  /** Literal view OR updater function (wheel handlers use the
   * updater so multi-events-per-frame stack on fresh state). */
  onSetView: (
    next: TimelineView | ((current: TimelineView) => TimelineView),
  ) => void;
  onSeek: (t: number) => void;
  onScrubStart: () => void;
  onScrubEnd: () => void;
  /** Current entity selection; rendered as a halo on matching
   * spans / glyphs so the timeline highlights what's selected
   * elsewhere (Stage, Inspector). */
  selection: StageSelection;
  /** Click an event pill / glyph to select its entity.
   * `| undefined` is explicit so callers can wire it conditionally
   * under `exactOptionalPropertyTypes`. */
  onSelectEvent?: ((selection: StageSelection) => void) | undefined;
  /** Sub-selection state machine (v1.5 #16). When the user clicks
   *  a session-state-changed diamond, the Scrubber emits the
   *  glyph's event id so the host can park "focus" on the
   *  keyframe — distinct from entity selection, which sits on
   *  the parent session. Clicks on span bodies / edges / empty
   *  area emit `null`, clearing focus. Escape at the host clears
   *  focus before entity selection so the state machine has a
   *  predictable inner→outer unwind. */
  focusedEventId?: string | null;
  onFocusEvent?: ((eventId: string | null) => void) | undefined;
  /** Drag an event pill or edge handle to retime. The Scrubber
   *  classifies the gesture (body translate / left-edge resize /
   *  right-edge resize) at hit-test time and emits the matching
   *  `MoveIntent` variant — no overload booleans, no optional
   *  `arrivalT` that flips the meaning of the t argument. */
  onMoveEvent?: ((move: MoveIntent) => void) | undefined;
  /** Entity-addressed sibling of `onMoveEvent` for spans with no
   *  anchor observation event (freshly authored peers/sessions);
   *  dispatches the engine's `move-entity-span`. */
  onMoveEntitySpan?: ((move: MoveSpanIntent) => void) | undefined;
  /** Transaction bracket around a drag-retime burst so the many
   * pointermove dispatches collapse into one undo step. */
  beginEdit?: ((label: string) => void) | undefined;
  endEdit?: (() => void) | undefined;
  /** Flash-grade timeline — multi-event selection. Events whose
   * id is in this set get the same halo as the single-selection
   * halo. Empty set ⇒ today's single-selection halo only.
   * Reference identity drives the per-paint bail; callers MUST
   * always create a new Set when membership changes, never
   * mutate in place. Holds entity refs (peer / session / message
   * keyed by `entityKey()`), not event ids — the Scrubber paints
   * the multi-halo on every event whose owning entity is in the
   * set, so the two ends of a pair light up together. */
  selectionSet: ReadonlySet<EntityRefKey>;
  /** Replace the selection set. Called on a non-modifier rubber-
   *  band commit AND on an additive rubber-band (after merging
   *  with `drag.startSelection` at the call site) — the store's
   *  set-selection is the only verb we need: additive mode is
   *  expressed by computing the union here and dispatching one
   *  set. (`add-to-selection` / `remove-from-selection` are
   *  exposed at App level for future shift/alt modifier modes
   *  and aren't surfaced to the Scrubber yet.) */
  /** Selection gesture (pill click or marquee) — forwarded with its
   * modifier mode to the one interpreter (`selectionActionFor`), so
   * this surface spells no set arithmetic of its own. */
  onEditSelection: (
    entities: ReadonlySet<EntityRefKey>,
    mode: SelectMode,
  ) => void;
  /** Toggle a single entity (shift/cmd-click on an event pill).
   *  Pair-end clicks resolve to the same entity, so toggling on
   *  either end has the same effect — that's the point of moving
   *  selection from event-id to entity-ref space. */
  /** Reports the Scrubber's computed intrinsic height — the
   * minimum pixels needed to render the current expansion
   * state with compact rows. The parent panel adds its own
   * chrome (control row + overview) and forwards an aggregated
   * intrinsic to App so the bottom pane can Fit / auto-size. */
  onIntrinsicHeightChange?: ((px: number) => void) | undefined;
  /** Reports the collapsed-fit scrubber height (every category
   *  collapsed, lanes as currently toggled). The parent uses this
   *  — not the live intrinsic — as the drag floor. */
  onCollapsedHeightChange?: ((px: number) => void) | undefined;
  /** Flash-grade timeline — per-category row management. */
  expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>;
  /** Doc-side row ordering override (read-through to the
   * renderer). Undefined ⇒ default first-event-t order. */
  rowOrder: TimelineDocument["rowOrder"];
  /** Doc-side per-row visibility (read-through, 4-state model —
   * visible / label / body / both — see engine's `setRowVisMode`).
   * Undefined ⇒ all rows fully visible. */
  rowHidden: TimelineDocument["rowHidden"];
  rowLabelHidden: TimelineDocument["rowLabelHidden"];
  rowBodyHidden: TimelineDocument["rowBodyHidden"];
  /** Stored per-category visibility flag — drives the
   *  category-header eyeball glyph. Stored independently of
   *  per-entity / all flags; the cascade is composed at draw
   *  time in the Stage, not surveyed here. */
  categoryVisMode: TimelineDocument["categoryVisMode"];
  /** Click a category chevron → toggle expand. Optional so
   * callers can opt out of the gesture (Play / non-Build modes
   * can leave it undefined and the chevron is decorative). */
  toggleCategory?:
    | ((category: Exclude<LaneKind, "ruler">) => void)
    | undefined;
  /** Click a row eyeball → cycle this entity's visibility mode
   * (visible → label-hidden → body-hidden → both-hidden → visible).
   * The engine owns the state machine; the UI just signals "next". */
  cycleRowVisibility?:
    | ((category: Exclude<LaneKind, "ruler">, entityId: string) => void)
    | undefined;
  /** Click the category-row eyeball → show-all / hide-all for the
   * category (lossy by design — wipes per-entity overrides for
   * the category). Engine handles the show ↔ hide toggle. */
  cycleCategoryVisibility?:
    | ((category: Exclude<LaneKind, "ruler">) => void)
    | undefined;
  /** Commit a row-drag-reorder gesture. Called on pointerup with
   * the final ordered list of entity ids for the affected
   * category. Wrap in a transaction at the caller. */
  commitRowReorder?:
    | ((
      category: Exclude<LaneKind, "ruler">,
      order: string[],
    ) => void)
    | undefined;
  /** Suppress the scrub / seek gestures (click in ruler band,
   *  click in empty scrub zone, drag-from-ruler). Used in Live
   *  mode — the feed is forward-only, so seeking has no meaning.
   *  Other gestures (wheel zoom / pan, marquee select, entity
   *  click, gutter chevron / eyeball / row reorder, gutter-edge
   *  resize) stay enabled. */
  disabledScrub?: boolean | undefined;
  /** The App's gesture context — Space, the active tool, and the keys held
   * right now. The cursor is drawn from it, so a modifier press previews the
   * select-mode cursor immediately, without waiting for the next pointer
   * move, and an authoring tool keeps its cursor over this surface too. */
  gestureCtx: SurfaceGestureCtx;
  /** View-width ceiling (zoom-out floor). Defaults to
   *  `clock.duration`. Live passes `MAX_LIVE_WINDOW_MS` (1 week)
   *  so the user can zoom out past 1× and see week-of-context
   *  ruler ticks. Shared with Overview via
   *  `TimelinePanel` so both surfaces honor the same bounds. */
  viewMaxWidth?: number | undefined;
  /** Right-edge cap for pan. Defaults to `clock.duration`. Live
   *  passes `Infinity` so pan-right is unbounded — the timeline
   *  has no end. Shared with Overview. */
  viewPanMaxT?: number | undefined;
};

export function Scrubber(
  {
    view,
    clock,
    doc,
    events,
    entities,
    expandedLanes,
    width,
    scrubbing,
    hoverTRef,
    onSetView,
    onSeek,
    onScrubStart,
    onScrubEnd,
    selection,
    onSelectEvent,
    focusedEventId = null,
    onFocusEvent,
    onMoveEvent,
    onMoveEntitySpan,
    beginEdit,
    endEdit,
    expandedCategories,
    rowOrder,
    rowHidden,
    rowLabelHidden,
    rowBodyHidden,
    categoryVisMode,
    toggleCategory,
    cycleRowVisibility,
    cycleCategoryVisibility,
    commitRowReorder,
    disabledScrub = false,
    gestureCtx,
    viewMaxWidth: viewMaxWidthProp,
    viewPanMaxT: viewPanMaxTProp,
    selectionSet,
    onEditSelection,
    onIntrinsicHeightChange,
    onCollapsedHeightChange,
  }: ScrubberProps,
) {
  // View-bounds (all three read by `clampView`): `clock.duration`
  // is content extent — drives the anchor-at-left rule when the
  // window covers all content. `viewMaxWidth` is the zoom-out
  // floor (Live: 1-week cap; Play/Build: duration). `viewPanMaxT`
  // is the right-edge pan cap (Live: Infinity, no end; Play/Build:
  // duration). Shared with Overview via TimelinePanel props.
  const viewMaxWidth = viewMaxWidthProp ?? clock.duration;
  const viewPanMaxT = viewPanMaxTProp ?? clock.duration;

  // Per-category insertion-ordered entity-id lists, from the same
  // `laneRowEntityIds` SOT `buildLaneBundle` drives its iteration
  // from — so gutter hit-test row indices and painted row indices
  // are the same indices, not two mirrors. Feeds `scrubberHeight`
  // (expanded-category height floor) and the gutter hit-test row
  // mapping.
  const insertionEntities = useMemo(
    () => laneRowEntityIds(entities, events),
    [entities, events],
  );
  const orderedEntities = useMemo(() => ({
    peers: applyRowOrder(insertionEntities.peers, rowOrder?.peers),
    sessions: applyRowOrder(insertionEntities.sessions, rowOrder?.sessions),
    messages: applyRowOrder(insertionEntities.messages, rowOrder?.messages),
  }), [insertionEntities, rowOrder]);
  const intrinsicHeight = scrubberHeight(expandedLanes, {
    expandedCategories,
    orderedEntities,
  });
  const collapsedHeight = scrubberCollapsedHeight(
    expandedLanes,
    orderedEntities,
  );
  // Bubble heights upward via layout-effect (not effect) so the
  // Scrubber → TimelinePanel → App.autoSize / drag-floor chain
  // runs synchronously, collapsing what would otherwise be 2-3
  // paints into one at the final geometry.
  useLayoutEffect(() => {
    onIntrinsicHeightChange?.(intrinsicHeight);
  }, [intrinsicHeight, onIntrinsicHeightChange]);
  useLayoutEffect(() => {
    onCollapsedHeightChange?.(collapsedHeight);
  }, [collapsedHeight, onCollapsedHeightChange]);
  const laneHeight = MIN_LANE_HEIGHT;
  const hostRef = useRef<HTMLDivElement | null>(null);
  const dragRef = useRef<DragMode>(null);
  // Active rubber-band rect (HOST coordinates) — null when no
  // band-drag is in flight. Per-frame paint reads this through
  // propsRef and overlays a translucent accent rect.
  const rubberBandRef = useRef<
    | { x: number; y: number; width: number; height: number }
    | null
  >(null);
  // X-pixel of the snap-to-grid target during an event drag
  // with Shift held — null otherwise. Painted as a thin accent
  // vertical line so the user sees where the value will snap.
  const snapLineRef = useRef<number | null>(null);
  /** Which gutter row the pointer is hovering, encoded as a
   *  stable key so the paint bail can compare cheaply. Values:
   *    "edge"                   — the gutter-resize seam
   *    "header:<category>"      — category header row
   *    "entity:<category>:<id>" — per-entity row label area
   *    "row-drag:<...>"         — drag handle on an entity row
   *    null                     — not over the gutter
   *  Painted as a subtle bg fill on the corresponding row by
   *  `drawScrubberScene`. */
  const hoverGutterRowRef = useRef<string | null>(null);
  /** Vertical scroll offset (px) applied to the lane stack. Ruler
   *  stays pinned to the bottom. Wheel over the GUTTER updates
   *  this; wheel over the plot area continues to pan/zoom (the
   *  user explicitly wants zoom-scroll preserved everywhere except
   *  the gutter, mirroring AE's gutter-scroll convention). The
   *  paint loop also writes back the maximum scroll for the
   *  current content so the wheel handler can clamp without
   *  re-iterating the row stack itself. */
  const scrollYRef = useRef(0);
  const scrollYMaxRef = useRef(0);
  // Latest rounded host region size, written by the paint loop's
  // `handleRegionRect`. The commit-side marquee reads from here
  // (instead of calling `getBoundingClientRect` again) so the
  // selection bounds use the SAME rounded width/height the paint
  // pass clamped the marching ants band to — no 1px WYSIWYG drift
  // from fractional DPR.
  const regionSizeRef = useRef({ width: 0, height: 0 });
  // `propsRef` lets the long-lived ticker see the latest prop
  // values without re-creating itself per render.
  const propsRef = useRef({
    view,
    clock,
    doc,
    events,
    entities,
    expandedLanes,
    laneHeight,
    scrubbing,
    selection,
    expandedCategories,
    rowOrder,
    rowHidden,
    rowLabelHidden,
    rowBodyHidden,
    categoryVisMode,
    selectionSet,
    rubberBandRef,
    snapLineRef,
    focusedEventId,
  });
  propsRef.current = {
    view,
    clock,
    doc,
    events,
    entities,
    expandedLanes,
    laneHeight,
    scrubbing,
    selection,
    expandedCategories,
    rowOrder,
    rowHidden,
    rowLabelHidden,
    rowBodyHidden,
    categoryVisMode,
    selectionSet,
    rubberBandRef,
    snapLineRef,
    focusedEventId,
  };

  useScrubberScene({
    hostRef,
    propsRef,
    dragRef,
    hoverGutterRowRef,
    hoverTRef,
    scrollYRef,
    scrollYMaxRef,
    regionSizeRef,
  });

  const {
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
  } = useScrubberPointers({
    hostRef,
    dragRef,
    rubberBandRef,
    snapLineRef,
    hoverGutterRowRef,
    scrollYRef,
    scrollYMaxRef,
    regionSizeRef,
    propsRef,
    hoverTRef,
    hostTitle: SCRUBBER_HOST_TITLE,
    view,
    clockDuration: clock.duration,
    viewMaxWidth,
    viewPanMaxT,
    events,
    doc,
    expandedLanes,
    expandedCategories,
    orderedEntities,
    rowHidden,
    laneHeight,
    disabledScrub,
    gestureCtx,
    selectionSet,
    onSetView,
    onSeek,
    onScrubStart,
    onScrubEnd,
    onSelectEvent,
    onFocusEvent,
    onMoveEvent,
    onMoveEntitySpan,
    beginEdit,
    endEdit,
    onEditSelection,
    toggleCategory,
    cycleRowVisibility,
    cycleCategoryVisibility,
    commitRowReorder,
  });

  // Wheel handling lives ONLY in the native listener below. Adding
  // an `onWheel={…}` here would fire alongside the native one and
  // apply pan/zoom twice per event — visible "chop" when scrolling.

  const handleDoubleClick = useCallback(() => {
    // Fit uses `clock.duration` (not `viewPanMaxT`) on purpose: in
    // Live mode this means "fit the window to the range captured
    // so far," which is the useful interpretation. Fitting to
    // Infinity would zoom out to nothing.
    onSetView(fitAll(view, clock.duration));
  }, [view, clock.duration, onSetView]);

  // `viewRef` holds the latest committed view so the wheel handler
  // can read AND write-back optimistically within a single React
  // tick. Including `view` in the effect deps would tear down the
  // native listener on every wheel-driven update.
  const viewRef = useRef(view);
  viewRef.current = view;

  // Native (non-passive) wheel — React's synthetic wheel is passive
  // in some versions, which would no-op `preventDefault`.
  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const handler = (e: WheelEvent) => {
      e.preventDefault();
      const rect = host.getBoundingClientRect();
      const px = e.clientX - rect.left;
      const current = viewRef.current;
      // Wheel over the GUTTER scrolls the lane stack vertically;
      // wheel over the plot area zooms/pans the time window. This
      // preserves zoom-scroll across the entire plot region and
      // limits vertical scroll to the gutter, matching AE's
      // convention. `scrollYMaxRef` is set by the paint loop after
      // it knows the total content height for the current row set.
      if (px < gutterWidthOf(current)) {
        const next = Math.max(
          0,
          Math.min(scrollYMaxRef.current, scrollYRef.current + e.deltaY),
        );
        if (next === scrollYRef.current) return;
        scrollYRef.current = next;
        // Clear hover-t — vertical scroll is unrelated to the
        // time cursor and a stale ghost playhead would look
        // glued to the gutter as the rows slide underneath.
        hoverTRef.current = null;
        return;
      }
      // Wheel zoom always uses `clock.duration` as the captured
      // extent (drives the anchor-at-left rule); `viewMaxWidth`
      // caps zoom-out width; `viewPanMaxT` (Infinity in Live)
      // lets zoomed-in pan extend past the live edge into
      // "future" empty space.
      const next = applyWheel(
        e,
        current,
        clock.duration,
        px,
        rect.width,
        viewMaxWidth,
        viewPanMaxT,
      );
      viewRef.current = next;
      onSetView(next);
      hoverTRef.current = canvasPxToT(px, rect.width, next);
    };
    host.addEventListener("wheel", handler, { passive: false });
    return () => host.removeEventListener("wheel", handler);
  }, [clock.duration, viewMaxWidth, viewPanMaxT, onSetView, hoverTRef]);

  return (
    <div
      ref={hostRef}
      data-testid="timeline-scrubber"
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerUp}
      onPointerLeave={() => {
        hoverTRef.current = null;
        hoverGutterRowRef.current = null;
      }}
      onDoubleClick={handleDoubleClick}
      // Suppress browser context menu on the scrubber surface —
      // same rationale as `UnifiedCanvas`'s canvas element: an
      // accidental right-click DURING a row reorder / scrub /
      // marquee / gutter-resize drag would corrupt the pointer
      // event stream and "stick" the drag. Editor convention
      // applies to every drag surface.
      onContextMenu={(e) => e.preventDefault()}
      style={{
        // Marker div carries React events + layout; the unified
        // canvas behind it paints the pixels. The marker fills
        // its slot via `flex: 1` rather than a React-computed
        // `${height}px` — that prior coupling lagged one frame
        // behind the slot during resize and made the bottom-
        // anchored ruler stutter. The parent slot must be a
        // flex column for this to work; TimelinePanel sets that.
        display: "block",
        width: `${width}px`,
        flex: 1,
        minHeight: 0,
        // The resting value before the pointer has been anywhere. Every
        // answer after that comes from `timelineCursor`, this element's one
        // writer.
        cursor: "default",
        userSelect: "none",
        touchAction: "none",
        background: "transparent",
        position: "relative",
        zIndex: 1,
      }}
      title={SCRUBBER_HOST_TITLE}
    />
  );
}
