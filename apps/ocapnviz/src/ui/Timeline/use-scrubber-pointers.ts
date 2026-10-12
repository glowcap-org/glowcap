/**
 * How a Scrubber pointer becomes a drag mode or a selection.
 *
 * `Scrubber.tsx` owns the React host, wheel zoom, and double-click fit.
 * `use-scrubber-scene.ts` owns the Pixi scene and paint ticker.
 * This hook holds the gesture lease and the live host object. Press
 * (`press.ts`) arms and commits, move (`move.ts`) updates in flight
 * and refreshes the cursor when a modifier changes.
 */

import { type MutableRefObject, type PointerEvent, type RefObject, useCallback, useEffect, useRef } from "react";
import type { EntityRefKey, SurfaceGestureCtx } from "../../interactions/types.ts";
import { useGestureSurface } from "../../interactions/use-gesture-surface.ts";
import type { DragMode } from "./scrubber-drag.ts";
import type { TimelineGesture } from "./timeline-cursor.ts";
import { endScrubberDrag, onScrubberPointerDown, onScrubberPointerUp } from "./scrubber-pointers/press.ts";
import { onScrubberPointerMove, refreshScrubberModifierHover } from "./scrubber-pointers/move.ts";
import type { ScrubberPointerHost, ScrubberPointerLive } from "./scrubber-pointers/types.ts";

const SCRUBBER_SURFACE_TAG = "timeline";

export type ScrubberPointerBindings =
	& {
		hostRef: RefObject<HTMLDivElement | null>;
		dragRef: MutableRefObject<DragMode>;
		rubberBandRef: MutableRefObject<
			{ x: number; y: number; width: number; height: number } | null
		>;
		snapLineRef: MutableRefObject<number | null>;
		hoverGutterRowRef: MutableRefObject<string | null>;
		scrollYRef: MutableRefObject<number>;
		scrollYMaxRef: MutableRefObject<number>;
		regionSizeRef: MutableRefObject<{ width: number; height: number }>;
		propsRef: { readonly current: ScrubberPointerLive };
		hoverTRef: { current: number | null };
		hostTitle: string;
		gestureCtx: SurfaceGestureCtx;
		selectionSet: ReadonlySet<EntityRefKey>;
	}
	& Omit<
		ScrubberPointerHost,
		| "surface"
		| "hostRef"
		| "dragRef"
		| "inFlightRef"
		| "gestureCtxRef"
		| "selectionSetRef"
		| "lastHoverRef"
		| "rubberBandRef"
		| "snapLineRef"
		| "hoverGutterRowRef"
		| "scrollYRef"
		| "scrollYMaxRef"
		| "regionSizeRef"
		| "propsRef"
		| "hoverTRef"
		| "hostTitle"
	>;

export function useScrubberPointers(args: ScrubberPointerBindings): {
	handlePointerDown: (e: PointerEvent<HTMLDivElement>) => void;
	handlePointerMove: (e: PointerEvent<HTMLDivElement>) => void;
	handlePointerUp: (e: PointerEvent<HTMLDivElement>) => void;
} {
	const inFlightRef = useRef<TimelineGesture | null>(null);
	const lastHoverRef = useRef<{ px: number; py: number } | null>(null);
	const gestureCtxRef = useRef(args.gestureCtx);
	gestureCtxRef.current = args.gestureCtx;
	const selectionSetRef = useRef(args.selectionSet);
	selectionSetRef.current = args.selectionSet;
	const liveRef = useRef<ScrubberPointerHost>(null!);

	// This surface's lease on the gesture lock. Cross-surface mutual
	// exclusion: while a Stage gesture is in flight, foreign
	// pointer-downs that land here are stopped before our handlers
	// see them, and vice versa. The hook ends a held gesture when the
	// scrubber leaves the tree, `TimelinePanel` drops it mid-drag
	// whenever recording starts or the slot measures zero wide, and
	// it watches the window for the gesture ends this element cannot
	// see. `endScrubberDrag` is the surface's own teardown and every
	// one of those paths runs it, which is what closes the edit
	// transaction an event drag opened when the panel goes away under
	// the pointer. The arrow reads it late, after this render has
	// finished.
	// `setPointerCapture` doesn't deliver pointerup if the user
	// releases off-document (OS chrome, URL bar). That release, a
	// capture loss, and a window blur all reach `endScrubberDrag`
	// through the window watch in `useGestureSurface`, which every
	// gesture surface shares.
	const surface = useGestureSurface(
		SCRUBBER_SURFACE_TAG,
		() => endScrubberDrag(liveRef.current),
	);

	liveRef.current = {
		...args,
		surface,
		inFlightRef,
		lastHoverRef,
		gestureCtxRef,
		selectionSetRef,
	};

	const { gestureCtx } = args;
	useEffect(() => {
		// Keyed on the context's VALUES, not its identity: App rebuilds the
		// object each render, and this effect hit-tests.
		refreshScrubberModifierHover(liveRef.current);
	}, [
		gestureCtx.spaceHeld,
		gestureCtx.activeTool,
		gestureCtx.modifiers.shift,
		gestureCtx.modifiers.alt,
		gestureCtx.modifiers.cmd,
	]);

	const handlePointerDown = useCallback((e: PointerEvent<HTMLDivElement>) => {
		onScrubberPointerDown(liveRef.current, e);
	}, []);
	const handlePointerMove = useCallback((e: PointerEvent<HTMLDivElement>) => {
		onScrubberPointerMove(liveRef.current, e);
	}, []);
	const handlePointerUp = useCallback((e: PointerEvent<HTMLDivElement>) => {
		onScrubberPointerUp(liveRef.current, e);
	}, []);

	return { handlePointerDown, handlePointerMove, handlePointerUp };
}
