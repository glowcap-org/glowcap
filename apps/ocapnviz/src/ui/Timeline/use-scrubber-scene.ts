/**
 * The Scrubber's Pixi scene: layers, region marker, and the paint ticker.
 *
 * `Scrubber.tsx` owns the React host, wheel zoom, and double-click fit.
 * Pointer press/move/release live in `use-scrubber-pointers.ts`. This hook
 * is the picture those two write into — it mounts the scene on the unified
 * canvas, bails a still frame, and asks `drawScrubberScene` for the rest.
 */

import { type MutableRefObject, type RefObject, useEffect } from "react";
import { Container, Graphics, Rectangle } from "pixi.js";
import type { ClockSnapshot } from "../../engine/clock.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { observationsOf } from "../../engine/temporal/recording-access.ts";
import { type EntityRefKey } from "../../interactions/types.ts";
import { type StageSelection } from "../../render/types.ts";
import { useUnifiedCanvas } from "../../render/UnifiedCanvas.tsx";
import { currentTheme, type Theme } from "../tokens.ts";
import { TextPool } from "./textPool.ts";
import { type RowDragSnapshot, RULER_HEIGHT, RULER_TOP_PAD } from "./row-layout.ts";
import { gutterWidthOf, type LaneKind, type TimelineView } from "./state.ts";
import { drawScrubberScene } from "./scrubber-paint.ts";
import { type DragMode } from "./scrubber-drag.ts";

/** What the ticker reads each frame. Written by the host on every render
 *  so the long-lived paint callback never closes over a stale prop. */
export type ScrubberSceneLive = {
	view: TimelineView;
	clock: ClockSnapshot;
	doc: TimelineDocument;
	events: readonly TimelineEvent[];
	entities: TimelineDocument["entities"];
	expandedLanes: ReadonlySet<LaneKind>;
	laneHeight: number;
	scrubbing: boolean;
	selection: StageSelection;
	expandedCategories: ReadonlySet<Exclude<LaneKind, "ruler">>;
	rowOrder: TimelineDocument["rowOrder"];
	rowHidden: TimelineDocument["rowHidden"];
	rowLabelHidden: TimelineDocument["rowLabelHidden"];
	rowBodyHidden: TimelineDocument["rowBodyHidden"];
	categoryVisMode: TimelineDocument["categoryVisMode"];
	selectionSet: ReadonlySet<EntityRefKey>;
	rubberBandRef: MutableRefObject<
		{ x: number; y: number; width: number; height: number } | null
	>;
	snapLineRef: MutableRefObject<number | null>;
	focusedEventId: string | null;
};

export function useScrubberScene(args: {
	hostRef: RefObject<HTMLDivElement | null>;
	propsRef: { readonly current: ScrubberSceneLive };
	dragRef: MutableRefObject<DragMode>;
	hoverGutterRowRef: MutableRefObject<string | null>;
	hoverTRef: { current: number | null };
	scrollYRef: MutableRefObject<number>;
	scrollYMaxRef: MutableRefObject<number>;
	regionSizeRef: MutableRefObject<{ width: number; height: number }>;
}): void {
	const {
		hostRef,
		propsRef,
		dragRef,
		hoverGutterRowRef,
		hoverTRef,
		scrollYRef,
		scrollYMaxRef,
		regionSizeRef,
	} = args;
	const ctx = useUnifiedCanvas();

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
			regionSizeRef.current = {
				width: regionWidth,
				height: regionHeight,
			};
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
			const liveEvents = observationsOf(
				p.doc,
			) as readonly TimelineEvent[];
			// An in-flight event drag (diamond / span edge / body) must
			// repaint even when the bail's prop snapshot has not moved.
			const eventDragActive = drag?.kind === "event" && drag.moved &&
				!drag.selectOnly;
			const curGutter = gutterWidthOf(p.view);
			const curHoverRow = hoverGutterRowRef.current;
			const curScrollY = scrollYRef.current;
			const curHoverT = hoverTRef.current;
			if (
				!bandActive && !snapActive && !rowDragActive &&
				!eventDragActive &&
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
			if (!scrubberScene.destroyed) {
				scrubberScene.destroy({ children: true });
			}
		};
	}, [
		ctx,
		dragRef,
		hostRef,
		hoverGutterRowRef,
		hoverTRef,
		propsRef,
		regionSizeRef,
		scrollYMaxRef,
		scrollYRef,
	]);
}
