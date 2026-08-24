/**
 * Scrubber paint pipeline. Per-frame scene rebuild: mask, pads, the
 * masked lane stack (`lane-stack-paint.ts`), then chrome overlays.
 * The Scrubber component orchestrates pointer/keyboard state and
 * calls in here on every tick.
 *
 * Paint order (back → front):
 *   1. Lane gutter separator
 *   2. Lane stack (headers, zebra, spans, glyphs, row-drag bar)
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
import type { EntityRefKey } from "../../interactions/types.ts";
import { clampRectToBounds, paintMarchingAntsBand } from "../../render/geometry.ts";
import { themedColors } from "../../render/palette.ts";
import type { StageSelection } from "../../render/types.ts";
import { drawGhostPlayhead } from "./ghostPlayhead.ts";
import { buildLaneBundle, laneBundleColorsFromTheme } from "./lane-bundle.ts";
import { orderEntities } from "./lane-paint.ts";
import { drawLaneStack } from "./lane-stack-paint.ts";
import {
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
	const lanesMaxYClip = wholeRowsHeight(
		height - RULER_HEIGHT - RULER_TOP_PAD,
	);
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
