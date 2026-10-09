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
import { stopBootAsides } from "./boot_note.ts";
import type { MarkLive } from "./mark_gpu_live.ts";
import type { PageProjection } from "./store/core.ts";

/** The two states this module puts the document in. `running` closes the window
 * in which page.html's watcher may call the page lost; `done` is the last word
 * on the screen, and the rooms stylesheets draw the fade from it. `leaving` is
 * a reload that has already committed: the same sheet covers the outgoing page
 * so a session that is over cannot flash a crash card on the way out. */
const RUNNING = "running";
const HANDED_OVER = "done";
const LEAVING = "leaving";

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
function settled(projection: PageProjection): boolean {
	return store.anyDirSettled(projection);
}

/** The document element this module stamps, when a document exists. */
function bootRoot(): HTMLElement | null {
	return typeof document === "undefined" ? null : document.documentElement;
}

/** Whether the page has already been handed over. The states run one way, so
 * whichever end of the wait got here first has the last word: a crash that hands
 * over early must not be followed back into a screen by the entry module
 * reporting, a moment later, that it finished running. A committed reload is
 * already past that decision; stamping `done` over `leaving` would take the
 * cover down and let a crash card flash on the way out. */
function handedOver(): boolean {
	const boot = bootRoot()?.dataset.boot;
	return boot === HANDED_OVER || boot === LEAVING;
}

/** Cover the running page for a reload that has already committed. The opening
 * screen was taken out at handover, so this stamps the document and the
 * stylesheet paints the same sheet over whatever React still has in the tree. */
export function coverForReload(): void {
	const root = bootRoot();
	if (root == null) return;
	root.dataset.boot = LEAVING;
}

/** Whether a committed reload's cover is up. A crash surface must not paint a
 * card or stamp `done` over this sheet. */
export function coveringReload(): boolean {
	return bootRoot()?.dataset.boot === LEAVING;
}

/** Drop an address that cannot mean anything until a session is chosen.
 *
 * Operations is session authority drawn as a page, so arriving there without
 * one has nothing to show, and reopening it after a leave is what
 * `standAtFront` was written for. A room or directory address is the opposite:
 * it is a reader following a link somebody sent them, and it has to survive
 * choosing a session so that choosing one puts them where the link pointed.
 *
 * The leave itself already stands at the front through
 * `finishCoveredReload`, so this is only about what a *cold* arrival keeps. */
export function standAtFrontOfPrivilegedAddress(): void {
	if (typeof location === "undefined") return;
	if (!location.pathname.startsWith("/ops")) return;
	standAtFront();
}

/** A session that is over must not reopen on a room or `/ops`. Search and hash
 * still preserve this tab's page configuration. */
function standAtFront(): void {
	if (typeof location === "undefined" || typeof history === "undefined") return;
	const url = new URL(location.href);
	if (url.pathname === "/") return;
	url.pathname = "/";
	history.replaceState(null, "", `${url.pathname}${url.search}${url.hash}`);
}

/** Unload a page that is already covered. `toFront` drops the last place so the
 * next parse opens session choice rather than Operations. */
export function finishCoveredReload(toFront = false): void {
	if (toFront) standAtFront();
	location.reload();
}

/** Reload the running page, covering it first so the outgoing tree cannot flash. */
export function reloadNow(): void {
	coverForReload();
	finishCoveredReload();
}

/** Persist refused after the sheet went up: the page is staying, so put the
 * document back in the handed-over state the running interface already had. */
export function uncoverReload(): void {
	const root = bootRoot();
	if (root == null || root.dataset.boot !== LEAVING) return;
	root.dataset.boot = HANDED_OVER;
}

/** A required chunk or boot step failed while the opening screen was still
 * up. `import()` rejects rather than firing `window.onerror`, so page.html's
 * watcher would never hear it and the splash would sit forever. */
export function pageDidNotOpen(reason: string): void {
	console.error("rooms: the page did not finish opening:", reason);
	const root = bootRoot();
	if (root == null) return;
	const boot = root.dataset.boot;
	if (boot !== "opening" && boot !== RUNNING) return;
	root.dataset.boot = "lost";
}

/** The opening screen's mark, from the moment the bundle asks for it: the
 * promise of one, then the one it got, or null where this browser has no
 * device to draw it with. Held so handover can stop it, and so the wait for
 * one assembled beat can ask it rather than a stylesheet. */
let openingMark: Promise<MarkLive | null> = Promise.resolve(null);

/** Start the opening screen's mark: the shader mushroom, looping its play in
 * the box page.html left for it.
 *
 * The box is empty until this runs. The mark is drawn by code, so nothing
 * can draw it before the code arrives, and the mark growing up out of the
 * ground is how its arrival reads. Called from the entry module rather than
 * at import, because asking for a device is asynchronous and the screen must
 * not wait on it to be a screen.
 *
 * The shader is fetched here rather than imported at the top, so that the
 * WGSL and its driver are their own chunk: the opening screen exists to be on
 * screen before anything else has loaded, and the mark has no business in the
 * bytes it waits on. */
export function startOpeningMark(): void {
	if (typeof document === "undefined") return;
	const box = document.querySelector<HTMLElement>("#boot .boot-mark");
	if (box === null) return;
	openingMark = import("./mark_gpu_live.ts").then((m) => m.start(box, "loop")).then((mark) => {
		// The screen may already be gone by the time a device arrives.
		if (mark !== null && (!box.isConnected || handedOver())) {
			mark.stop();
			return null;
		}
		return mark;
	}).catch(() => {
		// best-effort: a chunk that will not load is an opening screen with an
		// empty box where its mark would be, and nothing else about the page
		// turns on that.
		return null;
	});
}

export function handOffNow(): void {
	if (handedOver()) return;
	void openingMark.then((mark) => mark?.stop());
	openingMark = Promise.resolve(null);
	stopBootAsides();
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

/** Run `fn` once the mark has assembled at least once.
 *
 * On a fast network the peer can answer before the lantern has lit, and a
 * screen that vanishes mid-play reads as a glitch, not a mark. The mark owns
 * its own play, so it is the one that says when a play has assembled: its
 * `assembled` settles at that beat, at once for a reader who asked for less
 * motion, and a browser with no mark to draw has nothing to wait through. */
function onceAssembled(fn: () => void): void {
	void openingMark.then((mark) => mark === null ? fn() : mark.assembled.then(fn));
}

/** Hold the screen until the controller has answered and the mark has
 * assembled once, then hand over. An attached controller answers with
 * its complete initial snapshot; unlike local reconstruction, that snapshot
 * may correctly contain no directory whose attempt could settle the store.
 *
 * The entry module calls this last to move the page out of the opening state
 * stamped by page.html, and therefore out of the reach of its watcher:
 * an error before this point is a page that never started and gets the
 * explanation, and an error after it belongs to the running page. */
export function handOffWhenReady(
	projection: PageProjection,
	readiness: RoomsOpeningReadiness,
	readyWithoutDirectory?: Promise<void>,
): void {
	if (handedOver()) return;
	document.documentElement.dataset.boot = RUNNING;
	if (readiness === "controller-snapshot" || settled(projection)) return onceAssembled(handOffNow);
	let finishing = false;
	let stop = () => {};
	const finish = () => {
		if (finishing) return;
		finishing = true;
		stop();
		onceAssembled(handOffNow);
	};
	stop = projection.subscribe(() => {
		if (!settled(projection)) return;
		finish();
	});
	void readyWithoutDirectory?.then(() => {
		if (projection.get().dirs.size === 0) finish();
	});
}
