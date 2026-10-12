/**
 * Scrubber static paint pipeline: mask, pads, the masked lane stack
 * (`lane-stack-paint.ts`), then ruler chrome. The caller caches this
 * viewport-sized scene, `scrubber-overlay-paint.ts` owns the moving marks.
 * The Scrubber component orchestrates pointer/keyboard state and
 * calls in here on every tick.
 *
 * Paint order (back → front):
 *   1. Lane gutter separator
 *   2. Lane stack (headers, zebra, spans, glyphs, row-drag bar)
 *   2.5 Scroll-overflow chevrons
 *   3. Ruler footer (minor/major ticks + labels)
 * Returns the lane content height so the Scrubber can clamp scroll.
 */

import type { Graphics } from "pixi.js";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import type { EntityRefKey } from "../../interactions/types.ts";
import { themedColors } from "../../render/palette.ts";
import type { StageSelection } from "../../render/types.ts";
import { buildLaneBundle, laneBundleColorsFromTheme } from "./lane-bundle.ts";
import { orderEntities } from "./lane-paint.ts";
import { drawLaneStack } from "./lane-stack-paint.ts";
import { laneScrollMax, laneViewportHeight, type RowDragSnapshot, rowStackHeight, RULER_HEIGHT } from "./row-layout.ts";
import { gutterWidthOf, type LaneKind, plotStartXOf, plotWidthOf, type TimelineView, tToCanvasPx } from "./state.ts";
import type { TextPool } from "./textPool.ts";
import { generateTicks, pickTickStep } from "./ticks.ts";
import { FONT, SIZE, type Theme } from "../tokens.ts";

/** Target pixel pitch between major ticks. Smaller = denser
 *  ladder. The cascade in `ticks.ts` walks up units (s → min → hr
 *  → day → mo → yr) until the actual pitch meets or exceeds this. */
const TARGET_MAJOR_PX = 90;

export function drawScrubberScene(
	graphics: Graphics,
	lanesGfx: Graphics,
	/** The lane layer above the span labels, holding the keyframe
	 *  glyphs alone. A diamond marks the moment a span changed, so it
	 *  has to stay visible where a label runs under it. The label is
	 *  the name of a thing the reader can also read in the gutter,
	 *  and the diamond is the only mark carrying its moment. */
	lanesGlyphGfx: Graphics,
	laneClip: Graphics,
	labelPool: TextPool,
	lanesLabels: TextPool,
	theme: Theme,
	view: TimelineView,
	duration: number,
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
	selection: StageSelection,
	selectionSet: ReadonlySet<EntityRefKey>,
	hoverGutterRow: string | null,
	rowDrag: RowDragSnapshot | null,
	/** Vertical scroll offset applied to the lane stack. The ruler
	 *  is pinned to the bottom and unaffected. */
	scrollY: number,
	/** Sub-selection focus, id of the keyframe glyph that should
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
	// `lanesLabels` paints outside this rect is clipped, that's
	// what lets us render partial rows at top/bottom edges.
	// The mask matches the row clip exactly, or a row the loop declined to draw
	// would still have its top few pixels admitted by a taller mask.
	const lanesMaxYClip = laneViewportHeight(height);
	laneClip
		.rect(0, 0, width, lanesMaxYClip)
		.fill({ color: 0xffffff, alpha: 1 });

	const gutterX = gutterWidthOf(view);
	const plotX = plotStartXOf(view);
	const plotWidth = plotWidthOf(width, view);
	const tToPx = (t: number) => tToCanvasPx(t, width, view);
	// Row backgrounds (zebra, header tint, hover, drag overlays) are
	// clamped to the plot's t-content band. They do NOT paint through
	// the left/right pads. The pads read as the canvas-color frame
	// (filled below before lane paint), so the visible strip is:
	// gutter → pad (canvas) → row bg (plot) → pad (canvas). T-content
	// (playhead, ticks, spans, glyphs) maps t → canvas px without
	// clamping; anything outside `[plotX, plotX + plotWidth]` is hidden
	// by the `laneClip` mask set up above, but a span pill/glyph
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
	// plot band and the pads stay pure canvas, i.e. read as part of
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
		duration,
		laneBundleColorsFromTheme(theme),
		theme,
	);
	// Lanes paint from the top down; ruler pins to the bottom. If the
	// panel is too short to hold both, lanes that would intrude into
	// the ruler band simply don't draw. Rounded down to whole rows so
	// a panel dragged to an arbitrary height clips at a row boundary.
	const lanesMaxY = laneViewportHeight(height);
	// Total lane content height (layout coords), independent of the paint loop's
	// bottom-clip. The wheel clamp uses this to compute
	// `scrollYMax = max(0, contentHeight - lanesViewport)`.
	//
	// From `rowStackHeight`, the same walk the rows below are painted from.
	// Stepping the lanes here instead would reuse the pitch constants but apply
	// its own rule about which rows exist, skipping a category that holds
	// nothing. The rows are painted anyway, so a clamp that left them out would
	// report nothing to scroll to while the last of them sat clipped under the
	// ruler, half a row the reader could neither see whole nor scroll into
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
	// The masked lane stack paints into `lanesGfx` / `lanesLabels` so
	// the mask clips partial rows. Chrome below keeps writing to the
	// unmasked `graphics`.
	drawLaneStack({
		lanesGfx,
		lanesLabels,
		lanesGlyphGfx,
		bundle,
		orderedByLane,
		expanded,
		expandedCategories,
		rowHidden,
		rowLabelHidden,
		rowBodyHidden,
		categoryVisMode,
		rowDrag,
		selection,
		selectionSet,
		hoverGutterRow,
		focusedEventId,
		view,
		tToPx,
		colors,
		gutterX,
		rowBgX,
		rowBgWidth,
		plotX,
		plotWidth,
		width,
		laneHeight,
		scrollY,
		lanesMaxY,
	});
	// 2.5) Scroll-overflow chevrons in the gutter, passive visual
	// cue when rows exist above or below the visible lane viewport.
	// The Scrubber culls partially-offscreen rows (so they
	// don't bleed into the Overview above or the ruler below), which
	// means the user has no other signal that more rows exist. A small
	// ▴/▾ pair centered in the gutter, at the top/bottom of the lane
	// band, fills that gap. Painted before the ruler so the ruler chrome
	// sits on top if positions ever overlap.
	const scrollYMax = laneScrollMax(contentHeight, height);
	if (gutterX >= 12) {
		const cx = gutterX / 2;
		const chevW = 9;
		const chevH = 6;
		if (scrollY > 0.5) {
			// Top chevron, tip pushed ABOVE the Scrubber's top edge
			// into the Overview region of the shared Pixi canvas. The
			// Overview repaints every frame and sits earlier in scene
			// order so its bg covers the bleed visually; the visible
			// pixels of the chevron are the lower portion sitting in
			// the empty top strip of the lane viewport (gutter has no
			// lane content at y=0 yet because the first row's TOP edge
			// is at y=0 in layout space, but with scroll>0 the visible
			// top is empty gutter, the chevron has room).
			const tipY = -7;
			graphics
				.moveTo(cx - chevW / 2, tipY + chevH)
				.lineTo(cx, tipY)
				.lineTo(cx + chevW / 2, tipY + chevH)
				.closePath()
				.fill({ color: colors.textSubtle, alpha: 0.55 });
		}
		if (scrollY < scrollYMax - 0.5) {
			// Bottom chevron, tip pushed DOWN into the ruler band's
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

	labelPool.endFrame();
	lanesLabels.endFrame();
	return contentHeight;
}
