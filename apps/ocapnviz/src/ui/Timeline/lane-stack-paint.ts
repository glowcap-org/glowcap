/**
 * Masked lane-stack paint. The Scrubber's category headers, entity
 * rows, zebra, and row-drag insertion bar. `scrubber-paint.ts` owns
 * the scene: mask, pads, this stack, then chrome overlays.
 *
 * Paints into the masked `lanesGfx` / `lanesLabels` / `lanesGlyphGfx`
 * so partial rows clip at the viewport. The layout cursor stays in
 * unscrolled space. Paint coords subtract `scrollY`, which keeps
 * row-drag insertion-index math identical to the scrollY=0 case.
 *
 * Hit-testing walks the same stack through `iterateRows` in
 * `row-layout.ts`. This module is paint only.
 */

import type { Graphics } from "pixi.js";
import type { TimelineDocument } from "../../engine/timeline.ts";
import { entityKey, type EntityRefKey } from "../../interactions/types.ts";
import type { ThemedColors } from "../../render/palette.ts";
import type { StageSelection } from "../../render/types.ts";
import { drawCategoryHeader, drawRowGutter, type EyeGlyphMode } from "./gutter-paint.ts";
import { type LaneBundle, laneRowLabel } from "./lane-bundle.ts";
import { drawLaneGlyphs, drawLaneSpans } from "./lane-paint.ts";
import { CATEGORY_HEADER_HEIGHT, LANE_GAP, LANE_ORDER, type RowDragSnapshot } from "./row-layout.ts";
import type { LaneKind, TimelineView } from "./state.ts";
import type { TextPool } from "./textPool.ts";

type LaneStackPaintArgs = {
	lanesGfx: Graphics;
	lanesLabels: TextPool;
	lanesGlyphGfx: Graphics;
	bundle: LaneBundle;
	orderedByLane: Record<Exclude<LaneKind, "ruler">, readonly string[]>;
	expanded: ReadonlySet<LaneKind>;
	expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>;
	rowHidden: TimelineDocument["rowHidden"];
	rowLabelHidden: TimelineDocument["rowLabelHidden"];
	rowBodyHidden: TimelineDocument["rowBodyHidden"];
	categoryVisMode: TimelineDocument["categoryVisMode"];
	rowDrag: RowDragSnapshot | null;
	selection: StageSelection;
	selectionSet: ReadonlySet<EntityRefKey>;
	hoverGutterRow: string | null;
	focusedEventId: string | null;
	view: TimelineView;
	tToPx: (t: number) => number;
	colors: ThemedColors;
	gutterX: number;
	rowBgX: number;
	rowBgWidth: number;
	plotX: number;
	plotWidth: number;
	width: number;
	laneHeight: number;
	scrollY: number;
	lanesMaxY: number;
};

export function drawLaneStack({
	lanesGfx: graphics,
	lanesLabels: labelPool,
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
}: LaneStackPaintArgs): void {
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
		// `selection?.kind === laneKind && selection.id === spanId`,
		// App passes the store's anchor through as `selection`. The
		// halo paints thicker for the anchor so the user reads
		// which selected span the Inspector tracks under multi-
		// select.
		const isAnchor = (spanId: string): boolean => spanId === highlightId;
		const isExpandedCategory = expandedCategories.has(lane);

		// Bail when the lane's TOP edge falls below the viewport,
		// anything below that won't even partially render through the
		// mask. Subsequent lanes start even lower, so break entirely.
		// (The mask handles the bottom-clip visually, so we
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

			// Hover bg on the gutter portion of the row, same
			// "button-like" affordance you'd get from a list-item hover
			// in the rest of the app. Drawn behind the chevron/label so
			// it never obscures the glyph.
			if (hoverGutterRow === `header:${lane}`) {
				graphics
					.rect(0, laneY, gutterX, laneHeight)
					.fill({ color: colors.text, alpha: 0.05 });
			}

			// Lane label with chevron indicating it can be expanded.
			// Eyeball glyph reads the STORED category flag directly,
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
		// mask. (The mask keeps a negative-y header from bleeding into
		// the Overview pane above.)
		const headerOffTop = headerLaneY + CATEGORY_HEADER_HEIGHT < 0;
		// Persistent gutter tint on the header, distinctly
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
			// Header band tint over the row body. A tick stronger
			// than the row zebra (which tops out at 0.06) so the
			// header reads as a continuous label band, not just
			// another row. Extends through both pads via `rowBgX/W`.
			graphics
				.rect(rowBgX, headerLaneY, rowBgWidth, CATEGORY_HEADER_HEIGHT)
				.fill({ color: colors.text, alpha: 0.08 });
		}
		// 1-px divider under the header, spanning the FULL panel
		// (gutter + plot). Makes the parent / children boundary
		// explicit, the gutter tint + plot tint above set the
		// grouping intent; this rule gives a visible "everything
		// below is INSIDE this category" cut, the same way Flash /
		// After Effects show layer-group borders.
		//
		// Lives in the LANE_GAP region BELOW the header (not at the
		// header's last pixel) so it can't touch the bottom of the
		// category-eyeball glyph, the `label`-mode eye renders a
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
		// finish, drawing it inline would risk being overwritten by
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
			// Resolve the per-entity visibility mode (4-state, see
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
			// viewport, partial top rows render through the mask.
			const rowOffTop = rowY + rowH < 0;

			if (laneRowDrag && entityIndex === laneRowDrag.finalIndex) {
				dropY = rowY;
			}

			if (rowOffTop) {
				// Scrolled above the viewport, advance the layout cursor
				// and skip all painting + zebra accounting consistent with
				// the visible region.
				y += rowH + LANE_GAP;
				entityIndex += 1;
				zebraIndex += 1;
				continue;
			}

			// Zebra row tint, dimmed when the entity is hidden ON STAGE
			// (the eyeball semantics, see `RowHidden` doctrine in
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
			// / body / both), see `drawEyeGlyph`. The label dims when ANY
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

		// Drop-target insertion bar, drawn AFTER the row loop so it
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

/** Map a lane bucket to the selection `kind` whose `id` lives in
 * its spans (`spans` in `bundle.peers` carry peer ids, etc). */
function laneKindForSelection(
	lane: Exclude<LaneKind, "ruler">,
): "peer" | "session" | "message" {
	return lane === "peers" ? "peer" : lane === "sessions" ? "session" : "message";
}
