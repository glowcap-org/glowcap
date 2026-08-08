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
 * on the screen, and page.css draws the fade from it. */
const RUNNING = "running";
const HANDED_OVER = "done";

/** Whether the wait this screen covers is over: the peer's first attempt at the
 * room server has come back, connected or not. */
function settled(): boolean {
	return store.get().session !== "connecting";
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
	// has asked for less motion: one place decides. Removing the element
	// afterwards only tidies up, since it is already transparent and untouchable
	// by then, so nothing depends on the event arriving. It does depend on the
	// event being the screen's own. A transition ending anywhere inside it
	// bubbles up here too, and acting on one of those would snatch the screen
	// away mid-fade, which is the flash this whole arrangement is against.
	const gone = (event: TransitionEvent) => {
		if (event.target !== boot) return;
		boot.removeEventListener("transitionend", gone);
		boot.remove();
	};
	boot.addEventListener("transitionend", gone);
}

/** Hold the screen until the peer has answered, then hand over.
 *
 * Called at the end of the entry module, which is what moves the page out of
 * the opening state page.html stamped, and so out of the reach of its watcher:
 * an error before this point is a page that never started and gets the
 * explanation, and an error after it belongs to the running page. */
export function handOffWhenReady(): void {
	if (handedOver()) return;
	document.documentElement.dataset.boot = RUNNING;
	if (settled()) return handOffNow();
	const stop = store.subscribe(() => {
		if (!settled()) return;
		stop();
		handOffNow();
	});
}
