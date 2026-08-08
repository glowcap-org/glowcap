/**
 * Row-gutter paint helpers — the column on the left of each
 * Scrubber lane that carries the chevron, the eyeball, and the
 * row label. Three functions and the geometry that pins them:
 *
 *   drawCategoryHeader  — expanded-category header row
 *   drawRowGutter       — per-entity row gutter
 *   drawEyeGlyph        — shared 4-state visibility glyph
 *
 * The Overview strip reuses `drawEyeGlyph` + `HEADER_EYEBALL_X`
 * so the all-rows control stacks on the same x as Scrubber's
 * category eyeballs (one continuous control column).
 */

import type { Graphics } from "pixi.js";
import type { LaneKind } from "./state.ts";
import type { ThemedColors } from "../../render/palette.ts";
import { FONT, SIZE } from "../tokens.ts";
import { monoAdvance, truncateToWidth } from "./label-layout.ts";
import type { TextPool } from "./textPool.ts";

/** x-position of the category chevron on header rows. Hit-test
 * uses ±8 px around this. */
export const HEADER_CHEVRON_X = 8;

/** x-position of the CATEGORY eyeball on header rows. Sits to the
 * right of the chevron so the chevron-toggle and visibility-toggle
 * don't compete for the same click target. Hit-test ±8 px.
 *
 * Exported so Overview's all-rows eyeball can stack on the same x
 * — the gutter reads as one continuous control column. */
export const HEADER_EYEBALL_X = 24;

/** Per-entity rows nest UNDER the category header — same
 *  tree-list convention as Finder / VS Code / Premiere's
 *  timeline panel. The 6 px indent (relative to
 *  HEADER_EYEBALL_X) gives the eye + label a visible offset so
 *  the parent / child relationship reads at a glance instead of
 *  having to be inferred from the chevron alone. */
export const ROW_INDENT_PX = 6;

/** x-position of the row eyeball on per-entity rows. Hit-test
 * uses ±8 px around this. */
export const ROW_EYEBALL_X = HEADER_EYEBALL_X + ROW_INDENT_PX;

/** x-position of the entity-id label on per-entity rows. The
 * gutter region from here to LANE_LABEL_WIDTH is the row-drag-
 * handle grab area. */
export const ROW_LABEL_X = ROW_EYEBALL_X + 12;

/** Right-edge padding for gutter labels — leaves room for the
 *  resize seam without the text crowding the divider. */
export const GUTTER_LABEL_RIGHT_PAD_PX = 6;

/**
 * As much of `label` as fits the gutter, ending in an ellipsis when
 * that is less than all of it.
 *
 * Every label in this column comes through here, because the column
 * has a hard right edge — the divider the reader can drag — and a
 * glyph past it lands in the plot, on top of the spans. The width is
 * whatever the reader left between `labelX` and that divider, less
 * the pad, so the answer changes on every frame of a resize drag.
 *
 * Returns the empty string when there is no room for even one
 * character; callers skip the label rather than paint a smudge.
 */
export function gutterLabelText(
  label: string,
  labelX: number,
  gutterWidth: number,
): string {
  const budget = Math.max(
    0,
    gutterWidth - labelX - GUTTER_LABEL_RIGHT_PAD_PX,
  );
  return truncateToWidth(label, budget, monoAdvance(SIZE.xs));
}

/** Visibility modes for the per-entity eyeball glyph. Mirrors
 * the engine's row-vis-mode enum: `visible` = open eye, `label` =
 * eye + label-strikethrough mark below, `body` = eye outline
 * only (no pupil), `both` = slashed eye. The four glyphs are
 * picked to be distinguishable at the 8px scale we paint at;
 * the cursor tooltip on the gutter eyeball spells out the
 * current state so the glyph doesn't have to carry semantics
 * unaided. */
export type EyeGlyphMode = "visible" | "label" | "body" | "both";

export function drawCategoryHeader(
  graphics: Graphics,
  labelPool: TextPool,
  category: Exclude<LaneKind, "ruler">,
  centerY: number,
  colors: ThemedColors,
  isExpanded: boolean,
  gutterWidth: number,
  /** Stored category flag — independent of per-entity flags.
   *  Renders the matching eye glyph directly; the cascade
   *  (all → category → entity) is applied at draw time in the
   *  Stage, not surveyed here. */
  categoryVisMode: EyeGlyphMode,
): void {
  // Chevron — small triangle pointing right (collapsed) or down
  // (expanded). Drawn as a filled polygon to keep stroke width
  // out of the equation; muted color so it doesn't compete with
  // the label.
  const size = 4;
  if (isExpanded) {
    // ▾ — pointing down
    graphics
      .poly([
        HEADER_CHEVRON_X - size,
        centerY - 1,
        HEADER_CHEVRON_X + size,
        centerY - 1,
        HEADER_CHEVRON_X,
        centerY + size - 1,
      ])
      .fill({ color: colors.text, alpha: 0.55 });
  } else {
    // ▸ — pointing right
    graphics
      .poly([
        HEADER_CHEVRON_X - 1,
        centerY - size,
        HEADER_CHEVRON_X - 1,
        centerY + size,
        HEADER_CHEVRON_X + size - 1,
        centerY,
      ])
      .fill({ color: colors.text, alpha: 0.55 });
  }
  // Category eyeball — same 4-state glyph as the per-entity
  // row eyeball, painted dimmer so the visual hierarchy on
  // the header row reads as "category heading first, controls
  // available second". `"mixed"` collapses to the `both` glyph
  // since both states denote "category is not in a uniform
  // visible state" and the next click is a deterministic
  // reset to `visible` (the engine's `setCategoryVisMode`
  // cycle).
  drawEyeGlyph(
    graphics,
    HEADER_EYEBALL_X,
    centerY,
    categoryVisMode,
    colors,
    0.55,
  );
  const labelX = HEADER_EYEBALL_X + 8;
  const text = gutterLabelText(category, labelX, gutterWidth);
  if (text) {
    labelPool.acquire(
      text,
      {
        // Tiny gutter label (SIZE.xs). Per the typography rule's
        // size-first default, tiny → mono; matches the sibling
        // "overview" gutter label in `Overview.tsx` and the tick
        // labels below.
        //
        // `colors.text` (full strength) — the category header is
        // a parent in the tree-list, so it gets the brighter
        // label color; per-entity rows below sit on
        // `colors.text` too but inside an indent + lighter
        // background tint, so the visual weight still cascades
        // header → entities correctly.
        fontFamily: FONT.mono,
        fontSize: SIZE.xs,
        fill: colors.text,
        align: "left",
        baseline: "middle",
      },
      labelX,
      centerY,
    );
  }
}

export function drawEyeGlyph(
  graphics: Graphics,
  cx: number,
  cy: number,
  mode: EyeGlyphMode,
  colors: ThemedColors,
  baseAlpha: number,
): void {
  const dim = mode === "both" ? 0.55 : 1;
  const alpha = baseAlpha * dim;
  // Eye outline (always present so the cycling glyphs stay
  // visually anchored at the same spot regardless of state).
  graphics
    .circle(cx, cy, 4)
    .stroke({ color: colors.text, width: 1, alpha });
  switch (mode) {
    case "visible":
      // Pupil — small filled center.
      graphics
        .circle(cx, cy, 1.4)
        .fill({ color: colors.text, alpha });
      break;
    case "label":
      // Pupil + a tiny strikethrough bar BELOW the eye — reads
      // as "label part of the entity is suppressed".
      graphics
        .circle(cx, cy, 1.4)
        .fill({ color: colors.text, alpha });
      graphics
        .rect(cx - 3.5, cy + 5, 7, 1)
        .fill({ color: colors.text, alpha });
      break;
    case "body":
      // No pupil — the eye is open but the "thing it sees" is
      // gone. Pairs visually with the label-strike (top
      // emptied vs. bottom struck) for at-a-glance distinction.
      break;
    case "both":
      // Slash-eye: diagonal line through the circle.
      graphics
        .moveTo(cx - 4.5, cy - 4.5)
        .lineTo(cx + 4.5, cy + 4.5)
        .stroke({ color: colors.text, width: 1, alpha });
      break;
  }
}

/** Per-entity row's gutter content — eyeball glyph + the row's name.
 * `label` is what the row's own pill is called, so the column and the
 * spans beside it call one thing one name; `laneRowLabel` in
 * `lane-bundle.ts` is where a caller gets it. `mode` drives the
 * four-state glyph (see `drawEyeGlyph`); the label dims slightly when
 * ANY hidden state is active so a partially-hidden row reads as "this
 * exists but is muted on stage" without losing legibility. */
export function drawRowGutter(
  graphics: Graphics,
  labelPool: TextPool,
  label: string,
  centerY: number,
  mode: EyeGlyphMode,
  colors: ThemedColors,
  gutterWidth: number,
): void {
  const isHidden = mode !== "visible";
  drawEyeGlyph(graphics, ROW_EYEBALL_X, centerY, mode, colors, 0.7);
  const text = gutterLabelText(label, ROW_LABEL_X, gutterWidth);
  if (text) {
    labelPool.acquire(
      text,
      {
        fontFamily: FONT.mono,
        fontSize: SIZE.xs,
        fill: isHidden ? colors.textSubtle : colors.text,
        align: "left",
        baseline: "middle",
      },
      ROW_LABEL_X,
      centerY,
    );
  }
}
