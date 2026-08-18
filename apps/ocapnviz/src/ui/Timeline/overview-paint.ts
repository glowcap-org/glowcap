/**
 * Per-frame paint for the timeline Overview strip. The React surface
 * in `Overview.tsx` owns gestures and the Pixi scene; this module
 * owns what those pixels say: gutter, visible window, grips, ghost,
 * playhead.
 *
 * Paint order (back → front):
 *   1. Gutter label + vertical separator
 *   2. Visible-window rect
 *   3. Edge grips
 *   4. Hover ghost playhead
 *   5. Real playhead
 */

import type { Graphics } from "pixi.js";
import type { ClockSnapshot } from "../../engine/clock.ts";
import { themedColors } from "../../render/palette.ts";
import { FONT, SIZE, type Theme } from "../tokens.ts";
import { drawGhostPlayhead } from "./ghostPlayhead.ts";
import { gutterWidthOf, plotStartXOf, plotWidthOf, type TimelineView } from "./state.ts";
import { drawEyeGlyph, type EyeGlyphMode, gutterLabelText, HEADER_EYEBALL_X } from "./gutter-paint.ts";
import type { TextPool } from "./textPool.ts";

export function drawOverviewScene(
  graphics: Graphics,
  labelPool: TextPool,
  theme: Theme,
  view: TimelineView,
  clock: ClockSnapshot,
  hoverT: number | null,
  width: number,
  height: number,
  /** All-rows visibility mode for the gutter eyeball. When
   *  undefined the eyeball isn't drawn (no callback wired). */
  allVisMode: EyeGlyphMode | undefined,
): void {
  const colors = themedColors(theme);
  const duration = Math.max(clock.duration, 1);
  const gutterX = gutterWidthOf(view);
  const plotStartX = plotStartXOf(view);
  const plotW = plotWidthOf(width, view);

  graphics.clear();
  labelPool.beginFrame();

  // 1) Gutter — all-rows eyeball (aligned to the Scrubber's
  //    category-eyeball x so the column reads as one continuous
  //    control stack) + "overview" label.
  const gutterCY = height / 2 - 1;
  if (allVisMode !== undefined) {
    drawEyeGlyph(
      graphics,
      HEADER_EYEBALL_X,
      gutterCY,
      allVisMode,
      colors,
      0.7,
    );
  }
  const labelX = allVisMode !== undefined ? HEADER_EYEBALL_X + 8 : 6;
  // Through the same fit the rows below use, so the whole column stops
  // at the same edge — this strip heads the gutter the Scrubber's row
  // labels run down.
  const gutterLabel = gutterLabelText("overview", labelX, gutterX);
  if (gutterLabel) {
    labelPool.acquire(
      gutterLabel,
      {
        fontFamily: FONT.mono,
        fontSize: SIZE.xs,
        fill: colors.textSubtle,
        align: "left",
        baseline: "middle",
      },
      labelX,
      gutterCY,
    );
  }

  // Vertical separator between gutter and plot area.
  graphics
    .moveTo(gutterX + 0.5, 0)
    .lineTo(gutterX + 0.5, height)
    .stroke({ color: colors.text, alpha: 0.15, width: 1 });

  if (plotW <= 0) {
    labelPool.endFrame();
    return;
  }

  // 2) Visible-window rectangle. Anchored at `plotStartX`, NOT
  // `gutterX` — matches the Scrubber's t-content origin so the
  // window's start grip lines up pixel-for-pixel with span left
  // edges below. The left pad between gutter and plotStart is a
  // breathing strip; window/playhead can't bleed into it.
  const startPx = plotStartX + (view.windowStart / duration) * plotW;
  const endPx = plotStartX + (view.windowEnd / duration) * plotW;
  const winWidth = Math.max(2, endPx - startPx);
  graphics
    .rect(startPx, 1, winWidth, height - 2)
    .fill({ color: colors.accent, alpha: 0.15 });
  graphics
    .rect(
      Math.round(startPx) + 0.5,
      1.5,
      Math.round(winWidth) - 1,
      height - 3,
    )
    .stroke({ color: colors.accent, alpha: 0.6, width: 1 });

  // 3) Edge grips.
  graphics
    .rect(Math.round(startPx) - 1, 4, 2, height - 8)
    .fill({ color: colors.accent, alpha: 0.6 });
  graphics
    .rect(Math.round(endPx) - 1, 4, 2, height - 8)
    .fill({ color: colors.accent, alpha: 0.6 });

  // 4) Hover ghost — Macromedia chisel line.
  if (hoverT !== null && hoverT >= 0 && hoverT <= clock.duration) {
    drawGhostPlayhead(
      graphics,
      Math.round(plotStartX + (hoverT / duration) * plotW),
      0,
      height,
      colors.text,
      colors.canvas,
    );
  }

  // 5) Playhead.
  if (clock.t >= 0 && clock.t <= clock.duration) {
    const x = Math.round(plotStartX + (clock.t / duration) * plotW) + 0.5;
    graphics
      .moveTo(x, 0)
      .lineTo(x, height)
      .stroke({ color: colors.accent, width: 1 });
  }

  labelPool.endFrame();
  // `graphics.hitArea` is owned and sized by the caller (see
  // `repaint` in the Overview's effect). Events route through the
  // DOM marker, not federated, so this stays purely defensive
  // against stray Pixi hit-tests.
}
