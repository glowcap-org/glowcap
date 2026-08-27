/** Playback and gesture marks drawn above the cached Scrubber scene. */

import type { Graphics } from "pixi.js";
import type { ClockSnapshot } from "../../engine/clock.ts";
import { clampRectToBounds, paintMarchingAntsBand } from "../../render/geometry.ts";
import { themedColors } from "../../render/palette.ts";
import { drawGhostPlayhead } from "./ghostPlayhead.ts";
import { RULER_HEIGHT, scrubberPlotBounds } from "./row-layout.ts";
import { type TimelineView, tToCanvasPx } from "./state.ts";
import type { Theme } from "../tokens.ts";

/** The frame-rate layer: playhead and gesture affordances over cached lanes. */
export function drawScrubberOverlay(
	graphics: Graphics,
	theme: Theme,
	view: TimelineView,
	clock: ClockSnapshot,
	width: number,
	height: number,
	scrubbing: boolean,
	hoverT: number | null,
	rubberBand: { x: number; y: number; width: number; height: number } | null,
	snapLineX: number | null,
): void {
	graphics.clear();
	if (width <= 0 || height <= 0 || view.windowEnd <= view.windowStart) return;

	const colors = themedColors(theme);
	const tToPx = (t: number) => tToCanvasPx(t, width, view);
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

	// In Live the clock is the capture head, so the playhead always has a
	// "where I am" to point at.
	if (clock.t >= view.windowStart && clock.t <= view.windowEnd) {
		const x = Math.round(tToPx(clock.t)) + 0.5;
		const headColor = scrubbing ? colors.textSubtle : colors.accent;
		graphics
			.moveTo(x, 0)
			.lineTo(x, height)
			.stroke({ color: headColor, width: 2 });
		graphics
			.circle(x, height - RULER_HEIGHT - 3, 3)
			.fill({ color: headColor });
	}

	if (rubberBand) {
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

	if (snapLineX !== null) {
		const x = Math.round(snapLineX) + 0.5;
		graphics
			.moveTo(x, 0)
			.lineTo(x, height)
			.stroke({ color: colors.accent, width: 1, alpha: 0.6 });
	}
}
