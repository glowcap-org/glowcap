import { useCallback, useEffect, useRef, useState } from "react";
import { useGestureSurface } from "../interactions/use-gesture-surface.ts";

export type ResizeAxis = "x" | "y";

const RESIZE_HANDLE_SURFACE_TAG = "ui-resize";

/** How far one arrow key moves a seam, and how far a held Shift
 *  moves it. Small enough that a press is a nudge, and coarse enough
 *  that crossing a pane does not take a minute of tapping. The pair
 *  mirrors the stage's own arrow-nudge, where Shift is also the
 *  coarse modifier. */
const KEY_STEP_PX = 16;
const KEY_STEP_COARSE_PX = 64;

/**
 * Resize handle. `onDelta(px)` fires per axis direction (positive
 * x = right, positive y = down) for a pointer drag and for the arrow
 * keys alike, so a seam moves the same way however it is driven.
 *
 * rAF-batched because each `onDelta` cascades through React state
 * → grid-template change → ResizeObserver → scene re-paint → Pixi
 * `renderer.resize` (GPU-buffer reallocation). 120 Hz pointer
 * events into that cascade pegs a CPU core; coalescing caps the
 * work at one cascade per display frame.
 *
 * Uses pointer capture so fast drags don't lose the cursor. Sets
 * the body cursor during drag so it stays correct over any pane.
 */
export function useResizeHandle(
	axis: ResizeAxis,
	onDelta: (deltaPx: number) => void,
) {
	// This handle's lease on the gesture lock, and the one authority
	// on whether a drag is in progress: `surface.pointer()` is set
	// the instant the claim is granted, so no move is dropped
	// waiting for React to commit. The `dragging` state below says
	// the same thing one render later, and only two things that
	// render read it: `ResizeHandle` tints the seam, and the effect
	// below forces the body cursor. No pointer handler reads it. The
	// hook ends a held gesture when the handle leaves the tree, which
	// `App` does with the whole bottom bar, and watches the window for
	// the ends this element cannot see. `endDrag` below is this
	// handle's teardown and every one of those paths runs it; the
	// arrow reads it late, after this render has finished.
	const surface = useGestureSurface(
		RESIZE_HANDLE_SURFACE_TAG,
		() => endDrag(),
	);
	const [dragging, setDragging] = useState(false);
	// Latest pointer position seen (axis-projected). Updated on every
	// pointermove; consumed by the rAF flush.
	const lastPosRef = useRef(0);
	// Last position we've already committed to the host via onDelta.
	// Difference between this and lastPosRef is the un-flushed delta.
	const flushedPosRef = useRef(0);
	const rafIdRef = useRef<number | null>(null);
	// Box the latest onDelta in a ref so the rAF callback always
	// calls the freshest version without re-scheduling on each
	// render of the host.
	const onDeltaRef = useRef(onDelta);
	onDeltaRef.current = onDelta;

	const flush = useCallback(() => {
		rafIdRef.current = null;
		const delta = lastPosRef.current - flushedPosRef.current;
		if (delta === 0) return;
		flushedPosRef.current = lastPosRef.current;
		onDeltaRef.current(delta);
	}, []);

	const scheduleFlush = useCallback(() => {
		if (rafIdRef.current !== null) return;
		rafIdRef.current = globalThis.requestAnimationFrame(flush);
	}, [flush]);

	const onPointerDown = useCallback(
		(event: React.PointerEvent<HTMLDivElement>) => {
			// The claim also tags the host element so the root guard can
			// recognize this surface from an event's composedPath, and
			// both come back together on release. The element arrives
			// with the event because `ResizeHandle` renders without a
			// ref this hook can observe.
			if (!surface.claim(event.currentTarget, event.pointerId)) return;
			event.preventDefault();
			event.currentTarget.setPointerCapture(event.pointerId);
			const start = axis === "x" ? event.clientX : event.clientY;
			lastPosRef.current = start;
			flushedPosRef.current = start;
			setDragging(true);
		},
		[axis, surface],
	);

	// Idempotent drag teardown. Flushes any pending delta first so
	// the final pixel position lands before dragging is cleared.
	const endDrag = useCallback(() => {
		if (rafIdRef.current !== null) {
			globalThis.cancelAnimationFrame(rafIdRef.current);
			rafIdRef.current = null;
		}
		const tail = lastPosRef.current - flushedPosRef.current;
		if (tail !== 0) {
			flushedPosRef.current = lastPosRef.current;
			onDeltaRef.current(tail);
		}
		setDragging(false);
		surface.release();
	}, [surface]);

	const onPointerMove = useCallback(
		(event: React.PointerEvent<HTMLDivElement>) => {
			// A move with no button held is a pointer-up that went
			// missing, and `watchGestureEnd` has already released the
			// lease by the time this bubbles here — so the live claim is
			// the whole guard.
			if (surface.pointer() !== event.pointerId) return;
			lastPosRef.current = axis === "x" ? event.clientX : event.clientY;
			scheduleFlush();
		},
		[axis, surface, scheduleFlush],
	);

	const onPointerUp = useCallback(
		(event: React.PointerEvent<HTMLDivElement>) => {
			if (surface.pointer() !== event.pointerId) return;
			try {
				event.currentTarget.releasePointerCapture(event.pointerId);
			} catch {
				// capture may already be released
			}
			endDrag();
		},
		[surface, endDrag],
	);

	// Off-document releases (OS chrome, URL bar, alt-tab blur) and the
	// handle leaving the tree mid-drag both reach `endDrag` through the
	// window watch in `useGestureSurface`, which every gesture surface
	// shares. A pending rAF only ever exists inside a claimed gesture,
	// because `onPointerMove` schedules one only for the pointer this
	// surface holds — so that one teardown is also the only place the
	// frame needs cancelling.

	// Force the body cursor while dragging so it stays correct over
	// panes with their own cursor styles.
	useEffect(() => {
		if (!dragging) return;
		const previous = document.body.style.cursor;
		document.body.style.cursor = axis === "x" ? "col-resize" : "row-resize";
		return () => {
			document.body.style.cursor = previous;
		};
	}, [dragging, axis]);

	// Arrow keys move the seam along its own axis, through the same
	// `onDelta` contract a drag reports, so the host resizes by one
	// rule. The keys off the axis are left alone: a left-right press on
	// a horizontal seam is somebody navigating, not resizing, and
	// swallowing it would trap the focus ring on the handle.
	//
	// No gesture-surface claim and no rAF here. A press is one discrete
	// delta rather than a stream, so there is nothing to coalesce and no
	// pointer for another surface to contend over — and a key repeat is
	// already paced by the OS.
	const onKeyDown = useCallback(
		(event: React.KeyboardEvent<HTMLDivElement>) => {
			const step = event.shiftKey ? KEY_STEP_COARSE_PX : KEY_STEP_PX;
			const towards = axis === "x"
				? event.key === "ArrowRight" ? step : event.key === "ArrowLeft" ? -step : 0
				: event.key === "ArrowDown"
				? step
				: event.key === "ArrowUp"
				? -step
				: 0;
			if (towards === 0) return;
			event.preventDefault();
			onDeltaRef.current(towards);
		},
		[axis],
	);

	// Cancel + lost-capture route through the same end-drag path so
	// the handle tears down whoever ends the gesture.
	return {
		dragging,
		onPointerDown,
		onPointerMove,
		onPointerUp,
		onPointerCancel: onPointerUp,
		onLostPointerCapture: endDrag,
		onKeyDown,
	};
}
