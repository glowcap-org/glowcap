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
 */

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from "react";
import { Container, Graphics, Rectangle } from "pixi.js";
import type { ClockSnapshot } from "../../engine/clock.ts";
import type { MoveIntent, MoveSpanIntent } from "../../engine/authoring/events.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { observationsOf } from "../../engine/temporal/recording-access.ts";
import { applyRowOrder, momentOf } from "../../engine/event-helpers.ts";
import { momentEffective } from "../../engine/temporal/doc-resolver.ts";
import { type SelectMode, selectModeFromModifiers, type StageSelection } from "../../render/types.ts";
import { entityKey, type EntityRefKey, type SurfaceGestureCtx } from "../../interactions/types.ts";
import { useGestureSurface } from "../../interactions/use-gesture-surface.ts";

const SCRUBBER_SURFACE_TAG = "timeline";
import { clampRectToBounds, rectFromCorners } from "../../render/geometry.ts";
import { eventEntityRef } from "./event-entity-ref.ts";
import { useUnifiedCanvas } from "../../render/UnifiedCanvas.tsx";
import { currentTheme, type Theme } from "../tokens.ts";
import { TextPool } from "./textPool.ts";
import { laneRowEntityIds } from "./lane-bundle.ts";
import {
  iterateRows,
  LANE_GAP,
  MIN_LANE_HEIGHT,
  type RowDescriptor,
  type RowDragSnapshot,
  rowStackHeight,
  RULER_HEIGHT,
  RULER_TOP_PAD,
  scrubberPlotBounds,
} from "./row-layout.ts";
import {
  applyWheel,
  canvasPxToT,
  fitAll,
  GUTTER_MAX_PX,
  GUTTER_MIN_PX,
  gutterWidthOf,
  type LaneKind,
  pan as panView,
  plotWidthOf,
  snapToMajorTick,
  type TimelineView,
  tToCanvasPx,
} from "./state.ts";
import { entitiesInRect, GUTTER_DRAG_GRAB_PX, hitTestEvents, hitTestGutter, type ScrubberHit } from "./hit-test.ts";
import { eyeballHoverStatus, scrubberHoverAt, timelineCursor, type TimelineGesture } from "./timeline-cursor.ts";
import { drawScrubberScene } from "./scrubber-paint.ts";

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

// Hit-test geometry (entity/gutter pickers, drag plans, rubber-band
// rect commit) lives in `./hit-test.ts`.
// Per-frame paint pipeline (`drawScrubberScene`) lives in
// `./scrubber-paint.ts`.

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
  /** The gesture in flight, named in the resolver's vocabulary at the press
   *  that starts it, so the cursor can say what is happening rather than what
   *  the pointer is passing over. Null for a select-only press, which moves
   *  nothing — the surface's own cursor stays right. The pointer FSM would
   *  hold this once this surface joins it (§ 13). */
  const inFlightRef = useRef<TimelineGesture | null>(null);
  // The App's gesture context, boxed so the pointer handlers and the
  // hover-refresh effect read the current value without re-creating
  // themselves on every render App happens to run.
  const gestureCtxRef = useRef(gestureCtx);
  gestureCtxRef.current = gestureCtx;

  // A modifier press or release re-previews the cursor at the last
  // hover position, so shift/option feedback doesn't wait for a
  // pointer twitch (the stage's cursor updates the same way).
  useEffect(() => {
    const host = hostRef.current;
    const at = lastHoverRef.current;
    if (!host || !at || dragRef.current) return;
    const p = propsRef.current;
    const rect = host.getBoundingClientRect();
    const rows = [...iterateRows(
      p.expandedLanes,
      p.expandedCategories,
      orderedEntities,
      p.rowHidden,
      p.laneHeight,
    )];
    const { cursor, hoverKey, statusTitle } = computeHoverState({
      px: at.px,
      py: at.py,
      rect,
      view: p.view,
      scrollY: scrollYRef.current,
      rows,
      events: p.events,
      doc: p.doc,
      disabledScrub,
      inFlight: null,
      gestureCtx: gestureCtxRef.current,
    });
    host.style.cursor = cursor;
    host.title = statusTitle ?? SCRUBBER_HOST_TITLE;
    hoverGutterRowRef.current = hoverKey;
    // Keyed on the context's VALUES, not its identity: App rebuilds the
    // object each render, and this effect hit-tests.
  }, [
    gestureCtx.spaceHeld,
    gestureCtx.activeTool,
    gestureCtx.modifiers.shift,
    gestureCtx.modifiers.alt,
    gestureCtx.modifiers.cmd,
  ]);

  // This surface's lease on the gesture lock. Cross-surface mutual
  // exclusion: while a Stage gesture is in flight, foreign
  // pointer-downs that land here are stopped before our handlers
  // see them, and vice versa. The hook ends a held gesture when the
  // scrubber leaves the tree — `TimelinePanel` drops it mid-drag
  // whenever recording starts or the slot measures zero wide — and
  // it watches the window for the gesture ends this element cannot
  // see. `endDrag` below is the surface's own teardown and every one
  // of those paths runs it, which is what closes the edit
  // transaction an event drag opened when the panel goes away under
  // the pointer. The arrow reads it late, after this render has
  // finished.
  const surface = useGestureSurface(SCRUBBER_SURFACE_TAG, () => endDrag());
  // Mirror the multi-selection prop into a ref so pointer
  // handlers (long-lived per render) read the LATEST set without
  // re-binding on every membership change.
  const selectionSetRef = useRef(selectionSet);
  selectionSetRef.current = selectionSet;
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
  /** Last hover position in host coords — lets a modifier press
   * recompute the cursor in place. */
  const lastHoverRef = useRef<{ px: number; py: number } | null>(null);
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
  const ctx = useUnifiedCanvas();

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

  useEffect(() => {
    const host = hostRef.current;
    if (!host || !ctx) return;
    const { app, regions } = ctx;

    const scrubberScene = new Container();
    app.stage.addChild(scrubberScene);

    // Lane content lives in a masked child so rows can render
    // partially as they scroll past the top/bottom of the lane
    // viewport (instead of binary-culling, which loses the visual
    // signal that there's more content). The mask rect is sized
    // to [0,0,width,lanesMaxY] each paint frame. Chrome (ruler,
    // playhead, scrollbar, dividers) sits on the outer scene and
    // is unaffected.
    const lanesScene = new Container();
    scrubberScene.addChild(lanesScene);

    // Three layers, in the order a reader needs them: the spans, the
    // names written on the spans, and the keyframe glyphs over both.
    // The glyphs are last because a diamond is the only mark that
    // carries its moment, while a span's name is also in the gutter
    // beside it. The label pool owns a container of its own rather
    // than sharing `lanesScene`, because it appends a `Text` per
    // label as it goes and anything added to that container up front
    // would still end up underneath them.
    const lanesGfx = new Graphics();
    lanesScene.addChild(lanesGfx);

    const lanesLabelLayer = new Container();
    lanesScene.addChild(lanesLabelLayer);
    const lanesLabels = new TextPool(lanesLabelLayer);

    const lanesGlyphGfx = new Graphics();
    lanesScene.addChild(lanesGlyphGfx);

    const laneClip = new Graphics();
    scrubberScene.addChild(laneClip);
    lanesScene.mask = laneClip;

    const graphics = new Graphics();
    scrubberScene.addChild(graphics);

    const labelPool = new TextPool(scrubberScene);

    let regionWidth = 0;
    let regionHeight = 0;

    const cleanups: Array<() => void> = [];

    const handleRegionRect = (
      rect: { x: number; y: number; width: number; height: number },
    ) => {
      // Round in a way that preserves the marker's BOTTOM-RIGHT
      // corner, not its size. `getBoundingClientRect` returns
      // floats that oscillate by fractions of a px across frames
      // during continuous resize; rounding y and height
      // INDEPENDENTLY would let `round(y) + round(height)` flip
      // between (e.g.) 701 and 702 even though `y + height` is
      // a constant 701 — that's a visible 1px stutter on the
      // bottom-anchored ruler painted at `regionHeight - 22`.
      // Computing the corner via `round(y + height) - round(y)`
      // pins the bottom edge so the ruler position is stable
      // as long as the underlying marker's actual bottom is.
      const x = Math.round(rect.x);
      const y = Math.round(rect.y);
      const right = Math.round(rect.x + rect.width);
      const bottom = Math.round(rect.y + rect.height);
      scrubberScene.position.set(x, y);
      regionWidth = right - x;
      regionHeight = bottom - y;
      regionSizeRef.current = { width: regionWidth, height: regionHeight };
    };
    cleanups.push(regions.register("timeline-scrubber", host));
    cleanups.push(regions.subscribe("timeline-scrubber", handleRegionRect));

    // Per-frame bail: skip the full scene rebuild when no paint
    // input changed. The big win is paused playback with no hover.
    // `events` is compared by reference AND length so live-mode
    // appends (which mutate the array in place) re-fire the paint
    // even if duration didn't grow.
    let lastTheme: Theme | null = null;
    let lastWindowStart = NaN;
    let lastWindowEnd = NaN;
    let lastExpanded: ReadonlySet<LaneKind> | null = null;
    let lastClockT = NaN;
    let lastDuration = NaN;
    let lastEvents: readonly TimelineEvent[] | null = null;
    let lastEventsLen = -1;
    let lastWidth = NaN;
    let lastHeight = NaN;
    let lastLaneHeight = NaN;
    let lastScrubbing = false;
    let lastHoverT: number | null = null;
    let lastSelection: StageSelection = null;
    let lastExpandedCategories:
      | ReadonlySet<Exclude<LaneKind, "ruler">>
      | null = null;
    let lastRowOrder: TimelineDocument["rowOrder"] = undefined;
    let lastRowHidden: TimelineDocument["rowHidden"] = undefined;
    let lastRowLabelHidden: TimelineDocument["rowLabelHidden"] = undefined;
    let lastRowBodyHidden: TimelineDocument["rowBodyHidden"] = undefined;
    let lastCategoryVisMode: TimelineDocument["categoryVisMode"] = undefined;
    let lastSelectionSet: ReadonlySet<EntityRefKey> | null = null;
    let lastEntities: TimelineDocument["entities"] | undefined = undefined;
    let lastDoc: TimelineDocument | null = null;
    let lastGutterWidth = NaN;
    let lastHoverGutterRow: string | null = null;
    let lastScrollY = NaN;
    // Hoisted hitArea — avoids `new Rectangle(...)` per paint and
    // the `instanceof` check inside the draw function.
    const hitArea = new Rectangle(0, 0, 0, 0);
    graphics.hitArea = hitArea;

    const repaint = () => {
      const p = propsRef.current;
      if (regionWidth <= 0 || regionHeight <= 0) return;
      const theme = currentTheme();
      // Rubber-band is in flight when the rect ref is non-null;
      // snap-line analogous. Both flip per-frame without ref
      // identity changes, so the bail must skip those frames.
      const bandActive = p.rubberBandRef.current !== null;
      const snapActive = p.snapLineRef.current !== null;
      // Row-reorder drag — snapshot the drag state so the paint
      // can draw a lifted source row + insertion indicator at the
      // resolved target slot. Bail-skipping per frame is the same
      // idiom as `bandActive` / `snapActive`; the snapshot
      // captures the live `finalIndex` for each frame.
      const drag = dragRef.current;
      const rowDrag: RowDragSnapshot | null = drag?.kind === "row-drag" && drag.moved
        ? {
          category: drag.category,
          entityId: drag.entityId,
          startIndex: drag.startIndex,
          finalIndex: drag.finalIndex,
        }
        : null;
      const rowDragActive = rowDrag !== null;
      // Event retimes mutate `doc` inside a transaction without
      // bumping `docVersion`, so React props stay stale until
      // release. Read the live document here — `bumpEntities` and
      // in-place event edits are what the pills must follow mid-drag.
      const liveEntities = p.doc.entities;
      const liveEvents = observationsOf(p.doc) as readonly TimelineEvent[];
      // An in-flight event drag (diamond / span edge / body) must
      // repaint even when the bail's prop snapshot has not moved.
      const eventDragActive = drag?.kind === "event" && drag.moved &&
        !drag.selectOnly;
      const curGutter = gutterWidthOf(p.view);
      const curHoverRow = hoverGutterRowRef.current;
      const curScrollY = scrollYRef.current;
      const curHoverT = hoverTRef.current;
      if (
        !bandActive && !snapActive && !rowDragActive && !eventDragActive &&
        curScrollY === lastScrollY &&
        theme === lastTheme &&
        p.view.windowStart === lastWindowStart &&
        p.view.windowEnd === lastWindowEnd &&
        p.expandedLanes === lastExpanded &&
        p.clock.t === lastClockT &&
        p.clock.duration === lastDuration &&
        liveEvents === lastEvents &&
        liveEvents.length === lastEventsLen &&
        regionWidth === lastWidth &&
        regionHeight === lastHeight &&
        p.laneHeight === lastLaneHeight &&
        p.scrubbing === lastScrubbing &&
        curHoverT === lastHoverT &&
        p.selection === lastSelection &&
        p.expandedCategories === lastExpandedCategories &&
        p.rowOrder === lastRowOrder &&
        p.rowHidden === lastRowHidden &&
        p.rowLabelHidden === lastRowLabelHidden &&
        p.rowBodyHidden === lastRowBodyHidden &&
        p.categoryVisMode === lastCategoryVisMode &&
        p.selectionSet === lastSelectionSet &&
        liveEntities === lastEntities &&
        p.doc === lastDoc &&
        curGutter === lastGutterWidth &&
        curHoverRow === lastHoverGutterRow
      ) {
        return;
      }
      lastEntities = liveEntities;
      lastDoc = p.doc;
      lastGutterWidth = curGutter;
      lastHoverGutterRow = curHoverRow;
      lastScrollY = curScrollY;
      lastTheme = theme;
      lastWindowStart = p.view.windowStart;
      lastWindowEnd = p.view.windowEnd;
      lastExpanded = p.expandedLanes;
      lastClockT = p.clock.t;
      lastDuration = p.clock.duration;
      lastEvents = liveEvents;
      lastEventsLen = liveEvents.length;
      lastWidth = regionWidth;
      lastHeight = regionHeight;
      lastLaneHeight = p.laneHeight;
      lastScrubbing = p.scrubbing;
      lastHoverT = curHoverT;
      lastSelection = p.selection;
      lastExpandedCategories = p.expandedCategories;
      lastRowOrder = p.rowOrder;
      lastRowHidden = p.rowHidden;
      lastRowLabelHidden = p.rowLabelHidden;
      lastRowBodyHidden = p.rowBodyHidden;
      lastCategoryVisMode = p.categoryVisMode;
      lastSelectionSet = p.selectionSet;
      hitArea.width = regionWidth;
      hitArea.height = regionHeight;
      const contentHeight = drawScrubberScene(
        graphics,
        lanesGfx,
        lanesGlyphGfx,
        laneClip,
        labelPool,
        lanesLabels,
        theme,
        p.view,
        p.clock,
        p.doc,
        liveEvents,
        p.expandedLanes,
        p.expandedCategories,
        p.rowOrder,
        p.rowHidden,
        p.rowLabelHidden,
        p.rowBodyHidden,
        p.categoryVisMode,
        regionWidth,
        regionHeight,
        p.laneHeight,
        p.scrubbing,
        curHoverT,
        p.selection,
        p.selectionSet,
        p.rubberBandRef.current,
        p.snapLineRef.current,
        curHoverRow,
        rowDrag,
        curScrollY,
        p.focusedEventId,
      );
      // Publish the new scroll ceiling for the wheel handler. If
      // the content shrank (a category collapsed, an entity left
      // in Live) and we now exceed the new max, clamp down so the
      // lane stack doesn't end up scrolled into empty space.
      const lanesViewport = regionHeight - RULER_HEIGHT - RULER_TOP_PAD;
      const newMax = Math.max(0, contentHeight - lanesViewport);
      scrollYMaxRef.current = newMax;
      if (curScrollY > newMax) {
        scrollYRef.current = newMax;
      }
    };

    // Paint each frame. Stage's tick (which calls `engine.tick`)
    // registers earlier in commit order, so engine state is fresh
    // when we run.
    app.ticker.add(repaint);
    cleanups.push(() => app.ticker?.remove(repaint));

    return () => {
      for (const fn of cleanups) fn();
      app.stage?.removeChild(scrubberScene);
      labelPool.destroy();
      lanesLabels.destroy();
      if (!scrubberScene.destroyed) scrubberScene.destroy({ children: true });
    };
  }, [ctx, hoverTRef]);

  // Wheel handling lives ONLY in the native listener below. Adding
  // an `onWheel={…}` here would fire alongside the native one and
  // apply pan/zoom twice per event — visible "chop" when scrolling.

  const handlePointerDown = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      if (e.button !== 0) return; // left mouse only
      // Cross-surface lock — bail if another surface (e.g. Stage)
      // owns the gesture. The root guard normally suppresses this
      // event before it reaches us, but defending here costs
      // nothing and keeps invariants honest under tests.
      if (!surface.claim(e.currentTarget, e.pointerId)) return;
      e.preventDefault();
      e.currentTarget.setPointerCapture(e.pointerId);
      const rect = e.currentTarget.getBoundingClientRect();
      const px = e.clientX - rect.left;
      const py = e.clientY - rect.top;

      const gutter = gutterWidthOf(view);

      // 0) Gutter-edge drag handle: a few pixels straddling the
      // gutter's right edge resize the gutter live. Pre-empts
      // everything below — the user explicitly grabbed the seam.
      if (Math.abs(px - gutter) <= GUTTER_DRAG_GRAB_PX) {
        dragRef.current = {
          kind: "gutter-resize",
          startClientX: e.clientX,
          startGutterWidth: gutter,
        };
        inFlightRef.current = {
          surface: "timeline-gutter-edge",
          verb: { kind: "resize-gutter" },
        };
        return;
      }

      // Walk the same row stack the renderer paints. Shared by the
      // gutter hit-test and the event hit-test below (both must agree
      // with the painter's row geometry). Add `scrollY` to `py` at
      // each call so hits land on the unscrolled row coords.
      const rows = [...iterateRows(
        expandedLanes,
        expandedCategories,
        orderedEntities,
        rowHidden,
        laneHeight,
      )];
      // 1) Gutter check first (px < gutterWidth). The chevron /
      // eyeball / row-drag gestures all live in the gutter; they
      // pre-empt event hit-tests and the scrub / pan branches below.
      if (px < gutter) {
        const gutterHit = hitTestGutter(
          px,
          py + scrollYRef.current,
          rows,
          gutter,
        );
        if (gutterHit?.kind === "chevron") {
          toggleCategory?.(gutterHit.category);
          return;
        }
        if (gutterHit?.kind === "category-eyeball") {
          cycleCategoryVisibility?.(gutterHit.category);
          return;
        }
        if (gutterHit?.kind === "eyeball") {
          cycleRowVisibility?.(gutterHit.category, gutterHit.entityId);
          return;
        }
        if (gutterHit?.kind === "row-drag") {
          // The order of THIS category — captured at drag-start
          // so a mid-drag prop change doesn't drift the math.
          const startOrder = [...orderedEntities[gutterHit.category]];
          const startIndex = startOrder.indexOf(gutterHit.entityId);
          if (startIndex === -1) return;
          dragRef.current = {
            kind: "row-drag",
            category: gutterHit.category,
            entityId: gutterHit.entityId,
            startIndex,
            startOrder,
            startClientY: e.clientY,
            rowPitchPx: gutterHit.rowHeight + LANE_GAP,
            moved: false,
            finalIndex: startIndex,
          };
          inFlightRef.current = {
            surface: "timeline-gutter-label",
            verb: {
              kind: "reorder-row",
              category: gutterHit.category,
              entityId: gutterHit.entityId,
            },
          };
          return;
        }
        // Gutter click but not on a control → no-op (don't
        // treat as scrub; that would seek to t=null).
        return;
      }

      const t = canvasPxToT(px, rect.width, view);
      if (t === null) return; // shouldn't happen post-gutter check, defensive
      hoverTRef.current = null;
      // Entity hit-test wins over EVERY non-gutter branch — pan, scrub,
      // rubber-band all only fire if the pointer didn't land on a pill.
      // Routing this first means shift/alt/cmd-click on a pill always
      // reach the selection-mode resolution below; they no longer get
      // hijacked into pan (which broke shift-to-add) or scrub.
      const hit = hitTestEvents(
        px,
        py,
        rect.width,
        rect.height,
        view,
        events,
        rows,
        doc,
        scrollYRef.current,
      );
      if (hit && (onSelectEvent || onMoveEvent)) {
        // Gate drag-to-move on prior selection for body translates.
        // Clicking an unselected entity is a select-only intent: the
        // gesture captures the hit so endDrag can dispatch the select
        // on release, but the move handler ignores displacement so an
        // unselected pill body cannot translate. The user must click a
        // second time once the entity is selected to drag — matches
        // the "select then act" convention used across the Inspector
        // and Stage halo. Add/remove/toggle gestures skip this gate: a
        // modifier-click is unambiguously a selection-set edit, not a
        // drag intent, so it doesn't need to wait for a prior
        // single-select.
        const hitEntityKey = entityKey(hit.entity);
        // One selection grammar across surfaces: the stage's
        // modifier map (shift = add, shift+option = remove).
        const selectMode: SelectMode = selectModeFromModifiers(e);
        // `drag === null` = no observation event to retime. The
        // gesture must remain select-only regardless of selection
        // state, otherwise the move handler would have no plan.
        // Precise hotspots bypass the "click first to select" gate
        // so a user can grab a 6px edge or diamond and start retiming
        // in one motion (and discover the affordance via the cursor
        // without first having to click). Modifier gestures stay
        // select-only: a modifier-click is a selection-set edit, not
        // authoring.
        const isDirectActPlan = hit.drag?.kind === "span-edge" ||
          hit.drag?.kind === "entity-span-edge" ||
          hit.drag?.kind === "message-edge" ||
          hit.drag?.kind === "moment";
        const selectOnly = hit.drag === null ||
          selectMode !== "replace" ||
          (!isDirectActPlan && !selectionSetRef.current.has(hitEntityKey));
        dragRef.current = {
          kind: "event",
          hit,
          startClientX: e.clientX,
          moved: false,
          txOpen: false,
          selectMode,
          selectOnly,
        };
        // A select-only press moves nothing, so it names no gesture: the
        // pill's own cursor stays the honest answer until the release.
        inFlightRef.current = selectOnly ? null : {
          surface: isDirectActPlan && hit.drag?.kind !== "moment"
            ? "timeline-lane-event-right-edge"
            : "timeline-lane-event",
          verb: isDirectActPlan && hit.drag?.kind !== "moment"
            ? {
              kind: "drag-event-right-edge",
              eventId: eventIdOfPlan(hit),
              entityRef: hit.entity,
            }
            : {
              kind: "select-or-drag-event",
              eventId: eventIdOfPlan(hit),
              entityRef: hit.entity,
            },
        };
        return;
      }
      // No entity under the pointer. Alt alone = pan the whole
      // strip (time + lane scroll); a shifted gesture falls through
      // to the rubber-band branch, where the stage's modifier map
      // decides the commit (shift = add, shift+option = remove).
      // Pan losing the bare-shift modifier is the price of giving
      // shift back to "add to selection" — alt alone is the
      // timeline's pan key.
      if (e.altKey && !e.shiftKey) {
        dragRef.current = {
          kind: "pan",
          lastClientX: e.clientX,
          lastClientY: e.clientY,
        };
        inFlightRef.current = {
          surface: "timeline-lane-empty",
          verb: { kind: "pan-view" },
        };
        return;
      }
      // Empty area branch. Scrub zone = ruler band PLUS the empty
      // space between the bottom of the last entity row and the
      // top of the ruler — same idea the user described as
      // "expand the ruler container as high as it can go". Lane
      // area (where rows actually paint) keeps the rubber-band
      // gesture. With this split, the dead vertical gap left by
      // the panel auto-grow becomes a useful playhead-scrub
      // strip instead of a marquee start that always selects
      // nothing.
      // `lanesBottomY` is the painted (scrolled) bottom of the
      // last row — `py` is in painted coords too, so subtract
      // `scrollY` once here instead of adding to py everywhere.
      const lanesBottomY = (rows.length > 0
        ? rows[rows.length - 1]!.y +
          rows[rows.length - 1]!.height
        : 0) - scrollYRef.current;
      const rulerTopY = rect.height - RULER_HEIGHT;
      const inScrubZone = py >= rulerTopY || py >= lanesBottomY;
      if (inScrubZone) {
        // Live mode (`disabledScrub`) bails the scrub gesture
        // entirely — clicking the ruler or the empty zone below
        // the rows does nothing instead of trying to seek a
        // forward-only feed. Wheel zoom / pan still work
        // (separate native listener), and the rubber-band
        // gesture below this branch isn't reached because the
        // inScrubZone short-circuit ran.
        if (disabledScrub) return;
        dragRef.current = { kind: "scrub", lastClientX: e.clientX };
        inFlightRef.current = {
          surface: "timeline-ruler",
          verb: { kind: "scrub" },
        };
        onScrubStart();
        onSeek(t);
        return;
      }
      // Rubber-band. Sub-threshold release is treated as
      // "clear selection" (matching today's empty-area click
      // behavior at the App level).
      const mode = selectModeFromModifiers(e);
      dragRef.current = {
        kind: "rubber-band",
        startClientX: e.clientX,
        startClientY: e.clientY,
        currentClientX: e.clientX,
        currentClientY: e.clientY,
        mode,
        moved: false,
      };
      // The empty lane's own default verb (§ 4.5) — the same marquee the
      // empty stage sweeps, carrying the mode this drag latched, so the
      // cursor names the gesture this handler is actually running.
      inFlightRef.current = {
        surface: "timeline-lane-empty",
        verb: { kind: "rubber-band", mode },
      };
    },
    [
      view,
      events,
      expandedLanes,
      laneHeight,
      onSelectEvent,
      onMoveEvent,
      onSeek,
      onScrubStart,
      onSetView,
      hoverTRef,
      expandedCategories,
      orderedEntities,
      rowHidden,
      toggleCategory,
      cycleRowVisibility,
      cycleCategoryVisibility,
      disabledScrub,
    ],
  );

  // Idempotent drag teardown — called from the normal pointerup,
  // the phantom-drag recovery in `handlePointerMove`, and the
  // window watch inside `useGestureSurface` for the ends this
  // element cannot see.
  const endDrag = useCallback(() => {
    // Always release the gesture-router lock first — pointerdown
    // may have claimed without ever setting `dragRef` (e.g.
    // pointer landed on a non-actionable region). Releasing
    // before the early-return keeps the lock honest.
    surface.release();
    inFlightRef.current = null;
    const drag = dragRef.current;
    if (!drag) return;
    if (drag.kind === "scrub") onScrubEnd();
    if (drag.kind === "event") {
      // No movement = treat as click. Modifier-resolved selectMode
      // steers the click into one of four selection-set edits.
      // Plain "replace" also sets the single selection (Inspector
      // follow); the other three only edit the multi-set so the
      // user can grow / shrink it without losing single-select
      // focus elsewhere.
      if (drag.txOpen) endEdit?.();
      else {
        const key = entityKey(drag.hit.entity);
        // The mode's set arithmetic lives in `selectionActionFor`;
        // this surface only forwards the hit. The replace arm keeps
        // its surface extras: Inspector follow, and sub-selection
        // focus (#16) — a glyph (moment) hit parks focus on the
        // keyframe, body / edge hits reset it.
        onEditSelection(new Set([key]), drag.selectMode);
        if (drag.selectMode === "replace") {
          onSelectEvent?.(drag.hit.entity);
          if (onFocusEvent) {
            const plan = drag.hit.drag;
            onFocusEvent(plan?.kind === "moment" ? plan.eventId : null);
          }
        }
      }
      snapLineRef.current = null;
    }
    if (drag.kind === "row-drag") {
      if (drag.moved) {
        // Commit the reorder. Empty-or-noop is filtered at the
        // engine layer via `isNoOpIntent`.
        const next = [...drag.startOrder];
        const from = drag.startIndex;
        const to = Math.max(0, Math.min(next.length - 1, drag.finalIndex));
        if (from !== to) {
          const [moved] = next.splice(from, 1);
          if (moved !== undefined) next.splice(to, 0, moved);
          commitRowReorder?.(drag.category, next);
        }
      } else {
        // Tap-to-select on the entity row label — the previously
        // dead spot in the gutter. Picks the parent entity so the
        // click has a visible effect (Inspector follows + stage
        // halo lights up) and matches what clicking the entity
        // anywhere else does.
        const kind = drag.category === "peers" ? "peer" : drag.category === "sessions" ? "session" : "message";
        onSelectEvent?.({ kind, id: drag.entityId });
      }
    }
    if (drag.kind === "rubber-band") {
      rubberBandRef.current = null;
      if (!drag.moved) {
        // Click-no-drag on empty plot: the interpreter owns the
        // semantics (plain click clears with timeline empty-space
        // rules; a modifier click preserves the selection).
        onEditSelection(new Set(), drag.mode);
        if (drag.mode === "replace") {
          onSelectEvent?.(null);
          onFocusEvent?.(null);
        }
      } else {
        // Commit: every event whose pill intersects the rect
        // contributes its OWNING ENTITY's ref to the selection.
        // Pair-ends naturally fold into one ref (peer-joined and
        // peer-left both map to the same {kind:"peer", id}), so
        // a band that sweeps a span lights up the entity once,
        // not twice.
        const host = hostRef.current;
        if (host) {
          const hostRect = host.getBoundingClientRect();
          // Clamp to the SAME plot bounds the paint loop uses
          // (`scrubberPlotBounds`) so the committed selection rect
          // is pixel-identical to the marching-ants band the user
          // saw — gutter, left pad, right pad, and ruler are all
          // dead zone for the marquee. Then shift y by `scrollY` so
          // the rect lands in unscrolled row coords (rows from
          // `iterateRows` are unscrolled).
          const view = propsRef.current.view;
          // Bounds use the SAME rounded region size the paint loop
          // clamped the visible marching-ants band to (written into
          // `regionSizeRef` by `handleRegionRect`). Reading from
          // `hostRect.width/height` directly would drift by ≤1 px on
          // fractional DPR, silently letting the committed rect
          // include or exclude pills the user couldn't see lit up.
          const region = regionSizeRef.current;
          const bounds = scrubberPlotBounds(view, region.width, region.height);
          const raw = rectFromCorners(
            drag.startClientX - hostRect.left,
            drag.startClientY - hostRect.top,
            drag.currentClientX - hostRect.left,
            drag.currentClientY - hostRect.top,
          );
          const clamped = clampRectToBounds(raw, bounds);
          const sy = scrollYRef.current;
          const rect = {
            x: clamped.x,
            y: clamped.y + sy,
            width: clamped.width,
            height: clamped.height,
          };
          const rows = [...iterateRows(
            propsRef.current.expandedLanes,
            propsRef.current.expandedCategories,
            orderedEntities,
            propsRef.current.rowHidden,
            propsRef.current.laneHeight,
          )];
          const entityHits = entitiesInRect(
            rect,
            propsRef.current.doc,
            propsRef.current.events,
            propsRef.current.view,
            region.width,
            rows,
          );
          onEditSelection(entityHits, drag.mode);
        }
      }
    }
    dragRef.current = null;
  }, [
    onScrubEnd,
    onSelectEvent,
    onFocusEvent,
    endEdit,
    commitRowReorder,
    onEditSelection,
    orderedEntities,
  ]);

  const handlePointerMove = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      const rect = e.currentTarget.getBoundingClientRect();
      const drag = dragRef.current;
      // Ghost playhead is hover-only — once a drag starts, the
      // real playhead (scrub) or cursor (pan) carries the signal.
      // Mirrors the Overview's behavior.
      if (!drag) {
        const px = e.clientX - rect.left;
        hoverTRef.current = canvasPxToT(px, rect.width, view);
        const rows = [...iterateRows(
          expandedLanes,
          expandedCategories,
          orderedEntities,
          rowHidden,
          laneHeight,
        )];
        lastHoverRef.current = { px, py: e.clientY - rect.top };
        const { cursor, hoverKey, statusTitle } = computeHoverState({
          px,
          py: e.clientY - rect.top,
          rect,
          view,
          scrollY: scrollYRef.current,
          rows,
          events: propsRef.current.events,
          doc: propsRef.current.doc,
          disabledScrub,
          inFlight: null,
          gestureCtx: gestureCtxRef.current,
        });
        e.currentTarget.style.cursor = cursor;
        e.currentTarget.title = statusTitle ?? SCRUBBER_HOST_TITLE;
        hoverGutterRowRef.current = hoverKey;
        return;
      }
      // A gesture in flight is what is HAPPENING, and it outranks whatever
      // the pointer is passing over (§ 10, rung 1) — a scrub that wanders
      // into the gutter still reads as a scrub. Written every move so the
      // answer cannot go stale under the drag.
      if (inFlightRef.current !== null) {
        e.currentTarget.style.cursor = timelineCursor({
          hit: null,
          inFlight: inFlightRef.current,
          gestureCtx: gestureCtxRef.current,
        });
      }
      // A move with no button held is a pointer-up that went
      // missing, and `watchGestureEnd` has already ended the drag
      // by the time this bubbles here — so the live `drag` read
      // above is the whole guard.
      const plotWidth = plotWidthOf(rect.width, view);
      switch (drag.kind) {
        case "gutter-resize": {
          const dx = e.clientX - drag.startClientX;
          const next = drag.startGutterWidth + dx;
          const clamped = Math.max(
            GUTTER_MIN_PX,
            Math.min(GUTTER_MAX_PX, next),
          );
          onSetView((cur) => ({ ...cur, gutterWidth: clamped }));
          return;
        }
        case "pan": {
          const dx = e.clientX - drag.lastClientX;
          const dy = e.clientY - drag.lastClientY;
          drag.lastClientX = e.clientX;
          drag.lastClientY = e.clientY;
          // Vertical: grab-the-paper — content follows the pointer,
          // so dragging down reveals rows that were above.
          if (dy !== 0) {
            const next = Math.max(
              0,
              Math.min(
                scrollYMaxRef.current,
                scrollYRef.current - dy,
              ),
            );
            if (next !== scrollYRef.current) {
              scrollYRef.current = next;
              hoverTRef.current = null;
            }
          }
          // Horizontal: updater form so `dt` derives from the CURRENT
          // window width — without this, multiple moves per frame all
          // pan against the original window and the drag feels weak.
          if (dx !== 0) {
            onSetView((current) => {
              const dt = plotWidth > 0
                ? -(dx / plotWidth) *
                  (current.windowEnd - current.windowStart)
                : 0;
              return panView(
                current,
                dt,
                clock.duration,
                viewMaxWidth,
                viewPanMaxT,
              );
            });
          }
          return;
        }
        case "scrub": {
          drag.lastClientX = e.clientX;
          const t = canvasPxToT(e.clientX - rect.left, rect.width, view);
          if (t === null) return;
          onSeek(Math.max(0, Math.min(clock.duration, t)));
          return;
        }
        case "rubber-band": {
          updateRubberBand(
            e,
            drag,
            regionSizeRef.current,
            propsRef.current.view,
            rubberBandRef,
          );
          return;
        }
        case "row-drag": {
          updateRowDrag(e, drag);
          return;
        }
        case "event": {
          if (!onMoveEvent) return;
          applyEventDragMove({
            onMoveEntitySpan,
            e,
            rect,
            drag,
            plotWidth,
            view,
            events,
            doc: propsRef.current.doc,
            selectionSet: selectionSetRef.current,
            snapLineRef,
            beginEdit,
            onMoveEvent,
          });
          return;
        }
      }
    },
    [
      view,
      clock.duration,
      viewMaxWidth,
      viewPanMaxT,
      onSeek,
      onSetView,
      hoverTRef,
      onMoveEvent,
      onMoveEntitySpan,
      beginEdit,
      endDrag,
      expandedLanes,
      expandedCategories,
      orderedEntities,
      rowHidden,
      laneHeight,
      disabledScrub,
      events,
    ],
  );

  const handlePointerUp = useCallback(
    (e: React.PointerEvent<HTMLDivElement>) => {
      try {
        e.currentTarget.releasePointerCapture(e.pointerId);
      } catch {
        // capture may already be released
      }
      endDrag();
    },
    [endDrag],
  );

  // `setPointerCapture` doesn't deliver pointerup if the user
  // releases off-document (OS chrome, URL bar). That release, a
  // capture loss, and a window blur all reach `endDrag` through
  // the window watch in `useGestureSurface`, which every gesture
  // surface shares.

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

type DragMode =
  | { kind: "scrub"; lastClientX: number }
  | { kind: "pan"; lastClientX: number; lastClientY: number }
  | {
    kind: "event";
    /** What was hit; carried so we can dispatch select on a
     * no-move release or paint the halo during drag. */
    hit: ScrubberHit;
    /** Client-X at the start of the drag. New `t` is computed by
     * mapping the displacement through the current `pxPerMs`. */
    startClientX: number;
    /** Becomes true once displacement exceeds the drag threshold;
     * gates the transaction begin so pure clicks (no movement)
     * don't open a no-op undo step. */
    moved: boolean;
    /** True while an engine transaction is open. Flipped on the
     * first move above threshold; ended in `endDrag`. */
    txOpen: boolean;
    /** Modifier-resolved selection intent for a no-move release —
     *  the stage's vocabulary (`selectModeFromModifiers`): plain
     *  click replaces, shift adds, shift+option removes. Drag
     *  movement always operates on the dragged entity's cohort
     *  regardless of this value; the mode only steers the click. */
    selectMode: SelectMode;
    /** True when the dragged entity was NOT in the selection at
     * pointerdown. Such a gesture is a select-only intent — drag
     * movement is ignored so unselected entities cannot translate
     * or resize. Release still selects the entity; the user must
     * click a second time on the now-selected entity to drag. */
    selectOnly: boolean;
    /** Snapshot of (eventId, originalT, originalArrivalT?) for
     * every event in the multi-selection at drag-start. Set
     * iff the dragged event is itself in the multi-selection
     * — that's the "drag any selected pill → all move together"
     * trigger. Captured at start so a mid-drag prop change can't
     * drift the math. */
    bulkOriginals?: Array<{
      eventId: string;
      t: number;
      arrivalT?: number;
    }>;
  }
  | {
    /** Click-and-drag rectangle on empty plot area to multi-
     * select every event whose pill intersects the rect. */
    kind: "rubber-band";
    startClientX: number;
    startClientY: number;
    currentClientX: number;
    currentClientY: number;
    /** Modifier mode latched at drag start — the stage marquee's
     * vocabulary: replace, add (shift), remove (shift+option). */
    mode: SelectMode;
    moved: boolean;
  }
  | {
    /** Horizontal drag of the gutter's right edge, resizing
     *  `view.gutterWidth`. The edge has a small ±px grab band
     *  (`GUTTER_DRAG_GRAB_PX`) on top of any other interaction
     *  so the seam stays reliably catchable. */
    kind: "gutter-resize";
    startClientX: number;
    startGutterWidth: number;
  }
  | {
    /** Vertical drag-reorder of a per-entity row header. */
    kind: "row-drag";
    category: Exclude<LaneKind, "ruler">;
    entityId: string;
    /** Index of the row being dragged in its category's CURRENT
     * ordered-entities list. Captured at drag-start so the
     * insertion-index math has a stable origin. */
    startIndex: number;
    /** Snapshot of the current ordered-entities list for this
     * category. The drag commits a new permutation of this
     * list — captured here so a mid-drag prop change (rare but
     * possible) doesn't drift the math. */
    startOrder: string[];
    startClientY: number;
    /** Per-row height in pixels, captured at drag-start. Used to
     * convert clientY delta into insertion-index delta. */
    rowPitchPx: number;
    moved: boolean;
    /** Resolved on pointerup. */
    finalIndex: number;
  }
  | null;

/** The observation event a hit's drag plan retimes, or null when the plan is
 *  entity-addressed — an authored peer or session, whose painted span no
 *  observation names. */
function eventIdOfPlan(hit: ScrubberHit): string | null {
  const plan = hit.drag;
  if (plan === null) return null;
  if (plan.kind === "entity-span-edge" || plan.kind === "entity-span-body") {
    return null;
  }
  return plan.eventId;
}

/** Px threshold to distinguish click-to-select from drag-to-retime.
 * Matches the Stage's peer-drag threshold for muscle-memory
 * consistency. */
const EVENT_DRAG_THRESHOLD_PX = 4;

/** What the pointer is over and what it should look like there. The zones
 *  and the row key are `scrubberHoverAt`'s answer; the cursor is
 *  `cursorFor`'s, reached through `timelineCursor`. This host writes both and
 *  decides neither. */
function computeHoverState(
  args: {
    px: number;
    py: number;
    rect: DOMRect;
    view: TimelineView;
    scrollY: number;
    rows: readonly RowDescriptor[];
    events: readonly TimelineEvent[];
    doc: TimelineDocument;
    disabledScrub: boolean;
    /** The gesture this host is running, or null while it only hovers. */
    inFlight: TimelineGesture | null;
    /** The App's gesture context — a held Shift previews the selection edit
     *  the click or marquee would commit, exactly as it does on the Stage. */
    gestureCtx: SurfaceGestureCtx;
  },
): { cursor: string; hoverKey: string | null; statusTitle: string | null } {
  const { hit, hoverKey } = scrubberHoverAt({
    point: { px: args.px, py: args.py },
    size: { width: args.rect.width, height: args.rect.height },
    view: args.view,
    scrollY: args.scrollY,
    rows: args.rows,
    events: args.events,
    doc: args.doc,
    disabledScrub: args.disabledScrub,
  });
  return {
    cursor: timelineCursor({
      hit,
      inFlight: args.inFlight,
      gestureCtx: args.gestureCtx,
    }),
    hoverKey,
    statusTitle: eyeballHoverStatus(hit, args.doc),
  };
}

/** Rubber-band drag: track the live corner, clamp the rect to the
 *  plot content bounds, stash for the paint loop. The unified pixi
 *  canvas spans the viewport unmasked, so an unclamped rect happily
 *  paints into sibling panels when the pointer wanders out — clamping
 *  here AND at commit makes WYSIWYG. */
function updateRubberBand(
  e: React.PointerEvent<HTMLDivElement>,
  drag: Extract<DragMode, { kind: "rubber-band" }>,
  region: { width: number; height: number },
  view: TimelineView,
  rubberBandRef: React.MutableRefObject<
    { x: number; y: number; width: number; height: number } | null
  >,
): void {
  drag.currentClientX = e.clientX;
  drag.currentClientY = e.clientY;
  if (!drag.moved) {
    const dx = Math.abs(drag.currentClientX - drag.startClientX);
    const dy = Math.abs(drag.currentClientY - drag.startClientY);
    if (Math.hypot(dx, dy) >= EVENT_DRAG_THRESHOLD_PX) drag.moved = true;
  }
  const hostRect = e.currentTarget.getBoundingClientRect();
  const bounds = scrubberPlotBounds(view, region.width, region.height);
  const raw = rectFromCorners(
    drag.startClientX - hostRect.left,
    drag.startClientY - hostRect.top,
    drag.currentClientX - hostRect.left,
    drag.currentClientY - hostRect.top,
  );
  rubberBandRef.current = drag.moved ? clampRectToBounds(raw, bounds) : null;
}

/** Row-reorder drag: convert clientY delta into an insertion-index
 *  delta against the captured row pitch. Commit happens on pointerup
 *  in `endDrag`; this just tracks `drag.finalIndex`. */
function updateRowDrag(
  e: React.PointerEvent<HTMLDivElement>,
  drag: Extract<DragMode, { kind: "row-drag" }>,
): void {
  const dy = e.clientY - drag.startClientY;
  if (!drag.moved && Math.abs(dy) < EVENT_DRAG_THRESHOLD_PX) return;
  drag.moved = true;
  const indexDelta = Math.round(dy / drag.rowPitchPx);
  drag.finalIndex = Math.max(
    0,
    Math.min(drag.startOrder.length - 1, drag.startIndex + indexDelta),
  );
}

/** Event drag move — engages bulk-cohort + opens the undo txn on the
 *  first above-threshold frame, then dispatches to the engine per the
 *  drag plan's kind. Mutates `drag` (moved/txOpen/bulkOriginals) and
 *  `snapLineRef` (snap guide x in canvas px). */
function applyEventDragMove(
  args: {
    e: React.PointerEvent<HTMLDivElement>;
    rect: DOMRect;
    drag: Extract<DragMode, { kind: "event" }>;
    plotWidth: number;
    view: TimelineView;
    events: readonly TimelineEvent[];
    doc: TimelineDocument;
    selectionSet: ReadonlySet<EntityRefKey>;
    snapLineRef: React.MutableRefObject<number | null>;
    beginEdit: ((label: string) => void) | undefined;
    onMoveEvent: (move: MoveIntent) => void;
    onMoveEntitySpan: ((move: MoveSpanIntent) => void) | undefined;
  },
): void {
  const {
    e,
    rect,
    drag,
    plotWidth,
    view,
    events,
    doc,
    selectionSet,
    snapLineRef,
    beginEdit,
    onMoveEvent,
    onMoveEntitySpan,
  } = args;
  const totalDx = e.clientX - drag.startClientX;
  if (!drag.moved && Math.abs(totalDx) < EVENT_DRAG_THRESHOLD_PX) return;
  // Select-only gesture (entity wasn't selected at pointerdown):
  // swallow movement so an unselected entity can't be dragged or
  // resized. Release still routes through endDrag's no-move branch
  // and dispatches the select.
  if (drag.selectOnly) return;
  // selectOnly already implies a non-null drag plan (pointerdown
  // forces selectOnly when `hit.drag === null`). The narrowing here
  // is for the compiler — every downstream branch needs the plan
  // to read its eventId and times.
  if (drag.hit.drag === null) return;
  const plan = drag.hit.drag;
  const dt = plotWidth > 0 ? totalDx * (view.windowEnd - view.windowStart) / plotWidth : 0;
  // Entity-addressed spans (freshly authored entities with no
  // observation events): same gestures, dispatched through
  // `move-entity-span`. Handled before the event-addressed switch
  // because there is no eventId to read.
  if (plan.kind === "entity-span-edge" || plan.kind === "entity-span-body") {
    if (!drag.moved) {
      drag.moved = true;
      beginEdit?.(
        plan.kind === "entity-span-edge" ? "Resize span" : "Move span",
      );
      drag.txOpen = true;
    }
    const rawEntityT = Math.max(0, plan.originalT + dt);
    const newEntityT = e.shiftKey ? snapToMajorTick(rawEntityT, view, plotWidth) : rawEntityT;
    onMoveEntitySpan?.({
      kind: plan.kind === "entity-span-body" ? "translate" : plan.edge === "left" ? "resize-start" : "resize-end",
      ref: plan.ref,
      newT: newEntityT,
    });
    snapLineRef.current = e.shiftKey ? tToCanvasPx(newEntityT, rect.width, view) : null;
    return;
  }
  const dragEventId = plan.eventId;
  if (!drag.moved) {
    engageEventDrag(drag, plan, dragEventId, events, selectionSet, beginEdit);
  }
  // Anchor t for snap/bulk math: span/moment plans use originalT;
  // message plans use `start` (sent time) as the anchor, since that's
  // the dragged endpoint for body and left-edge gestures.
  const anchorT = plan.kind === "message-edge" || plan.kind === "message-body" ? plan.start : plan.originalT;
  if (drag.bulkOriginals) {
    // BULK: translate every selected event by the same dt. Snap (when
    // held) snaps the DRAGGED event first, then applies the same
    // effective dt to the rest, so the user's primary value lands on
    // the grid and the cohort stays in step.
    const rawAnchor = Math.max(0, anchorT + dt);
    const snappedAnchor = e.shiftKey ? snapToMajorTick(rawAnchor, view, plotWidth) : rawAnchor;
    const effectiveDt = snappedAnchor - anchorT;
    for (const orig of drag.bulkOriginals) {
      const newT = Math.max(0, orig.t + effectiveDt);
      onMoveEvent({ kind: "translate", eventId: orig.eventId, newT });
    }
    snapLineRef.current = e.shiftKey ? tToCanvasPx(snappedAnchor, rect.width, view) : null;
    return;
  }
  // Single-event path. One switch over the drag plan kind routes
  // each gesture to the engine call it needs.
  const rawT = Math.max(0, anchorT + dt);
  const newT = e.shiftKey ? snapToMajorTick(rawT, view, plotWidth) : rawT;
  switch (plan.kind) {
    case "message-edge": {
      if (plan.edge === "right") {
        const sentT = plan.start;
        const rawArrival = Math.max(sentT, plan.end + dt);
        const newArrival = e.shiftKey ? Math.max(sentT, snapToMajorTick(rawArrival, view, plotWidth)) : rawArrival;
        onMoveEvent({
          kind: "resize-end",
          eventId: dragEventId,
          newArrivalT: newArrival,
        });
        snapLineRef.current = e.shiftKey ? tToCanvasPx(newArrival, rect.width, view) : null;
      } else {
        // Left edge: sent moves, arrival stays pinned. Clamp sent ≤ arrival.
        const clampedT = Math.min(newT, plan.end);
        onMoveEvent({
          kind: "resize-start",
          eventId: dragEventId,
          newT: clampedT,
        });
        snapLineRef.current = e.shiftKey ? tToCanvasPx(newT, rect.width, view) : null;
      }
      return;
    }
    case "message-body":
    case "span-body": {
      onMoveEvent({ kind: "translate", eventId: dragEventId, newT });
      snapLineRef.current = e.shiftKey ? tToCanvasPx(newT, rect.width, view) : null;
      return;
    }
    case "span-edge": {
      // Left-edge: resize-start retimes just the start, paired close
      // stays put. Right-edge: dragEventId IS the end event; a plain
      // translate retimes it without sliding its sibling.
      onMoveEvent(
        plan.edge === "left"
          ? { kind: "resize-start", eventId: dragEventId, newT }
          : { kind: "translate", eventId: dragEventId, newT },
      );
      snapLineRef.current = e.shiftKey ? tToCanvasPx(newT, rect.width, view) : null;
      return;
    }
    case "moment": {
      // Land the moment where it would be PAINTED: `momentEffective`
      // is the same clamp the lane painter applies, so the diamond
      // follows the pointer to the edge of its entity's span and
      // stops there. `momentOf` names the entity, rather than the
      // clamp naming one kind — a peer's update dragged past its
      // arrival used to reach the engine unclamped, and the engine
      // refused it once per pointer move, which reads as a burst of
      // "invalid edit" errors from one gesture. The engine still
      // refuses out-of-span moves (it owns the rule); this stops the
      // gesture from asking for one.
      const anchorEv = events.find((ev) => ev.id === dragEventId);
      const moment = anchorEv === undefined ? null : momentOf(anchorEv);
      const dispatchT = moment === null ? newT : momentEffective(doc, moment.lane, moment.owner, newT);
      onMoveEvent({
        kind: "translate",
        eventId: dragEventId,
        newT: dispatchT,
      });
      snapLineRef.current = e.shiftKey ? tToCanvasPx(dispatchT, rect.width, view) : null;
      return;
    }
  }
}

/** First-move setup for an event drag: capture the bulk-cohort
 *  snapshot when applicable, then open the undo transaction with a
 *  label that reflects the gesture. Mutates `drag.moved`,
 *  `drag.bulkOriginals`, `drag.txOpen`. */
function engageEventDrag(
  drag: Extract<DragMode, { kind: "event" }>,
  plan: NonNullable<ScrubberHit["drag"]>,
  dragEventId: string,
  events: readonly TimelineEvent[],
  selectionSet: ReadonlySet<EntityRefKey>,
  beginEdit: ((label: string) => void) | undefined,
): void {
  drag.moved = true;
  // Bulk engages only when the dragged event's entity is itself in
  // the multi-selection, AND the plan is a body translate. Edge
  // resizes (span / message) on a selected entity must NOT cohort-
  // translate — that silently loses the resize intent the user
  // reached for. Moments (state-change diamonds) are individually
  // targeted; sibling diamonds in the same session must not move.
  // Pair-ends (peer-left / session-closed / message-delivered) are
  // skipped because the engine's pair-aware `move-event` slides them
  // with their start.
  if (plan.kind === "span-body" || plan.kind === "message-body") {
    const anchorEv = events.find((ev) => ev.id === dragEventId)!;
    const dragEntityKey = entityKey(eventEntityRef(anchorEv));
    if (selectionSet.has(dragEntityKey)) {
      drag.bulkOriginals = [];
      for (const ev of events) {
        if (
          ev.kind === "peer-left" ||
          ev.kind === "session-closed" ||
          ev.kind === "message-delivered"
        ) continue;
        if (!selectionSet.has(entityKey(eventEntityRef(ev)))) continue;
        drag.bulkOriginals.push({
          eventId: ev.id,
          t: ev.t,
          ...(ev.kind === "message-sent" ? { arrivalT: ev.arrivalT } : {}),
        });
      }
    }
  }
  // Bracket the burst in one undo step. Label reflects whether
  // we're bulk-shifting, single-moving, or specifically retiming
  // a message's arrival.
  const label = drag.bulkOriginals
    ? "Move events"
    : plan.kind === "message-edge" && plan.edge === "right"
    ? "Adjust flight time"
    : "Move event";
  beginEdit?.(label);
  drag.txOpen = true;
}
