/**
 * Row-layout: the shared geometry the Scrubber's hit-test, paint
 * path, and React-side render all walk in lockstep. Owns the row
 * pitch constants (`MIN_LANE_HEIGHT`, `LANE_GAP`,
 * `CATEGORY_HEADER_HEIGHT`), the canonical lane stacking order
 * (`LANE_ORDER`), the row-descriptor union, and `iterateRows`
 * itself.
 *
 * Pure data: no React, no Pixi, no engine state mutation. The
 * caller threads `expanded`, `expandedCategories`, the
 * already-ordered entity lists, and the doc's `rowHidden` map in;
 * the generator yields rows in paint order so the renderer and
 * the hit-tester share one source of truth.
 */

import type { TimelineDocument } from "../../engine/timeline.ts";
import {
  type LaneKind,
  plotStartXOf,
  plotWidthOf,
  type TimelineView,
} from "./state.ts";

/** Per-row paint height. Compact rows on a single vertical grid;
 *  the panel grows to fit via intrinsic-height callback. */
export const MIN_LANE_HEIGHT = 14;

/** Height of the ruler band at the bottom of the Scrubber. Shared
 * with the hit-tester (clicks at `py >= height - RULER_HEIGHT` are
 * the ruler, not a lane). */
export const RULER_HEIGHT = 22;

/** Vertical breathing room between the bottom-most lane and the
 * top of the ruler band. Counted into `scrubberHeight` so the
 * intrinsic measurement (and therefore the auto-grow target)
 * reserves the gap; counted into `lanesMaxY` so the lane clip
 * keeps it visually empty. */
export const RULER_TOP_PAD = 4;

/** Vertical gap between rows. Halved on top + bottom of each row
 * during paint so the gap reads as one continuous band between
 * adjacent rows instead of doubling at boundaries. */
export const LANE_GAP = 2;

/**
 * The vertical step from one row to the next.
 *
 * One number because every row takes the same step: `CATEGORY_HEADER_HEIGHT` is
 * `MIN_LANE_HEIGHT`, and the lane height the Scrubber paints at is that same
 * constant, so a header and an entity row are the same size. That is what lets
 * a panel of any height be reduced to a whole number of rows.
 */
export const ROW_PITCH = MIN_LANE_HEIGHT + LANE_GAP;

/**
 * How much of a lane area's height can hold whole rows.
 *
 * A panel is dragged to whatever height a hand stops at, and a row cut through
 * the middle of its label is neither of the two things a reader can act on: it
 * cannot be read and it cannot be scrolled to, because the row it belongs to is
 * counted in the content height and there is nothing past it. Rounding the
 * viewport down leaves at most one row's worth of blank space above the ruler
 * and never a partial row, which is the trade the fitted-height rule already
 * makes.
 */
export function wholeRowsHeight(available: number): number {
  if (available <= 0) return 0;
  return Math.floor(available / ROW_PITCH) * ROW_PITCH;
}

/** Height of an expanded category-header row. Pinned to
 *  `MIN_LANE_HEIGHT` so the header DOESN'T grow when the user
 *  expands the category — every gutter row (collapsed-category,
 *  expanded-category-header, per-entity) renders at the same
 *  height for a consistent vertical rhythm. (Was 18 px when
 *  `laneHeight` was larger, which left the "slim" header
 *  accidentally CHUNKIER than the entity rows after the lane
 *  height dropped to 14 — exactly the expand-makes-it-bigger
 *  jitter the user pointed out.) */
export const CATEGORY_HEADER_HEIGHT = MIN_LANE_HEIGHT;

/** Canonical top-to-bottom stacking order for the three event
 * lanes. Anchored here so the renderer, hit-tester, and React
 * label column all walk lanes in the same order. */
export const LANE_ORDER: readonly Exclude<LaneKind, "ruler">[] = [
  "peers",
  "sessions",
  "messages",
];

/** Captured at the start of a row-drag so the pointermove handler
 * can compute reorders against a stable origin. The `finalIndex`
 * advances each frame as the pointer crosses row midpoints; the
 * commit on pointerup applies that index to the rowOrder. Also
 * drives the paint path's "ghost-row" hint — a horizontal
 * indicator at the resolved target slot. Null when no row drag
 * is active (or the drag hasn't moved past the threshold yet). */
export type RowDragSnapshot = {
  category: Exclude<LaneKind, "ruler">;
  entityId: string;
  startIndex: number;
  finalIndex: number;
};

export type RowDescriptor =
  | {
    kind: "category-collapsed";
    category: Exclude<LaneKind, "ruler">;
    y: number;
    height: number;
  }
  | {
    kind: "category-header";
    category: Exclude<LaneKind, "ruler">;
    y: number;
    height: number;
  }
  | {
    kind: "entity-row";
    category: Exclude<LaneKind, "ruler">;
    entityId: string;
    y: number;
    height: number;
    hidden: boolean;
  };

export function* iterateRows(
  expanded: ReadonlySet<LaneKind>,
  expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>,
  /** Per-category ordered entity ids (already resolved via
   * `orderEntities`). An empty category still gets its row — the
   * lane toggle, not content, decides row existence. */
  orderedEntities: Record<Exclude<LaneKind, "ruler">, readonly string[]>,
  rowHidden: TimelineDocument["rowHidden"],
  laneHeight: number,
): Generator<RowDescriptor> {
  let y = 0;
  for (const lane of LANE_ORDER) {
    if (!expanded.has(lane)) continue;
    // The lane toggle alone decides whether a category row exists —
    // empty or not. Chrome answers to user-set state (the toggle,
    // the expansion set) and never to content: rows that appear and
    // vanish as data changes are unrequested layout shifts, and a
    // group emptied while drilled-down would otherwise lose its
    // chevron and be stuck expanded. A lane the user doesn't want
    // has its own remedy — toggle it off.
    if (!expandedCategories.has(lane)) {
      yield {
        kind: "category-collapsed",
        category: lane,
        y: y + LANE_GAP / 2,
        height: laneHeight,
      };
      y += laneHeight + LANE_GAP;
      continue;
    }
    yield {
      kind: "category-header",
      category: lane,
      y: y + LANE_GAP / 2,
      height: CATEGORY_HEADER_HEIGHT,
    };
    y += CATEGORY_HEADER_HEIGHT + LANE_GAP;
    const hiddenSet = new Set(rowHidden?.[lane] ?? []);
    for (const entityId of orderedEntities[lane]) {
      // `hidden` reports stage visibility, NOT row geometry —
      // every entity-row paints at full `laneHeight` so the row
      // remains interactive (drag-to-reorder, click-to-select,
      // edit on the timeline) regardless of whether the entity
      // is currently rendered on the stage.
      yield {
        kind: "entity-row",
        category: lane,
        entityId,
        y: y + LANE_GAP / 2,
        height: laneHeight,
        hidden: hiddenSet.has(entityId),
      };
      y += laneHeight + LANE_GAP;
    }
  }
}

/** Marquee-clamp bounds for the Scrubber's plot content rect.
 *  The marquee is meaningful only over t-content, so the gutter,
 *  left pad, right pad, and ruler footer are all excluded. One
 *  source of truth shared between the paint-side rubber-band
 *  (scrubber-paint.ts) and the commit-side selection (Scrubber.tsx)
 *  so the visible marching-ants band and the entities the release
 *  selects are pixel-identical (WYSIWYG). `hostHeight` is allowed
 *  to underflow the ruler reserve — the `Math.max(0, ...)` keeps
 *  `maxY` from going negative when the panel collapses. */
/**
 * How tall the row stack `iterateRows` yields actually is.
 *
 * One authority, because three answers to "which rows exist" is what put a
 * half-drawn row at the bottom edge. `iterateRows` includes a category's row
 * whether or not the category holds anything, and says why where it does it:
 * chrome answers to the toggle the user set rather than to content, so a group
 * emptied while drilled-down keeps its chevron instead of getting stuck
 * expanded. The panel's fitted height and the scroll clamp each used to walk
 * the same lanes with their own rule, both skipping an empty category, and both
 * agreed with the row pitch while disagreeing about the rows.
 *
 * What that produced was neither of the two behaviors anybody chose. The
 * panel was fitted to a height with no room for a row the painter drew anyway,
 * the lane mask cut that row through the middle of its label, and the scroll
 * clamp had also left it out, so there was nothing to scroll to and it read as
 * a rendering fault. Deriving both from this walk retires the disagreement:
 * a height that comes from the rows cannot fail to land on a row boundary.
 *
 * `rowHidden` is not a parameter because it is not geometry. Every row paints
 * at full height whatever its stage visibility, which `iterateRows` states at
 * the entity-row it yields.
 */
export function rowStackHeight(
  expanded: ReadonlySet<LaneKind>,
  expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>,
  orderedEntities: Record<Exclude<LaneKind, "ruler">, readonly string[]>,
  laneHeight: number,
): number {
  let bottom = 0;
  for (
    const row of iterateRows(
      expanded,
      expandedCategories,
      orderedEntities,
      undefined,
      laneHeight,
    )
  ) {
    // Each row sits half a gap below its pitch boundary, so the stack's bottom
    // is the last row's far edge plus the other half.
    bottom = row.y + row.height + LANE_GAP / 2;
  }
  return bottom;
}

export function scrubberPlotBounds(
  view: TimelineView,
  hostWidth: number,
  hostHeight: number,
): { minX: number; minY: number; maxX: number; maxY: number } {
  const plotX = plotStartXOf(view);
  const plotW = plotWidthOf(hostWidth, view);
  return {
    minX: plotX,
    minY: 0,
    maxX: plotX + plotW,
    maxY: Math.max(0, hostHeight - RULER_HEIGHT - RULER_TOP_PAD),
  };
}
