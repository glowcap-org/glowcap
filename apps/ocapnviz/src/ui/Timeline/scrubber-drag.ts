/**
 * Scrubber pointer-drag modes.
 *
 * `Scrubber.tsx` owns the Pixi scene. `use-scrubber-pointers.ts`
 * owns the pointer listeners. This module owns the in-flight
 * gesture shape and what each mode does on move: rubber-band, row
 * reorder, and event retime. Hover stays with the pointer host,
 * it is what the pointer is over, not what a drag is doing.
 */

import type { MutableRefObject, PointerEvent } from "react";
import type { MoveIntent, MoveSpanIntent } from "../../engine/authoring/moves.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { momentOf } from "../../engine/event-helpers.ts";
import { momentEffective } from "../../engine/temporal/doc-resolver.ts";
import { type SelectMode } from "../../render/types.ts";
import { entityKey, type EntityRefKey } from "../../interactions/types.ts";
import { clampRectToBounds, rectFromCorners } from "../../render/geometry.ts";
import { eventEntityRef } from "./event-entity-ref.ts";
import { scrubberPlotBounds } from "./row-layout.ts";
import { type LaneKind, snapToMajorTick, type TimelineView, tToCanvasPx } from "./state.ts";
import type { ScrubberHit } from "./hit-test.ts";

export type DragMode =
	| { kind: "scrub"; lastClientX: number }
	| { kind: "pan"; lastClientX: number; lastClientY: number }
	| {
		kind: "event";
		/** What was hit. Carried so we can dispatch select on a
		 * no-move release or paint the halo during drag. */
		hit: ScrubberHit;
		/** Client-X at the start of the drag. New `t` is computed by
		 * mapping the displacement through the current `pxPerMs`. */
		startClientX: number;
		/** Becomes true once displacement exceeds the drag threshold.
		 * Gates the transaction begin so pure clicks (no movement)
		 * don't open a no-op undo step. */
		moved: boolean;
		/** True while an engine transaction is open. Flipped on the
		 * first move above threshold. Ended in `endDrag`. */
		txOpen: boolean;
		/** Modifier-resolved selection intent for a no-move release,
		 *  the stage's vocabulary (`selectModeFromModifiers`): plain
		 *  click replaces, shift adds, shift+option removes. Drag
		 *  movement always operates on the dragged entity's cohort
		 *  regardless of this value. The mode only steers the click. */
		selectMode: SelectMode;
		/** True when the dragged entity was NOT in the selection at
		 * pointerdown. Such a gesture is a select-only intent, drag
		 * movement is ignored so unselected entities cannot translate
		 * or resize. Release still selects the entity. The user must
		 * click a second time on the now-selected entity to drag. */
		selectOnly: boolean;
		/** Snapshot of (eventId, originalT, originalArrivalT?) for
		 * every event in the multi-selection at drag-start. Set
		 * iff the dragged event is itself in the multi-selection,
		 * that's the "drag any selected pill → all move together"
		 * trigger. Captured at start so a mid-drag prop change can't
		 * drift the math. */
		bulkOriginals?: Array<{
			eventId: string;
			t: number;
			arrivalT?: number;
		}>;
	}
	| {
		/** Click-and-drag rectangle on empty plot area to multi-
		 * select every event whose pill intersects the rect. */
		kind: "rubber-band";
		startClientX: number;
		startClientY: number;
		currentClientX: number;
		currentClientY: number;
		/** Modifier mode latched at drag start. The stage marquee's
		 * vocabulary: replace, add (shift), remove (shift+option). */
		mode: SelectMode;
		moved: boolean;
	}
	| {
		/** Horizontal drag of the gutter's right edge, resizing
		 *  `view.gutterWidth`. The edge has a small ±px grab band
		 *  (`GUTTER_DRAG_GRAB_PX`) on top of any other interaction
		 *  so the seam stays reliably catchable. */
		kind: "gutter-resize";
		startClientX: number;
		startGutterWidth: number;
	}
	| {
		/** Vertical drag-reorder of a per-entity row header. */
		kind: "row-drag";
		category: Exclude<LaneKind, "ruler">;
		entityId: string;
		/** Index of the row being dragged in its category's CURRENT
		 * ordered-entities list. Captured at drag-start so the
		 * insertion-index math has a stable origin. */
		startIndex: number;
		/** Snapshot of the current ordered-entities list for this
		 * category. The drag commits a new permutation of this
		 * list, captured here so a mid-drag prop change (rare but
		 * possible) doesn't drift the math. */
		startOrder: string[];
		startClientY: number;
		/** Per-row height in pixels, captured at drag-start. Used to status-allow: purpose clause
		 * convert clientY delta into insertion-index delta. */
		rowPitchPx: number;
		moved: boolean;
		/** Resolved on pointerup. */
		finalIndex: number;
	}
	| null;

/** The observation event a hit's drag plan retimes, or null when the plan is
 *  entity-addressed. An authored peer or session, whose painted span no
 *  observation names. */
export function eventIdOfPlan(hit: ScrubberHit): string | null {
	const plan = hit.drag;
	if (plan === null) return null;
	if (plan.kind === "entity-span-edge" || plan.kind === "entity-span-body") {
		return null;
	}
	return plan.eventId;
}

/** Px threshold to distinguish click-to-select from drag-to-retime.
 * Matches the Stage's peer-drag threshold for muscle-memory
 * consistency. */
const EVENT_DRAG_THRESHOLD_PX = 4;

/** Rubber-band drag: track the live corner, clamp the rect to the
 *  plot content bounds, stash for the paint loop. The unified pixi
 *  canvas spans the viewport unmasked, so an unclamped rect happily
 *  paints into sibling panels when the pointer wanders out, clamping
 *  here AND at commit makes WYSIWYG. */
export function updateRubberBand(
	e: PointerEvent<HTMLDivElement>,
	drag: Extract<DragMode, { kind: "rubber-band" }>,
	region: { width: number; height: number },
	view: TimelineView,
	rubberBandRef: MutableRefObject<
		{ x: number; y: number; width: number; height: number } | null
	>,
): void {
	drag.currentClientX = e.clientX;
	drag.currentClientY = e.clientY;
	if (!drag.moved) {
		const dx = Math.abs(drag.currentClientX - drag.startClientX);
		const dy = Math.abs(drag.currentClientY - drag.startClientY);
		if (Math.hypot(dx, dy) >= EVENT_DRAG_THRESHOLD_PX) drag.moved = true;
	}
	const hostRect = e.currentTarget.getBoundingClientRect();
	const bounds = scrubberPlotBounds(view, region.width, region.height);
	const raw = rectFromCorners(
		drag.startClientX - hostRect.left,
		drag.startClientY - hostRect.top,
		drag.currentClientX - hostRect.left,
		drag.currentClientY - hostRect.top,
	);
	rubberBandRef.current = drag.moved ? clampRectToBounds(raw, bounds) : null;
}

/** Row-reorder drag: convert clientY delta into an insertion-index
 *  delta against the captured row pitch. Commit happens on pointerup
 *  in `endDrag`. This just tracks `drag.finalIndex`. */
export function updateRowDrag(
	e: PointerEvent<HTMLDivElement>,
	drag: Extract<DragMode, { kind: "row-drag" }>,
): void {
	const dy = e.clientY - drag.startClientY;
	if (!drag.moved && Math.abs(dy) < EVENT_DRAG_THRESHOLD_PX) return;
	drag.moved = true;
	const indexDelta = Math.round(dy / drag.rowPitchPx);
	drag.finalIndex = Math.max(
		0,
		Math.min(drag.startOrder.length - 1, drag.startIndex + indexDelta),
	);
}

/** Event drag move, engages bulk-cohort + opens the undo txn on the
 *  first above-threshold frame, then dispatches to the engine per the
 *  drag plan's kind. Mutates `drag` (moved/txOpen/bulkOriginals) and
 *  `snapLineRef` (snap guide x in canvas px). */
export function applyEventDragMove(
	args: {
		e: PointerEvent<HTMLDivElement>;
		rect: DOMRect;
		drag: Extract<DragMode, { kind: "event" }>;
		plotWidth: number;
		view: TimelineView;
		events: readonly TimelineEvent[];
		doc: TimelineDocument;
		selectionSet: ReadonlySet<EntityRefKey>;
		snapLineRef: MutableRefObject<number | null>;
		beginEdit: ((label: string) => void) | undefined;
		onMoveEvent: (move: MoveIntent) => void;
		onMoveEntitySpan: ((move: MoveSpanIntent) => void) | undefined;
	},
): void {
	const {
		e,
		rect,
		drag,
		plotWidth,
		view,
		events,
		doc,
		selectionSet,
		snapLineRef,
		beginEdit,
		onMoveEvent,
		onMoveEntitySpan,
	} = args;
	const totalDx = e.clientX - drag.startClientX;
	if (!drag.moved && Math.abs(totalDx) < EVENT_DRAG_THRESHOLD_PX) return;
	// Select-only gesture (entity wasn't selected at pointerdown):
	// swallow movement so an unselected entity can't be dragged or
	// resized. Release still routes through endDrag's no-move branch
	// and dispatches the select.
	if (drag.selectOnly) return;
	// selectOnly already implies a non-null drag plan (pointerdown
	// forces selectOnly when `hit.drag === null`). The narrowing here
	// is for the compiler. Every downstream branch needs the plan
	// to read its eventId and times.
	if (drag.hit.drag === null) return;
	const plan = drag.hit.drag;
	const dt = plotWidth > 0 ? totalDx * (view.windowEnd - view.windowStart) / plotWidth : 0;
	// Entity-addressed spans (freshly authored entities with no
	// observation events): same gestures, dispatched through
	// `move-entity-span`. Handled before the event-addressed switch
	// because there is no eventId to read.
	if (plan.kind === "entity-span-edge" || plan.kind === "entity-span-body") {
		if (!drag.moved) {
			drag.moved = true;
			beginEdit?.(
				plan.kind === "entity-span-edge" ? "Resize span" : "Move span",
			);
			drag.txOpen = true;
		}
		const rawEntityT = Math.max(0, plan.originalT + dt);
		const newEntityT = e.shiftKey ? snapToMajorTick(rawEntityT, view, plotWidth) : rawEntityT;
		onMoveEntitySpan?.({
			kind: plan.kind === "entity-span-body" ? "translate" : plan.edge === "left" ? "resize-start" : "resize-end",
			ref: plan.ref,
			newT: newEntityT,
		});
		snapLineRef.current = e.shiftKey ? tToCanvasPx(newEntityT, rect.width, view) : null;
		return;
	}
	const dragEventId = plan.eventId;
	if (!drag.moved) {
		engageEventDrag(
			drag,
			plan,
			dragEventId,
			events,
			selectionSet,
			beginEdit,
		);
	}
	// Anchor t for snap/bulk math: span/moment plans use originalT;
	// message plans use `start` (sent time) as the anchor, since that's
	// the dragged endpoint for body and left-edge gestures.
	const anchorT = plan.kind === "message-edge" || plan.kind === "message-body" ? plan.start : plan.originalT;
	if (drag.bulkOriginals) {
		// BULK: translate every selected event by the same dt. Snap (when
		// held) snaps the DRAGGED event first, then applies the same
		// effective dt to the rest, so the user's primary value lands on
		// the grid and the cohort stays in step.
		const rawAnchor = Math.max(0, anchorT + dt);
		const snappedAnchor = e.shiftKey ? snapToMajorTick(rawAnchor, view, plotWidth) : rawAnchor;
		const effectiveDt = snappedAnchor - anchorT;
		for (const orig of drag.bulkOriginals) {
			const newT = Math.max(0, orig.t + effectiveDt);
			onMoveEvent({ kind: "translate", eventId: orig.eventId, newT });
		}
		snapLineRef.current = e.shiftKey ? tToCanvasPx(snappedAnchor, rect.width, view) : null;
		return;
	}
	// Single-event path. One switch over the drag plan kind routes
	// each gesture to the engine call it needs.
	const rawT = Math.max(0, anchorT + dt);
	const newT = e.shiftKey ? snapToMajorTick(rawT, view, plotWidth) : rawT;
	switch (plan.kind) {
		case "message-edge": {
			if (plan.edge === "right") {
				const sentT = plan.start;
				const rawArrival = Math.max(sentT, plan.end + dt);
				const newArrival = e.shiftKey
					? Math.max(
						sentT,
						snapToMajorTick(rawArrival, view, plotWidth),
					)
					: rawArrival;
				onMoveEvent({
					kind: "resize-end",
					eventId: dragEventId,
					newArrivalT: newArrival,
				});
				snapLineRef.current = e.shiftKey ? tToCanvasPx(newArrival, rect.width, view) : null;
			} else {
				// Left edge: sent moves, arrival stays pinned. Clamp sent ≤ arrival.
				const clampedT = Math.min(newT, plan.end);
				onMoveEvent({
					kind: "resize-start",
					eventId: dragEventId,
					newT: clampedT,
				});
				snapLineRef.current = e.shiftKey ? tToCanvasPx(newT, rect.width, view) : null;
			}
			return;
		}
		case "message-body":
		case "span-body": {
			onMoveEvent({ kind: "translate", eventId: dragEventId, newT });
			snapLineRef.current = e.shiftKey ? tToCanvasPx(newT, rect.width, view) : null;
			return;
		}
		case "span-edge": {
			// Left-edge: resize-start retimes just the start, paired close
			// stays put. Right-edge: dragEventId IS the end event; a plain
			// translate retimes it without sliding its sibling.
			onMoveEvent(
				plan.edge === "left"
					? { kind: "resize-start", eventId: dragEventId, newT }
					: { kind: "translate", eventId: dragEventId, newT },
			);
			snapLineRef.current = e.shiftKey ? tToCanvasPx(newT, rect.width, view) : null;
			return;
		}
		case "moment": {
			// Land the moment where it would be PAINTED: `momentEffective`
			// is the same clamp the lane painter applies, so the diamond
			// follows the pointer to the edge of its entity's span and
			// stops there. `momentOf` names the entity, rather than the
			// clamp naming one kind. A peer's update dragged past its arrival
			// would reach the engine unclamped, and the engine would refuse it
			// once per pointer move, which reads as a burst of
			// "invalid edit" errors from one gesture. The engine still
			// refuses out-of-span moves (it owns the rule); this stops the
			// gesture from asking for one.
			const anchorEv = events.find((ev) => ev.id === dragEventId);
			const moment = anchorEv === undefined ? null : momentOf(anchorEv);
			const dispatchT = moment === null ? newT : momentEffective(doc, moment.lane, moment.owner, newT);
			onMoveEvent({
				kind: "translate",
				eventId: dragEventId,
				newT: dispatchT,
			});
			snapLineRef.current = e.shiftKey ? tToCanvasPx(dispatchT, rect.width, view) : null;
			return;
		}
	}
}

/** First-move setup for an event drag: capture the bulk-cohort
 *  snapshot when applicable, then open the undo transaction with a
 *  label that reflects the gesture. Mutates `drag.moved`,
 *  `drag.bulkOriginals`, `drag.txOpen`. */
function engageEventDrag(
	drag: Extract<DragMode, { kind: "event" }>,
	plan: NonNullable<ScrubberHit["drag"]>,
	dragEventId: string,
	events: readonly TimelineEvent[],
	selectionSet: ReadonlySet<EntityRefKey>,
	beginEdit: ((label: string) => void) | undefined,
): void {
	drag.moved = true;
	// Bulk engages only when the dragged event's entity is itself in
	// the multi-selection, AND the plan is a body translate. Edge
	// resizes (span / message) on a selected entity must NOT cohort-
	// translate. That silently loses the resize intent the user
	// reached for. Moments (state-change diamonds) are individually
	// targeted; sibling diamonds in the same session must not move.
	// Pair-ends (peer-left / session-closed / message-delivered) are
	// skipped because the engine's pair-aware `move-event` slides them
	// with their start.
	if (plan.kind === "span-body" || plan.kind === "message-body") {
		const anchorEv = events.find((ev) => ev.id === dragEventId)!;
		const dragEntityKey = entityKey(eventEntityRef(anchorEv));
		if (selectionSet.has(dragEntityKey)) {
			drag.bulkOriginals = [];
			for (const ev of events) {
				if (
					ev.kind === "peer-left" ||
					ev.kind === "session-closed" ||
					ev.kind === "message-delivered"
				) continue;
				if (!selectionSet.has(entityKey(eventEntityRef(ev)))) continue;
				drag.bulkOriginals.push({
					eventId: ev.id,
					t: ev.t,
					...(ev.kind === "message-sent" ? { arrivalT: ev.arrivalT } : {}),
				});
			}
		}
	}
	// Bracket the burst in one undo step. Label reflects whether
	// we're bulk-shifting, single-moving, or specifically retiming
	// a message's arrival.
	const label = drag.bulkOriginals
		? "Move events"
		: plan.kind === "message-edge" && plan.edge === "right"
		? "Adjust flight time"
		: "Move event";
	beginEdit?.(label);
	drag.txOpen = true;
}
