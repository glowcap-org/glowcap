// The moves this page starts from script. A stylesheet answers a reader who
// asked for less motion through the rule in controls.css. That rule does not
// reach a move started here, so each caller asks `still` first.

let asked: MediaQueryList | undefined;

/** Whether this reader asked for less motion. */
export function lessMotion(): boolean {
	asked ??= globalThis.matchMedia?.("(prefers-reduced-motion: reduce)");
	return asked?.matches === true;
}

/** Whether a move started now would be unwanted or unseen: the reader asked
 * for less motion, or the page is out of sight. A page out of sight draws no
 * frames, so the moves started there would all begin when it comes back. */
export function still(): boolean {
	return lessMotion() || globalThis.document?.hidden === true;
}

/** Something already on the page going to where the page now puts it. */
export const TRAVEL = { duration: 160, easing: "cubic-bezier(.2, .8, .2, 1)" } as const;

const ARRIVAL = { duration: 120, easing: "ease-out" } as const;

/** One new thing coming to its place among others that stand. */
export function arrive(what: Element): void {
	if (!still()) what.animate([{ opacity: 0, transform: "scale(.96)", offset: 0 }], ARRIVAL);
}

/** A whole part of the page being filled in. Nothing stands around it to
 * come in among, so it is shown and does not move. */
export function fillIn(what: Element): void {
	if (!still()) what.animate([{ opacity: 0, offset: 0 }], ARRIVAL);
}
