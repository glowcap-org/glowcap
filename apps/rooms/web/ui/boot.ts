// The end of the opening screen.
//
// page.html puts a screen up on the first parse, because a page that draws
// itself has nothing to show until its script has run. Taking that screen down
// is all this module does, and the only interesting part is when.
//
// The bundle starting to run is the wrong moment. It is a moment the reader
// cannot tell apart from arrival, and yet nothing they came for is there yet:
// the peer opens in the browser, dials the room server, and only then is there a
// list of live rooms to browse or a room to enter. Handing over there would
// swap one wait for another and present it as the page.
//
// So the screen stays up until the peer's first attempt has settled, whichever
// way it settled. Either it reached the room server, and the page opens with its
// rooms already listed, or it did not, and the interface takes over saying so in
// the line under the rail. What must not happen is the screen outliving the
// answer, which is why the other end is here too: a render that crashed hands
// over immediately, because a card explaining a crash to a reader who cannot see
// it is not an explanation.

import * as store from "./store.ts";

/** The two states this module puts the document in. `running` closes the window
 * in which page.html's watcher may call the page lost; `done` is the last word
 * on the screen, and the rooms stylesheets draw the fade from it. */
const RUNNING = "running";
const HANDED_OVER = "done";

/** How long to wait for the fade's own end before taking the screen down
 * anyway. Comfortably past the stylesheet's `.3s`, so it never cuts a fade
 * short, and short enough that a reader whose browser sent no event is not left
 * looking at a sheet over a page that is ready. */
const HANDOVER_FLOOR_MS = 500;

export type RoomsOpeningReadiness = "controller-snapshot" | "directory-attempt";

/** Whether the wait this screen covers is over: the page's first attempt at a
 * room server has come back, connected or not.
 *
 * Any directory answering ends the wait. The screen covers reaching a server at
 * all, not the health of every one this tab may go on to hold. */
function settled(): boolean {
	return store.anyDirSettled();
}

/** Whether the page has already been handed over. The states run one way, so
 * whichever end of the wait got here first has the last word: a crash that hands
 * over early must not be followed back into a screen by the entry module
 * reporting, a moment later, that it finished running. */
function handedOver(): boolean {
	return document.documentElement.dataset.boot === HANDED_OVER;
}

/** Hand the page to the interface now. Safe to call more than once, and from
 * either of the two paths that end the wait. */
export function handOffNow(): void {
	if (handedOver()) return;
	document.documentElement.dataset.boot = HANDED_OVER;
	const boot = document.getElementById("boot");
	if (boot === null) return;
	// The fade is the stylesheet's, and so is how long it lasts for a reader who
	// has asked for less motion: one place decides. It does depend on the event
	// being the screen's own. A transition ending anywhere inside it bubbles up
	// here too, and acting on one of those would snatch the screen away mid-fade,
	// which is the flash this whole arrangement is against.
	//
	// The timer is the floor under it. A transition that never *starts* fires no
	// `transitionend` at all — a zero duration, an ancestor that is not rendered,
	// a tab whose painting is throttled while it loads in the background — and
	// the screen covers the whole page, so the cost of the event not arriving is
	// the application sitting behind a sheet nobody can dismiss. Whichever of the
	// two lands first wins and cancels the other; the event stays the primary
	// signal, because it is the one that knows when the fade is actually done.
	const gone = (event?: TransitionEvent) => {
		if (event !== undefined && event.target !== boot) return;
		clearTimeout(floor);
		boot.removeEventListener("transitionend", gone);
		boot.remove();
	};
	boot.addEventListener("transitionend", gone);
	// Declared after the handler that clears it, which is safe because nothing
	// can run the handler until one of the two signals arrives.
	const floor = setTimeout(gone, HANDOVER_FLOOR_MS);
}

/** Run `fn` once the mark has finished stacking its pancakes at least once.
 *
 * On a fast network the peer can answer before the first stack has landed,
 * and a splash that vanishes mid-fall reads as a glitch, not a mark. The
 * stylesheet owns the choreography, so it also states when one build is done:
 * `--boot-stacked` on the mark, declared beside the keyframes it summarizes.
 * How far in the animation is comes from the animation itself, which makes
 * the reduced-motion case free: its near-zero run has already finished, no
 * animation is left to read, and the wait is nothing — a reader who asked
 * for less motion is not made to sit through timing they never saw. */
function onceStacked(fn: () => void): void {
	const mark = document.querySelector(".boot-mark");
	if (mark === null) return fn();
	const stacked = parseFloat(getComputedStyle(mark).getPropertyValue("--boot-stacked")) * 1000;
	const elapsed = mark.getAnimations()[0]?.currentTime;
	if (!Number.isFinite(stacked) || typeof elapsed !== "number") return fn();
	const wait = stacked - elapsed;
	if (wait <= 0) return fn();
	setTimeout(fn, wait);
}

/** Hold the screen until the controller has answered and the mark has stacked
 * one full set of pancakes, then hand over. An attached controller answers with
 * its complete initial snapshot; unlike local reconstruction, that snapshot
 * may correctly contain no directory whose attempt could settle the store.
 *
 * Called at the end of the entry module, which is what moves the page out of
 * the opening state page.html stamped, and so out of the reach of its watcher:
 * an error before this point is a page that never started and gets the
 * explanation, and an error after it belongs to the running page. */
export function handOffWhenReady(readiness: RoomsOpeningReadiness): void {
	if (handedOver()) return;
	document.documentElement.dataset.boot = RUNNING;
	if (readiness === "controller-snapshot" || settled()) return onceStacked(handOffNow);
	const stop = store.subscribe(() => {
		if (!settled()) return;
		stop();
		onceStacked(handOffNow);
	});
}
