/**
 * Scrubber paint pipeline. Per-frame scene rebuild driving the
 * timeline's masked lane stack, ruler footer, playheads, ghost,
 * rubber-band marquee and snap-target overlay. Lives next to its
 * lane-paint / gutter-paint siblings; the Scrubber component
 * orchestrates pointer/keyboard state and calls in here on every
 * tick.
 *
 * Paint order (back → front):
 *   1. Lane gutter separator
 *   2. Lanes top → bottom: header + zebra rows + spans + glyphs
 *   2.5 Scroll-overflow chevrons
 *   3. Ruler footer (minor/major ticks + labels)
 *   4. Hover ghost playhead
 *   5. Playhead (full-height line + ruler dot)
 *   6. Rubber-band selection rect (marching ants)
 *   7. Snap-target vertical line
 *
 * Returns the lane content height so the Scrubber can clamp scroll.
 */

import type { Graphics } from "pixi.js";
import type { ClockSnapshot } from "../../engine/clock.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { entityKey, type EntityRefKey } from "../../interactions/types.ts";
import { clampRectToBounds, paintMarchingAntsBand } from "../../render/geometry.ts";
import { themedColors } from "../../render/palette.ts";
import type { StageSelection } from "../../render/types.ts";
import { drawGhostPlayhead } from "./ghostPlayhead.ts";
import { drawCategoryHeader, drawRowGutter, type EyeGlyphMode } from "./gutter-paint.ts";
import { buildLaneBundle, laneBundleColorsFromTheme, laneRowLabel } from "./lane-bundle.ts";
import { drawLaneGlyphs, drawLaneSpans, orderEntities } from "./lane-paint.ts";
import {
  CATEGORY_HEADER_HEIGHT,
  LANE_GAP,
  LANE_ORDER,
  type RowDragSnapshot,
  rowStackHeight,
  RULER_HEIGHT,
  RULER_TOP_PAD,
  scrubberPlotBounds,
  wholeRowsHeight,
} from "./row-layout.ts";
import { gutterWidthOf, type LaneKind, plotStartXOf, plotWidthOf, type TimelineView, tToCanvasPx } from "./state.ts";
import type { TextPool } from "./textPool.ts";
import { generateTicks, pickTickStep } from "./ticks.ts";
import { FONT, SIZE, type Theme } from "../tokens.ts";

/** Target pixel pitch between major ticks. Smaller = denser
 *  ladder; the cascade in `ticks.ts` walks up units (s → min → hr
 *  → day → mo → yr) until the actual pitch meets or exceeds this. */
const TARGET_MAJOR_PX = 90;

export function drawScrubberScene(
  graphics: Graphics,
  lanesGfx: Graphics,
  /** The lane layer above the span labels, holding the keyframe
   *  glyphs alone. A diamond marks the moment a span changed, so it
   *  has to stay visible where a label runs under it; the label is
   *  the name of a thing the reader can also read in the gutter,
   *  and the diamond is the only mark carrying its moment. */
  lanesGlyphGfx: Graphics,
  laneClip: Graphics,
  labelPool: TextPool,
  lanesLabels: TextPool,
  theme: Theme,
  view: TimelineView,
  clock: ClockSnapshot,
  doc: TimelineDocument,
  events: readonly TimelineEvent[],
  expanded: ReadonlySet<LaneKind>,
  expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>,
  rowOrder: TimelineDocument["rowOrder"],
  rowHidden: TimelineDocument["rowHidden"],
  rowLabelHidden: TimelineDocument["rowLabelHidden"],
  rowBodyHidden: TimelineDocument["rowBodyHidden"],
  categoryVisMode: TimelineDocument["categoryVisMode"],
  width: number,
  height: number,
  laneHeight: number,
  scrubbing: boolean,
  hoverT: number | null,
  selection: StageSelection,
  selectionSet: ReadonlySet<EntityRefKey>,
  rubberBand:
    | { x: number; y: number; width: number; height: number }
    | null,
  snapLineX: number | null,
  hoverGutterRow: string | null,
  rowDrag: RowDragSnapshot | null,
  /** Vertical scroll offset applied to the lane stack. The ruler
   *  is pinned to the bottom and unaffected. */
  scrollY: number,
  /** Sub-selection focus — id of the keyframe glyph that should
   *  receive a halo ring this frame, or null when focus is clear.
   *  Independent of the entity-selection halo. */
  focusedEventId: string | null,
): number {
  const colors = themedColors(theme);
  const windowMs = view.windowEnd - view.windowStart;

  graphics.clear();
  lanesGfx.clear();
  lanesGlyphGfx.clear();
  laneClip.clear();
  labelPool.beginFrame();
  lanesLabels.beginFrame();
  if (windowMs <= 0 || width <= 0) {
    labelPool.endFrame();
    lanesLabels.endFrame();
    return 0;
  }

  // Mask covers the full lane viewport. Anything `lanesGfx` /
  // `lanesLabels` paints outside this rect is clipped — that's
  // what lets us render partial rows at top/bottom edges.
  // The mask matches the row clip exactly, or a row the loop declined to draw
  // would still have its top few pixels admitted by a taller mask.
  const lanesMaxYClip = wholeRowsHeight(height - RULER_HEIGHT - RULER_TOP_PAD);
  laneClip
    .rect(0, 0, width, lanesMaxYClip)
    .fill({ color: 0xffffff, alpha: 1 });

  const gutterX = gutterWidthOf(view);
  const plotX = plotStartXOf(view);
  const plotWidth = plotWidthOf(width, view);
  const tToPx = (t: number) => tToCanvasPx(t, width, view);
  // Row backgrounds (zebra, header tint, hover, drag overlays) are
  // clamped to the plot's t-content band — they do NOT paint through
  // the left/right pads. The pads read as the canvas-color frame
  // (filled below before lane paint), so the visible strip is:
  // gutter → pad (canvas) → row bg (plot) → pad (canvas). T-content
  // (playhead, ticks, spans, glyphs) maps t → canvas px without
  // clamping; anything outside `[plotX, plotX + plotWidth]` is hidden
  // by the `laneClip` mask set up above — but a span pill/glyph
  // overshooting a few px into a pad paints ON TOP of the canvas
  // fill, so the entity stays visible against the background.
  const rowBgX = plotX;
  const rowBgWidth = plotWidth;

  // 1) Lane gutter separator.
  graphics
    .moveTo(gutterX + 0.5, 0)
    .lineTo(gutterX + 0.5, height)
    .stroke({ color: colors.text, alpha: 0.12, width: 1 });

  // 1.5) Solid canvas-color fill over the left/right pads, painted
  // BEFORE lanes so row bgs/zebra/header tints paint only inside the
  // plot band and the pads stay pure canvas — i.e. read as part of
  // the panel background. Spans and glyphs that overshoot into a pad
  // paint on top, so entities stay legible at the frame edge.
  {
    const leftPadW = plotX - (gutterX + 1);
    if (leftPadW > 0) {
      lanesGfx
        .rect(gutterX + 1, 0, leftPadW, lanesMaxYClip)
        .fill({ color: colors.canvas, alpha: 1 });
    }
    const rightPadX = plotX + plotWidth;
    const rightPadW = Math.max(0, width - rightPadX);
    if (rightPadW > 0) {
      lanesGfx
        .rect(rightPadX, 0, rightPadW, lanesMaxYClip)
        .fill({ color: colors.canvas, alpha: 1 });
    }
  }

  // 2) Lanes top→bottom. Bundle memoized per (events, entities,
  // duration, theme); open spans use Infinity for endT and clip
  // at the visible window. Eternal-start entities (in `entities`
  // without a creation event) get synthesized spans inside
  // `buildLaneBundle`.
  const bundle = buildLaneBundle(
    doc,
    events,
    clock.duration,
    laneBundleColorsFromTheme(theme),
    theme,
  );
  // Lanes paint from the top down; ruler pins to the bottom. If the
  // panel is too short to hold both, lanes that would intrude into
  // the ruler band simply don't draw — visible content gets clipped
  // until scroll lands (planned) or the user resizes bigger. Never
  // overlap the ruler. The `RULER_TOP_PAD` keeps a few pixels of
  // breathing room between the bottom lane and the ruler ticks.
  // Rounded down to whole rows, so a panel dragged to an arbitrary height
  // clips at a row boundary rather than through a row. `wholeRowsHeight` owns
  // the rule and says why.
  const lanesMaxY = wholeRowsHeight(height - RULER_HEIGHT - RULER_TOP_PAD);
  // Total lane content height (layout coords), independent of the paint loop's
  // bottom-clip. The wheel clamp uses this to compute
  // `scrollYMax = max(0, contentHeight - lanesViewport)`.
  //
  // From `rowStackHeight`, the same walk the rows below are painted from. This
  // used to step the lanes here instead, reusing the pitch constants but
  // applying its own rule about which rows exist, and skipping a category that
  // held nothing. The rows were painted anyway, so a clamp that had left them
  // out reported nothing to scroll to while the last of them sat clipped under
  // the ruler — half a row the reader could neither see whole nor scroll into
  // view.
  // Resolved once for the frame rather than per category inside the paint loop:
  // the height needs all three lanes before the loop starts, and the loop then
  // reads the same answer instead of deriving its own.
  const orderedByLane = {
    peers: orderEntities(bundle.peers.byEntity, rowOrder?.peers),
    sessions: orderEntities(bundle.sessions.byEntity, rowOrder?.sessions),
    messages: orderEntities(bundle.messages.byEntity, rowOrder?.messages),
  };
  const contentHeight = rowStackHeight(
    expanded,
    expandedCategories,
    orderedByLane,
    laneHeight,
  );
  // `y` is the LAYOUT cursor (unscrolled); paint coords subtract
  // `scrollY`. Keeping the cursor in layout space keeps row-drag
  // insertion-index math identical to the scrollY=0 case.
  //
  // Lane paint is wrapped in a block that shadows `graphics` and
  // `labelPool` with the masked `lanesGfx` / `lanesLabels`. Every
  // `.rect()` / `.fill()` / helper call inside the for-loop now
  // paints into the masked container — partial rows at the top
  // and bottom of the viewport render normally and the mask clips
  // them at lanesMaxY (bottom) and 0 (top). Chrome (gutter line,
  // ruler, playhead, scrollbar, chevrons) keeps writing to the
  // unmasked `graphics` outside the block.
  {
    // eslint-disable-next-line @typescript-eslint/no-shadow
    const graphics = lanesGfx;
    // eslint-disable-next-line @typescript-eslint/no-shadow
    const labelPool = lanesLabels;
    let y = 0;
    let zebraIndex = 0;
    for (const lane of LANE_ORDER) {
      if (!expanded.has(lane)) continue;

      const laneData = bundle[lane];
      const laneKindSingular = laneKindForSelection(lane);
      const highlightId = selection?.kind === laneKindSingular ? selection.id : null;
      // Halo applies to BOTH the single-selection id and every
      // entity in the unified selection set. `spanId` is the
      // owning entity's id; we form the entity ref key for this
      // lane's kind and look it up. Pair-ends share the same
      // spanId (they paint into one entity row), so both light up
      // together for free.
      const isSelected = (spanId: string): boolean =>
        spanId === highlightId ||
        selectionSet.has(entityKey({ kind: laneKindSingular, id: spanId }));
      // Anchor (the Inspector-follow entity) is always
      // `selection?.kind === laneKind && selection.id === spanId` —
      // App passes the store's anchor through as `selection`. The
      // halo paints thicker for the anchor so the user reads
      // which selected span the Inspector tracks under multi-
      // select.
      const isAnchor = (spanId: string): boolean => spanId === highlightId;
      const isExpandedCategory = expandedCategories.has(lane);

      // Bail when the lane's TOP edge falls below the viewport —
      // anything below that won't even partially render through the
      // mask. Subsequent lanes start even lower, so break entirely.
      // (Pre-mask this was a tighter "header bottom past lanesMaxY"
      // check; the mask now handles the bottom-clip visually, so we
      // only need a cheaper "fully offscreen below" check here.)
      if ((y - scrollY) > lanesMaxY) break;

      if (!isExpandedCategory) {
        // Collapsed view (today's look): one row, stacked-spans summary.
        const laneY = (y + LANE_GAP / 2) - scrollY;
        const laneCenterY = laneY + laneHeight / 2;
        // Top cull: only skip when the row is ENTIRELY above the
        // viewport. Partial rows render and get clipped by the mask
        // so the user sees them peeking in as they scroll. Advance
        // the layout cursor so subsequent rows keep their position.
        if (laneY + laneHeight < 0) {
          y += laneHeight + LANE_GAP;
          zebraIndex += 1;
          continue;
        }

        // Hover bg on the gutter portion of the row — same
        // "button-like" affordance you'd get from a list-item hover
        // in the rest of the app. Drawn behind the chevron/label so
        // it never obscures the glyph.
        if (hoverGutterRow === `header:${lane}`) {
          graphics
            .rect(0, laneY, gutterX, laneHeight)
            .fill({ color: colors.text, alpha: 0.05 });
        }

        // Lane label with chevron indicating it can be expanded.
        // Eyeball glyph reads the STORED category flag directly —
        // independent of per-entity flags (the cascade is applied
        // at draw time in the Stage, not surveyed here).
        drawCategoryHeader(
          graphics,
          labelPool,
          lane,
          laneCenterY,
          colors,
          false, // collapsed
          gutterX,
          categoryVisMode?.[lane] ?? "visible",
        );

        graphics
          .rect(rowBgX, laneY, rowBgWidth, laneHeight)
          .fill({
            color: colors.text,
            alpha: zebraIndex % 2 === 0 ? 0.02 : 0.06,
          });
        zebraIndex += 1;

        drawLaneSpans(
          graphics,
          labelPool,
          laneData.spans,
          view,
          tToPx,
          laneCenterY,
          laneHeight,
          plotX,
          plotWidth,
          colors,
          isSelected,
          isAnchor,
        );

        drawLaneGlyphs(
          lanesGlyphGfx,
          laneData.glyphs,
          view,
          tToPx,
          laneCenterY,
          laneHeight,
          plotX,
          plotWidth,
          focusedEventId,
          colors.accent,
        );

        y += laneHeight + LANE_GAP;
        continue;
      }

      // Expanded view: slim header row + one row per entity.
      const headerLaneY = (y + LANE_GAP / 2) - scrollY;
      const headerCenterY = headerLaneY + CATEGORY_HEADER_HEIGHT / 2;
      // Top cull: only skip when the header is ENTIRELY above the
      // viewport. Partial headers render and get clipped by the
      // mask. (Pre-mask any negative-y header was dropped to avoid
      // bleeding into the Overview pane above; the mask handles
      // that visually now.)
      const headerOffTop = headerLaneY + CATEGORY_HEADER_HEIGHT < 0;
      // Persistent gutter tint on the header — distinctly
      // stronger than the entity-row zebra below so the parent
      // / child boundary is legible at a glance, plus the
      // entity-row indent (`ROW_INDENT_PX`) reinforcing the
      // tree-list hierarchy. Hover tint stacks on top for the
      // usual button affordance.
      if (!headerOffTop) {
        graphics
          .rect(0, headerLaneY, gutterX, CATEGORY_HEADER_HEIGHT)
          .fill({ color: colors.text, alpha: 0.08 });
        if (hoverGutterRow === `header:${lane}`) {
          graphics
            .rect(0, headerLaneY, gutterX, CATEGORY_HEADER_HEIGHT)
            .fill({ color: colors.text, alpha: 0.05 });
        }
        drawCategoryHeader(
          graphics,
          labelPool,
          lane,
          headerCenterY,
          colors,
          true, // expanded
          gutterX,
          categoryVisMode?.[lane] ?? "visible",
        );
        // Header band tint over the row body — a tick stronger
        // than the row zebra (which tops out at 0.06) so the
        // header reads as a continuous label band, not just
        // another row. Extends through both pads via `rowBgX/W`.
        graphics
          .rect(rowBgX, headerLaneY, rowBgWidth, CATEGORY_HEADER_HEIGHT)
          .fill({ color: colors.text, alpha: 0.08 });
      }
      // 1-px divider under the header, spanning the FULL panel
      // (gutter + plot). Makes the parent / children boundary
      // explicit — the gutter tint + plot tint above set the
      // grouping intent; this rule gives a visible "everything
      // below is INSIDE this category" cut, the same way Flash /
      // After Effects show layer-group borders.
      //
      // Lives in the LANE_GAP region BELOW the header (not at the
      // header's last pixel) so it can't touch the bottom of the
      // category-eyeball glyph — the `label`-mode eye renders a
      // 1-px strike at `centerY + 5` (= header bottom - 2). Sliding
      // the divider 1 px down leaves a clean 1-px breathing band
      // between the two horizontal marks.
      if (!headerOffTop) {
        graphics
          .rect(0, headerLaneY + CATEGORY_HEADER_HEIGHT, width, 1)
          .fill({ color: colors.text, alpha: 0.18 });
      }
      zebraIndex += 1;
      y += CATEGORY_HEADER_HEIGHT + LANE_GAP;

      // The per-entity order, resolved once for the frame above: explicit
      // `rowOrder[category]` first (in given order), then any unlisted
      // entities sorted by first-event-t (the default).
      const orderedEntities = orderedByLane[lane];
      const hiddenSet = new Set(rowHidden?.[lane] ?? []);
      const labelHiddenSet = new Set(rowLabelHidden?.[lane] ?? []);
      const bodyHiddenSet = new Set(rowBodyHidden?.[lane] ?? []);

      // Row-reorder drag state for this category, plus the y at
      // which the insertion bar (drop target) should paint. Tracked
      // during the row loop so we can draw the bar after the rows
      // finish — drawing it inline would risk being overwritten by
      // the next row's zebra fill. `dropY` lines up with the TOP
      // edge of the row currently occupying `finalIndex` (the row
      // being dragged is dimmed in-place; the bar shows the
      // landing slot, accounting for the rest of the rows shifting
      // out of the way on commit).
      const laneRowDrag = rowDrag?.category === lane ? rowDrag : null;
      let dropY: number | null = null;

      let entityIndex = 0;
      for (const entityId of orderedEntities) {
        const entityData = laneData.byEntity.get(entityId);
        if (!entityData) continue;
        // Resolve the per-entity visibility mode (4-state — see
        // engine's `setRowVisMode`). The three doc lists are
        // exclusive so first-match-wins.
        const visMode: EyeGlyphMode = hiddenSet.has(entityId)
          ? "both"
          : labelHiddenSet.has(entityId)
          ? "label"
          : bodyHiddenSet.has(entityId)
          ? "body"
          : "visible";
        const isHidden = visMode !== "visible";
        const isDragSource = laneRowDrag?.entityId === entityId;
        const rowH = laneHeight;
        const rowY = (y + LANE_GAP / 2) - scrollY;
        const rowCenterY = rowY + rowH / 2;
        // Bottom cull: only break when the row's TOP edge is
        // already below the viewport. Partial rows at the bottom
        // render and get clipped by the mask (pre-mask we had to
        // hard-break to keep paint out of the ruler band).
        if (rowY > lanesMaxY) break;
        // Top cull: only skip when the row is ENTIRELY above the
        // viewport — partial top rows render through the mask.
        const rowOffTop = rowY + rowH < 0;

        if (laneRowDrag && entityIndex === laneRowDrag.finalIndex) {
          dropY = rowY;
        }

        if (rowOffTop) {
          // Scrolled above the viewport — advance the layout cursor
          // and skip all painting + zebra accounting consistent with
          // the visible region.
          y += rowH + LANE_GAP;
          entityIndex += 1;
          zebraIndex += 1;
          continue;
        }

        // Zebra row tint, dimmed when the entity is hidden ON STAGE
        // (the eyeball semantics — see `RowHidden` doctrine in
        // engine/timeline.ts) OR when the row is the source of an
        // in-flight reorder drag (visually lifted so the user sees
        // what's moving). The row stays at full height so
        // selection / drag / scrub all keep working.
        graphics
          .rect(rowBgX, rowY, rowBgWidth, rowH)
          .fill({
            color: colors.text,
            alpha: (zebraIndex % 2 === 0 ? 0.02 : 0.06) *
              (isHidden ? 0.5 : 1) *
              (isDragSource ? 0.4 : 1),
          });
        // Accent-tinted overlay on the source row so it reads as
        // "this is moving" against the neutral zebra of its
        // siblings. Spans the full canvas width (gutter + content +
        // pads) so the lift reads as one continuous strip.
        if (isDragSource) {
          graphics
            .rect(0, rowY, width, rowH)
            .fill({ color: colors.accent, alpha: 0.06 });
        }
        zebraIndex += 1;

        // Hover bg over the gutter side of the entity row (matches
        // header-row affordance above).
        if (hoverGutterRow === `entity:${lane}:${entityId}`) {
          graphics
            .rect(0, rowY, gutterX, rowH)
            .fill({ color: colors.text, alpha: 0.05 });
        }

        // Gutter: eyeball + the row's name. The name is the one the
        // row's own span carries, read back through `laneRowLabel`, so
        // the column and the pill beside it cannot call one entity two
        // things. `visMode` selects the 4-state glyph (visible / label
        // / body / both) — see `drawEyeGlyph`. The label dims when ANY
        // hidden state is active so partially-hidden rows read as muted.
        drawRowGutter(
          graphics,
          labelPool,
          laneRowLabel(entityData, entityId),
          rowCenterY,
          visMode,
          colors,
          gutterX,
        );

        drawLaneSpans(
          graphics,
          labelPool,
          entityData.spans,
          view,
          tToPx,
          rowCenterY,
          rowH,
          plotX,
          plotWidth,
          colors,
          isSelected,
          isAnchor,
        );
        drawLaneGlyphs(
          lanesGlyphGfx,
          entityData.glyphs,
          view,
          tToPx,
          rowCenterY,
          rowH,
          plotX,
          plotWidth,
          focusedEventId,
          colors.accent,
        );

        y += rowH + LANE_GAP;
        entityIndex += 1;
      }

      // Drop-target insertion bar — drawn AFTER the row loop so it
      // sits on top of the zebra tint at the landing slot. 2px
      // accent-colored line spanning the full row width (gutter +
      // plot) so it reads as "this is where the dragged row lands".
      if (laneRowDrag !== null && dropY !== null) {
        graphics
          .rect(0, dropY - 1, width, 2)
          .fill({ color: colors.accent, alpha: 0.9 });
      }
    }
  }
  // 2.5) Scroll-overflow chevrons in the gutter — passive visual
  // cue when rows exist above or below the visible lane viewport.
  // The Scrubber culls partially-offscreen rows by design (so they
  // don't bleed into the Overview above or the ruler below), which
  // means the user has no other signal that more rows exist. A small
  // ▴/▾ pair centered in the gutter, at the top/bottom of the lane
  // band, fills that gap. Painted before the ruler so the ruler chrome
  // sits on top if positions ever overlap.
  const scrollYMax = Math.max(0, contentHeight - lanesMaxY);
  if (gutterX >= 12) {
    const cx = gutterX / 2;
    const chevW = 9;
    const chevH = 6;
    if (scrollY > 0.5) {
      // Top chevron — tip pushed ABOVE the Scrubber's top edge
      // into the Overview region of the shared Pixi canvas. The
      // Overview repaints every frame and sits earlier in scene
      // order so its bg covers the bleed visually; the visible
      // pixels of the chevron are the lower portion sitting in
      // the empty top strip of the lane viewport (gutter has no
      // lane content at y=0 yet because the first row's TOP edge
      // is at y=0 in layout space, but with scroll>0 the visible
      // top is empty gutter — the chevron has room).
      const tipY = -7;
      graphics
        .moveTo(cx - chevW / 2, tipY + chevH)
        .lineTo(cx, tipY)
        .lineTo(cx + chevW / 2, tipY + chevH)
        .closePath()
        .fill({ color: colors.textSubtle, alpha: 0.55 });
    }
    if (scrollY < scrollYMax - 0.5) {
      // Bottom chevron — tip pushed DOWN into the ruler band's
      // top strip (above the highest tick line at y=height-12).
      // Ruler ticks paint AFTER the chevron on the same Graphics
      // so any overlap reads as ticks-over-chevron, which is fine
      // since they don't collide at the chosen y.
      const tipY = height - RULER_HEIGHT + 4;
      graphics
        .moveTo(cx - chevW / 2, tipY - chevH)
        .lineTo(cx, tipY)
        .lineTo(cx + chevW / 2, tipY - chevH)
        .closePath()
        .fill({ color: colors.textSubtle, alpha: 0.55 });
    }
  }

  // 3) Ruler footer.
  const rulerY = height - RULER_HEIGHT;
  const pxPerMs = plotWidth / windowMs;
  const step = pickTickStep(pxPerMs, TARGET_MAJOR_PX);
  const ticks = generateTicks(view.windowStart, view.windowEnd, step);

  for (const t of ticks.minor) {
    const x = Math.round(tToPx(t)) + 0.5;
    if (x < plotX - 1 || x > plotX + plotWidth + 1) continue;
    graphics.moveTo(x, height - 6).lineTo(x, height - 1);
  }
  graphics.stroke({ color: colors.text, alpha: 0.18, width: 1 });

  for (const t of ticks.major) {
    const x = Math.round(tToPx(t)) + 0.5;
    if (x < plotX - 1 || x > plotX + plotWidth + 1) continue;
    graphics.moveTo(x, height - 12).lineTo(x, height - 1);
  }
  graphics.stroke({ color: colors.text, alpha: 0.5, width: 1 });

  const plotRight = plotX + plotWidth;
  for (const t of ticks.major) {
    const x = Math.round(tToPx(t));
    if (x < plotX - 40 || x > plotRight + 40) continue;
    const label = step.format(t);
    const rightAligned = x > plotRight - 20;
    labelPool.acquire(
      label,
      {
        fontFamily: FONT.mono,
        fontSize: SIZE.xs,
        fill: colors.textSubtle,
        align: rightAligned ? "right" : "left",
        baseline: "alphabetic",
      },
      x + (rightAligned ? -3 : 4),
      height - 14,
    );
  }

  // 4) Hover ghost.
  if (
    hoverT !== null &&
    hoverT >= view.windowStart &&
    hoverT <= view.windowEnd
  ) {
    drawGhostPlayhead(
      graphics,
      Math.round(tToPx(hoverT)),
      0,
      height,
      colors.text,
      colors.canvas,
    );
  }

  // 5) Playhead — full-height line + ruler dot. In Live the
  //    clock is the capture head, so the playhead always has a
  //    "where I am" to point at.
  if (clock.t >= view.windowStart && clock.t <= view.windowEnd) {
    const x = Math.round(tToPx(clock.t)) + 0.5;
    const headColor = scrubbing ? colors.textSubtle : colors.accent;
    graphics
      .moveTo(x, 0)
      .lineTo(x, height)
      .stroke({ color: headColor, width: 2 });
    graphics
      .circle(x, rulerY - 3, 3)
      .fill({ color: headColor });
  }

  // 6) Rubber-band selection rectangle. Same marching-ants
  // treatment as the Stage marquee (`paintMarchingAntsBand`) so
  // the two selection surfaces feel like one tool. Drawn ON TOP
  // of everything so the user always sees the selection bounds
  // even when overlapping pills; the ticker repaint keeps the
  // ants marching while the drag is in flight.
  if (rubberBand) {
    // Clamp to the plot content rect — the marquee is only meaningful
    // over t-content, so it can't bleed into the gutter, left pad, or
    // right pad. Same bounds the commit-side selection clamps to
    // (Scrubber.tsx threads its `regionSizeRef` into the same helper),
    // so the visible band and the selected events stay WYSIWYG.
    const clamped = clampRectToBounds(
      rubberBand,
      scrubberPlotBounds(view, width, height),
    );
    paintMarchingAntsBand(
      graphics,
      Math.round(clamped.x),
      Math.round(clamped.y),
      Math.round(clamped.width),
      Math.round(clamped.height),
    );
  }

  // 7) Snap-target line — drawn while Shift is held during an
  // event drag, at the pixel of the snapped t. Thin accent
  // vertical so the user sees where the value will land.
  if (snapLineX !== null) {
    const xR = Math.round(snapLineX) + 0.5;
    graphics
      .moveTo(xR, 0)
      .lineTo(xR, height)
      .stroke({ color: colors.accent, width: 1, alpha: 0.6 });
  }

  labelPool.endFrame();
  lanesLabels.endFrame();
  // `graphics.hitArea` is owned and sized by the caller (see
  // `repaint` in the Scrubber's effect) — Pixi reads it on event
  // dispatch, not per frame.
  return contentHeight;
}

/** Map a lane bucket to the selection `kind` whose `id` lives in
 * its spans (`spans` in `bundle.peers` carry peer ids, etc). */
function laneKindForSelection(
  lane: Exclude<LaneKind, "ruler">,
): "peer" | "session" | "message" {
  return lane === "peers" ? "peer" : lane === "sessions" ? "session" : "message";
}
