/** Release `pointerId`'s capture on `target` when `target` holds it. Releasing
 *  a pointer the browser no longer tracks (after a cancel, or once the element
 *  has detached) throws, and such a pointer holds no capture, so asking first
 *  leaves nothing to catch. */
export function releasePointerCaptureIfHeld(target: Element, pointerId: number): void {
	if (target.hasPointerCapture(pointerId)) target.releasePointerCapture(pointerId);
}
