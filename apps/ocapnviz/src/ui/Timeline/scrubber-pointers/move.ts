/**
 * Scrubber move and hover: in-flight drag updates, and the cursor
 * a modifier press must refresh without waiting for a twitch.
 *
 * Press/teardown live in `press.ts`.
 */

import type { PointerEvent } from "react";
import type { TimelineDocument, TimelineEvent } from "../../../engine/timeline.ts";
import type { SurfaceGestureCtx } from "../../../interactions/types.ts";
import type { RowDescriptor } from "../row-layout.ts";
import { canvasPxToT, GUTTER_MAX_PX, GUTTER_MIN_PX, pan as panView, plotWidthOf, type TimelineView } from "../state.ts";
import { applyEventDragMove, updateRowDrag, updateRubberBand } from "../scrubber-drag.ts";
import { eyeballHoverStatus, scrubberHoverAt, timelineCursor, type TimelineGesture } from "../timeline-cursor.ts";
import type { ScrubberPointerHost } from "./types.ts";
import type { EventHitIndex } from "../event-hit-index.ts";

/** What the pointer is over and what it should look like there. The zones
 *  and the row key are `scrubberHoverAt`'s answer. The cursor is
 *  `cursorFor`'s, reached through `timelineCursor`. This host writes both and
 *  decides neither. */
function computeHoverState(
	args: {
		px: number;
		py: number;
		rect: DOMRect;
		view: TimelineView;
		scrollY: number;
		rows: readonly RowDescriptor[];
		events: readonly TimelineEvent[];
		doc: TimelineDocument;
		eventIndex: EventHitIndex;
		disabledScrub: boolean;
		/** The gesture this host is running, or null while it only hovers. */
		inFlight: TimelineGesture | null;
		/** The App's gesture context. A held Shift previews the selection edit
		 *  the click or marquee would commit, exactly as it does on the Stage. */
		gestureCtx: SurfaceGestureCtx;
	},
): { cursor: string; hoverKey: string | null; statusTitle: string | null } {
	const { hit, hoverKey } = scrubberHoverAt({
		point: { px: args.px, py: args.py },
		size: { width: args.rect.width, height: args.rect.height },
		view: args.view,
		scrollY: args.scrollY,
		rows: args.rows,
		events: args.events,
		doc: args.doc,
		disabledScrub: args.disabledScrub,
		eventIndex: args.eventIndex,
	});
	return {
		cursor: timelineCursor({
			hit,
			inFlight: args.inFlight,
			gestureCtx: args.gestureCtx,
		}),
		hoverKey,
		statusTitle: eyeballHoverStatus(hit, args.doc),
	};
}

/** Re-preview the cursor at the last hover when a modifier changes. */
export function refreshScrubberModifierHover(h: ScrubberPointerHost): void {
	const {
		hostRef,
		lastHoverRef,
		dragRef,
		propsRef,
		scrollYRef,
		disabledScrub,
		gestureCtxRef,
		hoverGutterRowRef,
		hostTitle,
	} = h;
	const host = hostRef.current;
	const at = lastHoverRef.current;
	if (!host || !at || dragRef.current) return;
	const p = propsRef.current;
	const rect = host.getBoundingClientRect();
	const { cursor, hoverKey, statusTitle } = computeHoverState({
		px: at.px,
		py: at.py,
		rect,
		view: p.view,
		scrollY: scrollYRef.current,
		rows: p.interactionRows,
		events: p.events,
		doc: p.doc,
		eventIndex: p.eventHitIndex,
		disabledScrub,
		inFlight: null,
		gestureCtx: gestureCtxRef.current,
	});
	host.style.cursor = cursor;
	host.title = statusTitle ?? hostTitle;
	hoverGutterRowRef.current = hoverKey;
}

export function onScrubberPointerMove(
	h: ScrubberPointerHost,
	e: PointerEvent<HTMLDivElement>,
): void {
	const {
		dragRef,
		hoverTRef,
		view,
		lastHoverRef,
		propsRef,
		scrollYRef,
		disabledScrub,
		inFlightRef,
		gestureCtxRef,
		hoverGutterRowRef,
		hostTitle,
		onSetView,
		clockDuration,
		viewMaxWidth,
		viewPanMaxT,
		scrollYMaxRef,
		onSeek,
		regionSizeRef,
		rubberBandRef,
		onMoveEvent,
		onMoveEntitySpan,
		selectionSetRef,
		snapLineRef,
		beginEdit,
		events,
	} = h;
	const rect = e.currentTarget.getBoundingClientRect();
	const drag = dragRef.current;
	// Ghost playhead is hover-only, once a drag starts, the
	// real playhead (scrub) or cursor (pan) carries the signal.
	// Mirrors the Overview's behavior.
	if (!drag) {
		const px = e.clientX - rect.left;
		hoverTRef.current = canvasPxToT(px, rect.width, view);
		lastHoverRef.current = { px, py: e.clientY - rect.top };
		const { cursor, hoverKey, statusTitle } = computeHoverState({
			px,
			py: e.clientY - rect.top,
			rect,
			view,
			scrollY: scrollYRef.current,
			rows: propsRef.current.interactionRows,
			events: propsRef.current.events,
			doc: propsRef.current.doc,
			eventIndex: propsRef.current.eventHitIndex,
			disabledScrub,
			inFlight: null,
			gestureCtx: gestureCtxRef.current,
		});
		e.currentTarget.style.cursor = cursor;
		e.currentTarget.title = statusTitle ?? hostTitle;
		hoverGutterRowRef.current = hoverKey;
		return;
	}
	// A gesture in flight is what is HAPPENING, and it outranks whatever
	// the pointer is passing over (cursor.md, rung 1). A scrub that wanders
	// into the gutter still reads as a scrub. Written every move so the
	// answer cannot go stale under the drag.
	if (inFlightRef.current !== null) {
		e.currentTarget.style.cursor = timelineCursor({
			hit: null,
			inFlight: inFlightRef.current,
			gestureCtx: gestureCtxRef.current,
		});
	}
	// A move with no button held is a pointer-up that went
	// missing, and `watchGestureEnd` has already ended the drag
	// by the time this bubbles here. So the live `drag` read
	// above is the whole guard.
	const plotWidth = plotWidthOf(rect.width, view);
	switch (drag.kind) {
		case "gutter-resize": {
			const dx = e.clientX - drag.startClientX;
			const next = drag.startGutterWidth + dx;
			const clamped = Math.max(
				GUTTER_MIN_PX,
				Math.min(GUTTER_MAX_PX, next),
			);
			onSetView((cur) => ({ ...cur, gutterWidth: clamped }));
			return;
		}
		case "pan": {
			const dx = e.clientX - drag.lastClientX;
			const dy = e.clientY - drag.lastClientY;
			drag.lastClientX = e.clientX;
			drag.lastClientY = e.clientY;
			// Vertical: grab-the-paper, content follows the pointer,
			// so dragging down reveals rows that were above.
			if (dy !== 0) {
				const next = Math.max(
					0,
					Math.min(
						scrollYMaxRef.current,
						scrollYRef.current - dy,
					),
				);
				if (next !== scrollYRef.current) {
					scrollYRef.current = next;
					hoverTRef.current = null;
				}
			}
			// Horizontal: updater form so `dt` derives from the CURRENT
			// window width, without this, multiple moves per frame all
			// pan against the original window and the drag feels weak.
			if (dx !== 0) {
				onSetView((current) => {
					const dt = plotWidth > 0
						? -(dx / plotWidth) *
							(current.windowEnd - current.windowStart)
						: 0;
					return panView(
						current,
						dt,
						clockDuration,
						viewMaxWidth,
						viewPanMaxT,
					);
				});
			}
			return;
		}
		case "scrub": {
			drag.lastClientX = e.clientX;
			const t = canvasPxToT(e.clientX - rect.left, rect.width, view);
			if (t === null) return;
			onSeek(Math.max(0, Math.min(clockDuration, t)));
			return;
		}
		case "rubber-band": {
			updateRubberBand(
				e,
				drag,
				regionSizeRef.current,
				propsRef.current.view,
				rubberBandRef,
			);
			return;
		}
		case "row-drag": {
			updateRowDrag(e, drag);
			return;
		}
		case "event": {
			if (!onMoveEvent) return;
			applyEventDragMove({
				onMoveEntitySpan,
				e,
				rect,
				drag,
				plotWidth,
				view,
				events,
				doc: propsRef.current.doc,
				selectionSet: selectionSetRef.current,
				snapLineRef,
				beginEdit,
				onMoveEvent,
			});
			return;
		}
	}
}
