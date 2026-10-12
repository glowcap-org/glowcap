/**
 * Overview, the timeline's context strip. A thin band showing the
 * full `[0, doc.duration]` with a draggable visible-window rect
 * that mirrors the Scrubber's `view.windowStart/End`.
 *
 * Pixels paint through `overview-paint.ts` into the unified canvas
 * (`overviewScene`). The DOM marker is transparent and carries React
 * event handlers. The inverse of the Stage's pattern, Timeline has
 * single-surface pointer state, so React handlers on a transparent
 * overlay are simpler than wiring federated events.
 *
 * Interactions:
 *   - Drag rect body  : pan.
 *   - Drag rect edge  : zoom.
 *   - Click outside   : recenter.
 *   - Wheel           : pan + zoom via `applyWheel`.
 */

import { useCallback, useEffect, useRef } from "react";
import { Container, Graphics, Rectangle } from "pixi.js";
import type { ClockSnapshot } from "../../engine/clock.ts";
import { useGestureSurface } from "../../interactions/use-gesture-surface.ts";
import { useUnifiedCanvas } from "../../render/UnifiedCanvas.tsx";

const OVERVIEW_SURFACE_TAG = "timeline-overview";
import { currentTheme, type Theme } from "../tokens.ts";
import { TextPool } from "./textPool.ts";
import { applyWheel, clampView, gutterWidthOf, MIN_WINDOW_MS, plotWidthOf, type TimelineView } from "./state.ts";
import { type EyeGlyphMode, eyeGlyphStatus } from "./gutter-paint.ts";
import { drawOverviewScene } from "./overview-paint.ts";
import { overviewHitAt, timelineCursor, type TimelineGesture } from "./timeline-cursor.ts";
import { resolveTimelineGesture } from "./timeline-gesture.ts";
import type { SurfaceGestureCtx } from "../../interactions/types.ts";

export const OVERVIEW_HEIGHT = 26;

/** Default host `title` when the pointer is not on the all-rows eyeball. */
const OVERVIEW_HOST_TITLE =
	"Overview — drag rectangle to pan · drag edges to zoom · click outside to recenter · wheel = zoom · Shift+wheel = pan";

export type OverviewProps = {
	view: TimelineView;
	clock: ClockSnapshot;
	/** Width hint for the marker div. Actual paint width comes
	 * from the region rect each frame. */
	width: number;
	/** Where the ghost playhead's time lives, shared with the
	 * Scrubber via `TimelinePanel`. A mutable box rather than a
	 * value: both surfaces write it on every pointermove, and the
	 * only reader is each surface's own Pixi ticker, which reads it
	 * once a frame. As state it re-rendered the whole timeline at
	 * pointer-event rate to move one number into two mutable slots,
	 * and hardest while paused, where the engine only notifies on
	 * change and hover was then the only thing re-rendering at all.
	 * `Scrubber`'s `rubberBandRef` and `snapLineRef` are the same
	 * idiom. */
	hoverTRef: React.RefObject<number | null>;
	/** Literal view OR updater function (wheel / drag use the
	 * updater so multi-events-per-frame stack on fresh state). */
	onSetView: (
		next: TimelineView | ((current: TimelineView) => TimelineView),
	) => void;
	/** All-rows visibility cycle, lives on the overview's gutter
	 *  eyeball (there is no separate `all` button in the control row).
	 *  Same 4-state vocabulary as the per-category and per-entity
	 *  eyeballs. With the independent-flag visibility model each
	 *  level (all / category / entity) stores its own state, no
	 *  surveying, no `mixed`. Undefined disables the eyeball
	 *  affordance entirely (the control isn't wired). */
	allVisMode?: EyeGlyphMode | undefined;
	onCycleAllVisibility?: (() => void) | undefined;
	/** View-width ceiling for the wheel handler. Defaults to
	 *  `clock.duration` in Play and Build, which cannot zoom past
	 *  1×. Live mode overrides with a 1-week cap so
	 *  wheeling over the Overview doesn't undo the Scrubber's
	 *  zoom-out. Must agree with the Scrubber's `viewMaxWidth`
	 *  for the two surfaces to share one view consistently. */
	viewMaxWidth?: number | undefined;
	/** Right-edge cap for the wheel handler's pan. Defaults to
	 *  `clock.duration` (Play / Build). Live passes `Infinity`
	 *  so pan-right via the Overview doesn't snap the view back
	 *  to the captured edge. Must agree with the Scrubber's
	 *  `viewPanMaxT`. */
	viewPanMaxT?: number | undefined;
	/** The App's gesture context, Space, the active tool, and the keys held
	 *  right now. The cursor is drawn from it, the same value the Stage and the
	 *  Scrubber are handed. */
	gestureCtx: SurfaceGestureCtx;
};

export function Overview(
	{
		view,
		clock,
		width,
		hoverTRef,
		onSetView,
		allVisMode,
		onCycleAllVisibility,
		viewMaxWidth,
		viewPanMaxT,
		gestureCtx,
	}: OverviewProps,
) {
	const hostRef = useRef<HTMLDivElement | null>(null);
	// Boxed so the pointer handlers read the current context without
	// re-creating themselves on every render App happens to run.
	const gestureCtxRef = useRef(gestureCtx);
	gestureCtxRef.current = gestureCtx;
	const dragRef = useRef<OverviewDrag>(null);
	/** The gesture in flight, named in the resolver's vocabulary at the press
	 *  that starts it, so the cursor says what is happening rather than what
	 *  the pointer is passing over. */
	const inFlightRef = useRef<TimelineGesture | null>(null);
	const ctx = useUnifiedCanvas();

	// This surface's lease on the gesture lock, cross-surface
	// mutual exclusion treats Overview as its own surface. The hook
	// releases the lease when the strip leaves the tree, which
	// `TimelinePanel` does mid-drag whenever recording starts or the
	// slot measures zero wide, and it watches the window for the
	// gesture ends this element cannot see. `endDrag` below is the
	// surface's own teardown; the arrow reads it late, after this
	// render has finished.
	const surface = useGestureSurface(OVERVIEW_SURFACE_TAG, () => endDrag());

	// Shared view bounds, same source of truth as `Scrubber`
	// (`TimelinePanel` lifts both and passes to both surfaces).
	// Without aligning these, wheel / drag over the Overview
	// would default to `clock.duration` for both and snap the
	// view back inside `[0, duration]` on every gesture, undoing
	// any zoom-out / pan-into-future the user did via the
	// Scrubber. See `MAX_LIVE_WINDOW_MS` in `Scrubber.tsx`.
	const maxWidth = viewMaxWidth ?? clock.duration;
	const panMaxT = viewPanMaxT ?? clock.duration;

	// `propsRef` lets the long-lived ticker read latest prop values
	// without re-creating itself per render.
	const propsRef = useRef({
		view,
		clock,
		allVisMode,
	});
	propsRef.current = {
		view,
		clock,
		allVisMode,
	};

	useEffect(() => {
		const host = hostRef.current;
		if (!host || !ctx) return;
		const { app, regions } = ctx;

		const overviewScene = new Container();
		app.stage.addChild(overviewScene);

		const graphics = new Graphics();
		overviewScene.addChild(graphics);

		const labelPool = new TextPool(overviewScene);

		let regionWidth = 0;
		let regionHeight = OVERVIEW_HEIGHT;

		const cleanups: Array<() => void> = [];

		const handleRegionRect = (
			rect: { x: number; y: number; width: number; height: number },
		) => {
			overviewScene.position.set(rect.x, rect.y);
			regionWidth = rect.width;
			regionHeight = rect.height;
		};
		cleanups.push(regions.register("timeline-overview", host));
		cleanups.push(regions.subscribe("timeline-overview", handleRegionRect));

		// Per-frame bail, skip the full Overview rebuild when no
		// input changed. See `Scrubber.tsx` for the same pattern.
		let lastTheme: Theme | null = null;
		let lastWindowStart = NaN;
		let lastWindowEnd = NaN;
		let lastClockT = NaN;
		let lastDuration = NaN;
		let lastHoverT: number | null = NaN;
		let lastWidth = NaN;
		let lastHeight = NaN;
		let lastGutterWidth = NaN;
		let lastAllVisMode: OverviewProps["allVisMode"] | null = null;
		// Hoisted hitArea, see Scrubber for the rationale.
		const hitArea = new Rectangle(0, 0, 0, 0);
		graphics.hitArea = hitArea;

		const repaint = () => {
			const p = propsRef.current;
			if (regionWidth <= 0 || regionHeight <= 0) return;
			const theme = currentTheme();
			const curGutter = gutterWidthOf(p.view);
			const curHoverT = hoverTRef.current;
			if (
				theme === lastTheme &&
				p.view.windowStart === lastWindowStart &&
				p.view.windowEnd === lastWindowEnd &&
				p.clock.t === lastClockT &&
				p.clock.duration === lastDuration &&
				curHoverT === lastHoverT &&
				regionWidth === lastWidth &&
				regionHeight === lastHeight &&
				curGutter === lastGutterWidth &&
				p.allVisMode === lastAllVisMode
			) {
				return;
			}
			lastAllVisMode = p.allVisMode;
			lastTheme = theme;
			lastWindowStart = p.view.windowStart;
			lastWindowEnd = p.view.windowEnd;
			lastClockT = p.clock.t;
			lastDuration = p.clock.duration;
			lastHoverT = curHoverT;
			lastWidth = regionWidth;
			lastHeight = regionHeight;
			lastGutterWidth = curGutter;
			hitArea.width = regionWidth;
			hitArea.height = regionHeight;
			drawOverviewScene(
				graphics,
				labelPool,
				theme,
				p.view,
				p.clock,
				curHoverT,
				regionWidth,
				regionHeight,
				p.allVisMode,
			);
		};

		const tickCb = () => repaint();
		app.ticker.add(tickCb);
		cleanups.push(() => app.ticker?.remove(tickCb));

		return () => {
			for (const fn of cleanups) fn();
			app.stage?.removeChild(overviewScene);
			labelPool.destroy();
			if (!overviewScene.destroyed) {
				overviewScene.destroy({ children: true });
			}
		};
	}, [ctx, hoverTRef]);

	const handlePointerDown = useCallback(
		(e: React.PointerEvent<HTMLDivElement>) => {
			if (e.button !== 0) return;
			if (!surface.claim(e.currentTarget, e.pointerId)) return;
			e.preventDefault();
			e.currentTarget.setPointerCapture(e.pointerId);
			// Ghost is a "where would my click land?" hint, moot
			// once a click is in flight.
			hoverTRef.current = null;
			const rect = e.currentTarget.getBoundingClientRect();
			const px = e.clientX - rect.left;
			const plotW = plotWidthOf(rect.width, view);
			if (plotW <= 0) return;
			const hit = overviewHitAt({
				px,
				width: rect.width,
				view,
				duration: clock.duration,
				hasAllRowsEyeball: onCycleAllVisibility !== undefined,
			});
			const resolved = resolveTimelineGesture(hit, gestureCtxRef.current);

			// Space and Hand govern the whole strip, including its gutter and pad.
			// Starting the pan here is the action half of the same resolution that
			// gives those regions a grab cursor.
			if (
				resolved?.tier === "space-pan" || resolved?.tier === "hand-tool"
			) {
				dragRef.current = { mode: "pan-rect", lastClientX: e.clientX };
				inFlightRef.current = gestureFor("pan-rect");
				e.currentTarget.style.cursor = timelineCursor({
					hit: null,
					inFlight: inFlightRef.current,
					gestureCtx: gestureCtxRef.current,
				});
				return;
			}
			if (resolved?.tier !== "default") return;

			if (resolved.verb.kind === "toggle-row-visibility") {
				if (resolved.verb.scope.kind === "all") {
					onCycleAllVisibility?.();
				}
				return;
			}

			let mode: OverviewDragState["mode"];
			if (resolved.verb.kind === "resize-time-window") {
				mode = resolved.verb.edge === "start" ? "resize-start" : "resize-end";
			} else if (
				resolved.verb.kind === "pan-view" &&
				hit?.surface === "timeline-overview"
			) {
				if (hit.t < view.windowStart || hit.t > view.windowEnd) {
					const halfWidth = (view.windowEnd - view.windowStart) / 2;
					onSetView(
						clampView(
							{
								...view,
								windowStart: hit.t - halfWidth,
								windowEnd: hit.t + halfWidth,
							},
							clock.duration,
							maxWidth,
							panMaxT,
						),
					);
				}
				mode = "pan-rect";
			} else {
				return;
			}
			dragRef.current = { mode, lastClientX: e.clientX };
			inFlightRef.current = gestureFor(mode);
			e.currentTarget.style.cursor = timelineCursor({
				hit: null,
				inFlight: inFlightRef.current,
				gestureCtx: gestureCtxRef.current,
			});
		},
		[
			view,
			clock.duration,
			maxWidth,
			panMaxT,
			onSetView,
			hoverTRef,
			onCycleAllVisibility,
		],
	);

	const endDrag = useCallback(() => {
		dragRef.current = null;
		inFlightRef.current = null;
		surface.release();
	}, [surface]);

	const handlePointerMove = useCallback(
		(e: React.PointerEvent<HTMLDivElement>) => {
			// A move with no button held is a pointer-up that went
			// missing, and `watchGestureEnd` has already ended the drag
			// by the time this bubbles here. So a live `dragRef` is the
			// whole guard.
			const drag = dragRef.current;
			if (!drag) return;
			const rect = e.currentTarget.getBoundingClientRect();
			const dx = e.clientX - drag.lastClientX;
			drag.lastClientX = e.clientX;
			const mode = drag.mode;

			onSetView((current) => {
				// plotW depends on `current.gutterWidth`; recompute against
				// the latest view so a gutter resize mid-drag doesn't fall
				// back to a stale dx→dt conversion.
				const plotW = plotWidthOf(rect.width, current);
				if (plotW <= 0) return current;
				const dt = (dx / plotW) * clock.duration;
				if (mode === "pan-rect") {
					return clampView(
						{
							...current,
							windowStart: current.windowStart + dt,
							windowEnd: current.windowEnd + dt,
						},
						clock.duration,
						maxWidth,
						panMaxT,
					);
				}
				if (mode === "resize-start") {
					const newStart = Math.min(
						current.windowEnd - MIN_WINDOW_MS,
						current.windowStart + dt,
					);
					return clampView(
						{ ...current, windowStart: newStart },
						clock.duration,
						maxWidth,
						panMaxT,
					);
				}
				const newEnd = Math.max(
					current.windowStart + MIN_WINDOW_MS,
					current.windowEnd + dt,
				);
				return clampView(
					{ ...current, windowEnd: newEnd },
					clock.duration,
					maxWidth,
					panMaxT,
				);
			});
		},
		[clock.duration, maxWidth, panMaxT, onSetView, endDrag],
	);

	const handleHoverMove = useCallback(
		(e: React.PointerEvent<HTMLDivElement>) => {
			const rect = e.currentTarget.getBoundingClientRect();
			const px = e.clientX - rect.left;
			// What the strip is pointing at, then what `cursorFor` says about it.
			// This host writes the answer and decides none of it.
			const hit = overviewHitAt({
				px,
				width: rect.width,
				view,
				duration: clock.duration,
				hasAllRowsEyeball: onCycleAllVisibility !== undefined,
			});
			e.currentTarget.style.cursor = timelineCursor({
				hit,
				inFlight: null,
				gestureCtx: gestureCtxRef.current,
			});
			e.currentTarget.title = hit?.surface === "timeline-gutter-eyeball" &&
					allVisMode !== undefined
				? eyeGlyphStatus(allVisMode, { kind: "all" })
				: OVERVIEW_HOST_TITLE;
			// The ghost playhead follows the pointer only over the t-content area;
			// the gutter and the left pad carry no time.
			hoverTRef.current = hit !== null && hit.surface !== "timeline-gutter-eyeball" ? hit.t : null;
		},
		// List `view` whole, hit resolution reads its gutter width and window,
		// which would otherwise go stale after a resize.
		[view, clock.duration, hoverTRef, onCycleAllVisibility, allVisMode],
	);

	const handlePointerUp = useCallback(
		(e: React.PointerEvent<HTMLDivElement>) => {
			try {
				e.currentTarget.releasePointerCapture(e.pointerId);
			} catch {
				// capture may already be released
			}
			endDrag();
			// Recompute cursor now rather than waiting for the next move.
			handleHoverMove(e);
		},
		[endDrag, handleHoverMove],
	);

	const handleMove = useCallback(
		(e: React.PointerEvent<HTMLDivElement>) => {
			if (dragRef.current) handlePointerMove(e);
			else handleHoverMove(e);
		},
		[handlePointerMove, handleHoverMove],
	);

	// Releases this element never sees, off-document pointerup, OS
	// chrome, capture loss, window blur, reach `endDrag` through
	// the window watch in `useGestureSurface`, which every gesture
	// surface shares.

	useEffect(() => {
		const host = hostRef.current;
		if (!host) return;
		const handler = (e: WheelEvent) => {
			e.preventDefault();
			const rect = host.getBoundingClientRect();
			const px = e.clientX - rect.left;
			onSetView((current) =>
				applyWheel(
					e,
					current,
					clock.duration,
					px,
					rect.width,
					maxWidth,
					panMaxT,
				)
			);
		};
		host.addEventListener("wheel", handler, { passive: false });
		return () => host.removeEventListener("wheel", handler);
	}, [clock.duration, maxWidth, panMaxT, onSetView]);

	return (
		<div
			ref={hostRef}
			onPointerDown={handlePointerDown}
			onPointerMove={handleMove}
			onPointerUp={handlePointerUp}
			onPointerCancel={handlePointerUp}
			onPointerLeave={() => {
				hoverTRef.current = null;
			}}
			style={{
				// Marker div catches React events + carries layout; the
				// unified canvas behind it paints the pixels.
				display: "block",
				width: `${width}px`,
				height: `${OVERVIEW_HEIGHT}px`,
				userSelect: "none",
				touchAction: "none",
				background: "transparent",
				position: "relative",
				zIndex: 1,
			}}
			title={OVERVIEW_HOST_TITLE}
		/>
	);
}

type OverviewDragState = {
	mode: "pan-rect" | "resize-start" | "resize-end";
	lastClientX: number;
};
type OverviewDrag = OverviewDragState | null;

/** This strip's drag modes in the resolver's vocabulary (§ 4.5), which is
 *  what the cursor rule reads. A jump-then-pan and a plain pan are one verb:
 *  the recentre happens on the press, and what the drag does after it is pan
 *  the window either way. */
function gestureFor(mode: OverviewDragState["mode"]): TimelineGesture {
	if (mode === "pan-rect") {
		return { surface: "timeline-overview", verb: { kind: "pan-view" } };
	}
	return {
		surface: "timeline-overview-edge",
		verb: {
			kind: "resize-time-window",
			edge: mode === "resize-start" ? "start" : "end",
		},
	};
}
