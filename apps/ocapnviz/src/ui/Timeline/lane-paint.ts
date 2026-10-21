/**
 * Lane-paint helpers. The pill rendering, glyph stamping, and
 * entity row-order resolution that the Scrubber's lane-stack paint
 * delegates to per lane. Pure paint code: no React, no state
 * mutation, no hit-test responsibility (that lives in `Scrubber.tsx`).
 * Callers thread `plotX` = the leftmost paintable content pixel
 * (`plotStartXOf(view)` in `state.ts`). The helpers clamp paint to
 * `[plotX, plotX + plotWidth]` so spans / glyphs / labels stay
 * inside the t-content band and never bleed into the gutter or
 * the left/right pads.
 */

import { FillGradient, type Graphics } from "pixi.js";
import type { TextPool } from "./textPool.ts";
import type { LaneGlyph, LaneSpan } from "./lane-bundle.ts";
import type { TimelineView } from "./state.ts";
import { LABEL_GAP_PX, LABEL_MIN_PX, layoutLaneLabels, monoAdvance } from "./label-layout.ts";
import { SPAN_MIN_PILL_PX, SPAN_PILL_INSET_Y, SPAN_RADIUS, type SpanRect, spanScreenRect } from "./span-geometry.ts";
import { FONT, SIZE } from "../tokens.ts";

/** Palette subset `drawLaneSpans` actually reads. Decoupled from
 * the full `ThemedColors` so the helper signature stays narrow. */
export type LanePaintPalette = {
	canvas: number;
};

/** How much canvas the edge fade has laid over the pill by the time
 *  it reaches the clipped end. Short of 1: a trace of the
 *  pill survives at the edge, so the span reads as continuing past
 *  the window rather than as stopping there. */
const FADE_END_ALPHA = 0.8;

/** Widest an edge fade gets, in px. A pill narrower than this fades
 *  across `w - SPAN_RADIUS` instead, so the fade never outgrows the
 *  pill carrying it. */
const FADE_MAX_WIDTH_PX = 16;

/** One gradient per (canvas color, direction). `textureSpace:
 *  "local"` measures the gradient across the bounds of the shape
 *  being filled, so a single instance stretches to fit every pill
 *  whatever its width or position, and a frame that fades fifty
 *  pills allocates nothing. Keyed on the canvas color because the
 *  fade is toward whatever the lane sits on, which the theme moves. */
const fadeGradients = new Map<string, FillGradient>();

function fadeGradient(canvas: number, towardRight: boolean): FillGradient {
	const key = `${canvas}:${towardRight ? "r" : "l"}`;
	const cached = fadeGradients.get(key);
	if (cached) return cached;
	const r = (canvas >> 16) & 0xff;
	const g = (canvas >> 8) & 0xff;
	const b = canvas & 0xff;
	const clear = `rgba(${r},${g},${b},0)`;
	const solid = `rgba(${r},${g},${b},${FADE_END_ALPHA})`;
	const gradient = new FillGradient({
		type: "linear",
		start: { x: 0, y: 0 },
		end: { x: 1, y: 0 },
		textureSpace: "local",
		colorStops: towardRight
			? [{ offset: 0, color: clear }, { offset: 1, color: solid }]
			: [{ offset: 0, color: solid }, { offset: 1, color: clear }],
	});
	fadeGradients.set(key, gradient);
	return gradient;
}

/** Resolve the per-entity render order for a category: listed ids
 * first (in the listed order), then unlisted entities sorted by
 * the bundle insertion order (which is first-event-t because
 * `buildLaneBundle` walks events in t-order). Stable + cheap.
 * Used inside `drawLaneStack` where the byEntity map is in
 * scope. The React-side equivalent is `applyRowOrder` which
 * takes a pre-flattened insertion-ordered list. */
export function orderEntities(
	byEntity: Map<string, { spans: LaneSpan[]; glyphs: LaneGlyph[] }>,
	order: readonly string[] | undefined,
): string[] {
	if (!order || order.length === 0) {
		return [...byEntity.keys()];
	}
	const result: string[] = [];
	const seen = new Set<string>();
	for (const id of order) {
		if (byEntity.has(id) && !seen.has(id)) {
			result.push(id);
			seen.add(id);
		}
	}
	for (const id of byEntity.keys()) {
		if (!seen.has(id)) result.push(id);
	}
	return result;
}

export function drawLaneSpans(
	graphics: Graphics,
	labelPool: TextPool,
	spans: readonly LaneSpan[],
	view: TimelineView,
	tToPx: (t: number) => number,
	centerY: number,
	laneHeight: number,
	plotX: number,
	plotWidth: number,
	colors: LanePaintPalette,
	/** Halo predicate. The caller bakes both single-selection
	 * (entity-keyed) and multi-selection (event-id-keyed) into
	 * one predicate so this function doesn't need to know about
	 * either selection regime. */
	isSelected: (spanId: string) => boolean,
	/** Anchor predicate, strict subset of `isSelected`. When
	 * true the halo paints with a thicker stroke so the user can
	 * tell WHICH selected span the Inspector is following under
	 * multi-select. Defaults to "never" so callers that don't
	 * track anchor get the single-tier halo. */
	isAnchor: (spanId: string) => boolean = () => false,
): void {
	const BUCKET_PX = SPAN_MIN_PILL_PX;
	const MIN_PILL_PX = SPAN_MIN_PILL_PX;
	// Pill insets `SPAN_PILL_INSET_Y` top + bottom from the lane row
	// so the zebra backing is visible around it.
	const PILL_HEIGHT = Math.max(
		SPAN_MIN_PILL_PX,
		laneHeight - SPAN_PILL_INSET_Y * 2,
	);
	const RADIUS = SPAN_RADIUS;

	type Stamp = { color: string; x: number };
	// Per-bucket: count + color + whether any span in the bucket is
	// selected, and whether any is the anchor. `firstId` is kept so
	// single-item stamps can paint a halo against the same predicate
	// the long-pill branch uses.
	const buckets = new Map<
		number,
		{
			count: number;
			color: string;
			anySelected: boolean;
			anyAnchor: boolean;
		}
	>();
	const stamps: Stamp[] = [];
	const longPills: { span: LaneSpan; rect: SpanRect }[] = [];

	for (const span of spans) {
		if (span.endT < view.windowStart || span.startT > view.windowEnd) {
			continue;
		}
		const x0 = tToPx(span.startT);
		const x1 = tToPx(span.endT);
		const width = x1 - x0;
		if (width < MIN_PILL_PX) {
			// Bucket by LEFT anchor (x0), not midpoint. Lookup downstream
			// re-buckets by `stamp.x` (also x0), keying both passes off the
			// same value is what keeps a sub-pill span paintable through the
			// entire (0, MIN_PILL_PX) width range. Bucketing here by xMid
			// while looking up by x0 dropped stamps when xMid and x0 landed
			// on opposite sides of a `BUCKET_PX` boundary, which is exactly
			// the size of the transition zone, sessions/messages flashed
			// invisible as a parent's effective range squeezed them through
			// it during a drag-resize.
			const bucket = Math.floor(x0 / BUCKET_PX);
			const existing = buckets.get(bucket);
			const sel = isSelected(span.id);
			const anchor = isAnchor(span.id);
			if (existing) {
				existing.count += 1;
				if (sel) existing.anySelected = true;
				if (anchor) existing.anyAnchor = true;
			} else {
				buckets.set(bucket, {
					count: 1,
					color: span.color,
					anySelected: sel,
					anyAnchor: anchor,
				});
				// Anchor the stamp's LEFT edge at x0 (the span's start time)
				// rather than centering on xMid. With midpoint-anchoring the
				// visible left edge slides up to MIN_PILL_PX/2 px leftward as
				// the span shrinks toward zero. The user-visible "shifts left
				// near zero" bug. Left-anchoring keeps the start pinned and
				// grows the stamp out to its MIN_PILL_PX footprint to the
				// right of the start.
				stamps.push({ color: span.color, x: x0 });
			}
		} else {
			const rect = spanScreenRect({
				startT: span.startT,
				endT: span.endT,
				tToPx,
				plotX,
				plotWidth,
			});
			if (rect) longPills.push({ span, rect });
		}
	}

	for (const { span, rect } of longPills) {
		const { left, right } = rect;
		const w = right - left;
		const y = centerY - PILL_HEIGHT / 2;

		graphics
			.roundRect(
				Math.round(left),
				Math.round(y),
				Math.round(w),
				PILL_HEIGHT,
				RADIUS,
			)
			.fill({ color: span.color });

		// State segments paint edge-to-edge across the pill: the first
		// and last segments use `roundRect` to fill the rounded caps in
		// their own color (so the cap doesn't show the categorical
		// captp color and create a visible seam against the state
		// segment). Middle segments paint as plain rects. To suppress
		// the rounded-corner notch at the boundary between a roundRect
		// segment and its rect neighbor, the first segment extends RADIUS
		// past its right edge (and the last extends RADIUS before its
		// left edge). The abutting rect overpaints the notch since it
		// has full corner coverage.
		if (span.segments && span.segments.length > 0) {
			const segs = span.segments;
			const lastIdx = segs.length - 1;
			for (let i = 0; i < segs.length; i++) {
				const seg = segs[i]!;
				const isFirst = i === 0;
				const isLast = i === lastIdx;
				const segLeftRaw = isFirst ? left : tToPx(seg.t0);
				const segRightRaw = isLast ? right : tToPx(seg.t1);
				// Extend roundRect segments by RADIUS into the abutting rect
				// so the notch sits under the neighbor's full-coverage paint.
				const drawLeft = isFirst || isLast ? segLeftRaw - (isFirst && !isLast ? 0 : RADIUS) : segLeftRaw;
				const drawRight = isFirst || isLast ? segRightRaw + (isLast && !isFirst ? 0 : RADIUS) : segRightRaw;
				const clipLeft = Math.max(left, drawLeft);
				const clipRight = Math.min(right, drawRight);
				if (clipRight <= clipLeft) continue;
				const w = clipRight - clipLeft;
				if (isFirst || isLast) {
					graphics
						.roundRect(
							Math.round(clipLeft),
							Math.round(y),
							Math.round(w),
							PILL_HEIGHT,
							RADIUS,
						)
						.fill({ color: seg.color });
				} else {
					graphics
						.rect(
							Math.round(clipLeft),
							Math.round(y),
							Math.round(w),
							PILL_HEIGHT,
						)
						.fill({ color: seg.color });
				}
			}
		}

		// Selection halo: a 1.5px white outline overlaid on the pill.
		// Pulled out 1px so the stroke isn't clipped against the
		// zebra backing, and the fill peeks through to make the
		// outline read as a halo, not a border swap. The `-1`
		// extension AND the stroke's half-width land safely inside
		// the left pad because spans clamp to `plotX` above and
		// `plotX` itself sits one full pad-width inside the gutter
		// divider.
		if (isSelected(span.id)) {
			const anchorHere = isAnchor(span.id);
			graphics
				.roundRect(
					Math.round(left) - 1,
					Math.round(y) - 1,
					Math.round(w) + 2,
					PILL_HEIGHT + 2,
					RADIUS + 1,
				)
				.stroke({
					color: 0xffffff,
					width: anchorHere ? 2.5 : 1.5,
					alpha: 0.95,
				});
		}

		// Edge fade, a gradient toward the canvas color at either end.
		// Visually a "trailing off" / "comes from off-screen" cue. It is
		// one gradient-filled `roundRect` per faded end, sharing the
		// pill's own `RADIUS`, so the cap the fade lands on stays as
		// round as the cap on a pill that never fades. Both of the
		// gradient's ends are rounded, but the inner one sits where the
		// gradient is fully transparent, so only the outer cap shows.
		// Fires whenever the span extends past the visible
		// window in that direction, regardless of WHY:
		//   right edge: x1 > plot's right edge  (open spans always
		//     trigger because endT=Infinity; finite spans whose end
		//     is past windowEnd also trigger, not only `span.open`).
		//   left edge:  x0 < plotX              (any span that
		//     began before windowStart, covers normal scroll-out
		//     and a future "entity already present at
		//     recording start" data shape gets the visual for free).
		// Both conditions key on the true window edge: `x1 > plotX +
		// plotWidth` for "extends past the right" and `x0 < plotX` for
		// "starts before the left". The stripe formula at start is
		// the mirror of end: most-canvas at the edge, fading to span
		// color inward.
		// Both fades measure off the pill's own rounded coordinates, so
		// a fade's outer edge lands on the pill's edge exactly and the
		// two caps coincide instead of missing each other by a pixel.
		const pillX = Math.round(left);
		const pillW = Math.round(w);
		const fadeWidth = Math.round(
			Math.min(Math.min(FADE_MAX_WIDTH_PX, w - RADIUS), pillW),
		);
		if (fadeWidth > 0 && rect.rightClamped) {
			graphics
				.roundRect(
					pillX + pillW - fadeWidth,
					Math.round(y),
					fadeWidth,
					PILL_HEIGHT,
					RADIUS,
				)
				.fill(fadeGradient(colors.canvas, true));
		}
		if (fadeWidth > 0 && rect.leftClamped) {
			// Mirror of the right-edge fade: most canvas at the pill's
			// clipped left edge, clearing inward, so a span reads the same
			// way whichever side it runs off. A pill clipped at both ends
			// gets both, and the two overlap on a pill short enough for
			// their widths to meet, the way the stripes they replaced did.
			graphics
				.roundRect(
					pillX,
					Math.round(y),
					fadeWidth,
					PILL_HEIGHT,
					RADIUS,
				)
				.fill(fadeGradient(colors.canvas, false));
		}
	}

	// Sticky cross-pill label layout (later wins; earlier truncates). status-allow: event or source ordering
	// See `layoutLaneLabels` for the algorithm.
	const placedLabels = layoutLaneLabels(
		longPills.map(({ span, rect }) => ({
			id: span.id,
			startT: span.startT,
			label: span.label,
			pillLeft: rect.left,
			pillRight: rect.right,
		})),
		monoAdvance(SIZE.xs),
		LABEL_GAP_PX,
		LABEL_MIN_PX,
	);
	for (const p of placedLabels) {
		labelPool.acquire(
			p.label,
			{
				fontFamily: FONT.mono,
				fontSize: SIZE.xs,
				// White-on-saturated-pill reads on every theme.
				fill: 0xffffff,
				align: "left",
				baseline: "middle",
			},
			p.x,
			centerY + 0.5,
		);
	}

	for (const stamp of stamps) {
		// `stamp.x` is the span's true x0 (left edge), left-anchored to
		// keep the visible start fixed as a span shrinks toward zero.
		// Bucket key is derived from x0 here AND at insertion, keying
		// both passes off the same value is what makes lookup stable for
		// every sub-pill width, not just the fully-collapsed case.
		const leftAnchor = stamp.x;
		const bucket = Math.floor(leftAnchor / BUCKET_PX);
		const entry = buckets.get(bucket);
		if (!entry) continue;
		if (leftAnchor > plotX + plotWidth) continue;
		if (entry.count === 1) {
			const w = MIN_PILL_PX;
			// Clamp the stamp's LEFT edge to `plotX` so the stamp can't
			// bleed into the left pad / gutter. A zero-span item at
			// `windowStart` paints exactly at `plotX`; the clamp is a
			// no-op for those but kicks in when an earlier-than-window status-allow: event or source ordering
			// stamp scrolls into view. Drop the stamp entirely only if
			// even the clamped position would land off the right edge.
			// The roundRect call below takes the CENTER via `x - w/2`,
			// so we re-center after clamping the left.
			const leftPx = Math.max(plotX, leftAnchor);
			if (leftPx > plotX + plotWidth) continue;
			const x = leftPx + w / 2;
			const y = centerY - PILL_HEIGHT / 2;
			graphics
				.roundRect(
					Math.round(x - w / 2),
					Math.round(y),
					w,
					PILL_HEIGHT,
					RADIUS,
				)
				.fill({ color: entry.color });
			if (entry.anySelected) {
				graphics
					.roundRect(
						Math.round(x - w / 2) - 1,
						Math.round(y) - 1,
						w + 2,
						PILL_HEIGHT + 2,
						RADIUS + 1,
					)
					.stroke({
						color: 0xffffff,
						width: entry.anyAnchor ? 2.5 : 1.5,
						alpha: 0.95,
					});
			}
		} else {
			const badgeW = Math.max(
				14,
				entry.count >= 100 ? 20 : entry.count >= 10 ? 16 : 14,
			);
			const leftPx = Math.max(plotX, leftAnchor);
			if (leftPx > plotX + plotWidth) continue;
			const x = leftPx + badgeW / 2;
			const y = centerY - PILL_HEIGHT / 2;
			graphics
				.roundRect(
					Math.round(x - badgeW / 2),
					Math.round(y),
					badgeW,
					PILL_HEIGHT,
					RADIUS,
				)
				.fill({ color: entry.color });
			if (entry.anySelected) {
				graphics
					.roundRect(
						Math.round(x - badgeW / 2) - 1,
						Math.round(y) - 1,
						badgeW + 2,
						PILL_HEIGHT + 2,
						RADIUS + 1,
					)
					.stroke({
						color: 0xffffff,
						width: entry.anyAnchor ? 2.5 : 1.5,
						alpha: 0.95,
					});
			}
			// Center-align via "left" anchor offset, counts are 1–3
			// chars so the visual centering error is negligible.
			labelPool.acquire(
				String(entry.count),
				{
					fontFamily: FONT.mono,
					fontSize: 9,
					fill: 0xffffff,
					align: "left",
					baseline: "middle",
				},
				x - 3,
				centerY + 0.5,
			);
		}
		buckets.delete(bucket);
	}
}

export function drawLaneGlyphs(
	graphics: Graphics,
	glyphs: readonly LaneGlyph[],
	view: TimelineView,
	tToPx: (t: number) => number,
	centerY: number,
	laneHeight: number,
	plotX: number,
	plotWidth: number,
	/** Sub-selection focus. When a glyph's `eventId` matches, paint
	 *  a stroke ring around it so the user can see the keyframe the
	 *  Inspector / authoring focus is parked on. Independent of the
	 *  entity-selection halo (a focused glyph sits inside an entity
	 *  span that may or may not be in the entity selection). */
	focusedEventId: string | null,
	/** Theme-resolved stroke color for the focus ring. */
	focusColor: number,
): void {
	const BUCKET_PX = 4;
	// Bucket index → kept glyph (last write wins; cheap dedup).
	const kept = new Map<string, LaneGlyph>();
	// Glyphs cull against the visible content band. A diamond's
	// half-radius can poke past `plotX` into the left pad without
	// bleeding to the gutter (the pad absorbs the arm); same story
	// on the right edge.
	for (const g of glyphs) {
		if (g.t < view.windowStart || g.t > view.windowEnd) continue;
		const x = tToPx(g.t);
		if (x < plotX || x > plotX + plotWidth) continue;
		const bucket = `${g.shape}:${Math.floor(x / BUCKET_PX)}`;
		kept.set(bucket, g);
	}
	for (const g of kept.values()) {
		const x = Math.round(tToPx(g.t));
		const focused = focusedEventId !== null && g.eventId === focusedEventId;
		if (g.shape === "diamond") {
			const r = 4;
			const poly = [
				x,
				centerY - r,
				x + r,
				centerY,
				x,
				centerY + r,
				x - r,
				centerY,
			];
			if (focused) {
				// Larger outer diamond as a stroke ring, painted first so
				// the fill sits on top. 2 px outset reads as a halo at
				// 60 Hz without the geometry fighting the 4-px glyph.
				const fr = r + 2;
				graphics
					.poly([
						x,
						centerY - fr,
						x + fr,
						centerY,
						x,
						centerY + fr,
						x - fr,
						centerY,
					])
					.fill({ color: focusColor });
			}
			graphics.poly(poly).fill({ color: g.color });
		} else {
			if (focused) {
				graphics
					.rect(
						x - 1,
						centerY - laneHeight / 2 + 1,
						3,
						Math.max(4, laneHeight - 2),
					)
					.fill({ color: focusColor });
			}
			graphics
				.rect(
					x,
					centerY - laneHeight / 2 + 2,
					1,
					Math.max(2, laneHeight - 4),
				)
				.fill({ color: g.color });
		}
	}
}
