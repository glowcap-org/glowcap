/**
 * React binding for the gesture router, one `SurfaceLease` per
 * gesture surface, held for the surface's lifetime.
 *
 * The hook mints the lease on first render, installs the document
 * root guard once, and lets `watchGestureEnd` own the rest: the
 * window watch for gesture ends the surface's own element cannot
 * see, and the release. That watch's disposer IS this effect's
 * cleanup, which is the reason the claim lives here rather than in
 * each surface's pointer handlers. React detaches a removed
 * element's handlers before any `pointerup` or
 * `lostpointercapture` can reach them, so a surface removed
 * mid-drag would never run its own teardown, and a claim nobody
 * gives back makes the root guard swallow every pointer-down on
 * every other surface, which reads to a user as the canvas
 * freezing.
 */

import { useEffect, useRef } from "react";
import {
	type GestureEndReason,
	gestureRouter,
	installRootGuard,
	type SurfaceLease,
	type SurfaceTag,
	watchGestureEnd,
} from "./gesture-router.ts";

export function useGestureSurface(
	tag: SurfaceTag,
	/** Called when a gesture this surface holds ends somewhere its
	 *  own handlers cannot observe. The surface ends its drag here.
	 *  the watch releases the lease straight after, so an
	 *  implementation that also releases is harmless. Boxed in a
	 *  ref, so it need not be stable across renders.
	 *
	 *  The `GestureEndReason` says whether the reader let go or the gesture was
	 *  taken away. A surface that applies each value as it passes through has
	 *  nothing to revert and ends the same way for both, so most callers here
	 *  ignore it. A surface holding something back until the release has to ask. */
	onEnd?: (reason: GestureEndReason) => void,
): SurfaceLease {
	const leaseRef = useRef<SurfaceLease | null>(null);
	if (leaseRef.current === null) leaseRef.current = gestureRouter.lease(tag);
	const lease = leaseRef.current;

	const onEndRef = useRef(onEnd);
	onEndRef.current = onEnd;

	useEffect(() => {
		installRootGuard();
		// The returned disposer releases the lease, so a surface that
		// leaves the tree mid-gesture cannot strand the lock.
		// `gesture-surface.test.ts` pins that, and pins it against the
		// freeze it prevents.
		return watchGestureEnd(lease, (reason) => onEndRef.current?.(reason));
	}, [lease]);

	return lease;
}
