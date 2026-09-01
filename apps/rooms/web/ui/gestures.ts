// The one gesture `touch-action` does not settle.
//
// `html { touch-action: pan-x pan-y }` in controls.css is what stops the page
// scaling, and on every engine that honours it for the root that is the whole
// story. WebKit is the exception: it scales the page through its own gesture
// events, which are not touch events and are not governed by that property, so
// a pinch there still zooms a page the stylesheet has already said may not.
//
// So this is one engine's other half, not a second mechanism. It listens for
// the events only WebKit sends and refuses them, and does nothing anywhere
// else, because nowhere else sends them.
//
// The double tap is already handled: `touch-action` drops it, which is also why
// this does not go looking for two taps in a row on a clock. Timing a gesture
// by hand is how a scroll flick or a fast reader with two messages to react to
// ends up with a press the page swallowed.

/** The events WebKit raises for a pinch on the page. */
const gestures = ["gesturestart", "gesturechange", "gestureend"] as const;

/** Refuse the page-scaling gesture.
 *
 * The listeners are non-passive, because a passive listener may not refuse the
 * event: the browser would scale anyway, having noted that we asked it not to.
 * Attaching where nothing fires costs nothing, so this does not first ask what
 * engine it is on.
 *
 * Returns the removal for a caller that owns a lifetime. The page's own
 * listeners live as long as the page. */
export function refusePageScaling(target: EventTarget = document): () => void {
	const refuse = (event: Event) => event.preventDefault();
	for (const name of gestures) {
		target.addEventListener(name, refuse, { passive: false });
	}
	return () => {
		for (const name of gestures) target.removeEventListener(name, refuse);
	};
}
