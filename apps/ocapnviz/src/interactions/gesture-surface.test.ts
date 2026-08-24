/**
 * `watchGestureEnd` — the teardown every gesture surface shares.
 *
 * What these tests pin: the disposer a React effect returns
 * releases the lease, so a surface removed mid-drag cannot strand
 * the router's lock; the window watch ends a gesture on the paths
 * the surface's own element never sees; and each of those paths is
 * reported as a release or a cancellation, which is the one thing
 * about them no surface downstream can work out for itself.
 *
 * What they do NOT pin: anything React runs. Deno has no DOM, so
 * nothing here mounts a component, and two links are covered only
 * by a browser. One is the single
 * `useEffect(() => watchGestureEnd(...), [lease])` in
 * `use-gesture-surface.ts`, which a real `ScrubInput` inside a list
 * that drops its row mid-drag exercises. The other is each
 * surface's own end callback, which is how the news reaches the
 * surface's state: the lock coming back is not the gesture ending,
 * and a surface that hears only the first leaves a drag standing in
 * its own machine.
 */

import { assertEquals } from "@std/assert";
import { type GestureEndReason, GestureRouter, watchGestureEnd } from "./gesture-router.ts";

class FakeElement {
	dataset: Record<string, string> = {};
}

const anElement = () => new FakeElement() as unknown as HTMLElement;

/** Stand-in for `window`: records listeners by type and phase so a
 *  test can fire one the way the browser would. */
class FakeWindow {
	#byKey = new Map<string, Set<(ev: Event) => void>>();

	addEventListener(
		type: string,
		listener: (ev: Event) => void,
		options?: { capture?: boolean },
	): void {
		const key = `${type}:${options?.capture ? "capture" : "bubble"}`;
		const set = this.#byKey.get(key) ?? new Set();
		set.add(listener);
		this.#byKey.set(key, set);
	}

	removeEventListener(
		type: string,
		listener: (ev: Event) => void,
		options?: { capture?: boolean },
	): void {
		const key = `${type}:${options?.capture ? "capture" : "bubble"}`;
		this.#byKey.get(key)?.delete(listener);
	}

	fire(type: string, ev: Record<string, unknown> = {}): void {
		// Capture runs before bubble, as it does in the DOM.
		for (const phase of ["capture", "bubble"]) {
			const set = this.#byKey.get(`${type}:${phase}`);
			if (!set) continue;
			for (const fn of [...set]) fn(ev as unknown as Event);
		}
	}

	/** How many listeners are still attached, in every phase. */
	count(): number {
		let n = 0;
		for (const set of this.#byKey.values()) n += set.size;
		return n;
	}

	/** Which phase `type` is watched in. */
	phaseOf(type: string): "capture" | "bubble" | null {
		if (this.#byKey.get(`${type}:capture`)?.size) return "capture";
		if (this.#byKey.get(`${type}:bubble`)?.size) return "bubble";
		return null;
	}
}

function surfaceUnderTest(tag = "ui-scrub-input") {
	const router = new GestureRouter();
	const lease = router.lease(tag);
	const win = new FakeWindow();
	/** Every end this surface was told about, in order, with the reason. */
	const interrupted: GestureEndReason[] = [];
	const dispose = watchGestureEnd(
		lease,
		(reason) => interrupted.push(reason),
		win,
	);
	return { router, lease, win, interrupted, dispose };
}

Deno.test("unmount mid-drag releases the lock", () => {
	// The freeze: a scrub input inside a list starts a drag, its row
	// is dropped, and React detaches the handlers that would have
	// released. The effect cleanup is the release that survives that.
	const { router, lease, dispose } = surfaceUnderTest();
	assertEquals(lease.claim(anElement(), 1), true);
	assertEquals(router.current()?.tag, "ui-scrub-input");

	dispose();

	assertEquals(router.current(), null);
	// And the surface that the freeze locked out can go again.
	assertEquals(router.lease("stage").claim(anElement(), 2), true);
});

Deno.test("unmount mid-drag ends the surface's own gesture too", () => {
	// The lock coming back is not the gesture ending. A surface that
	// hears only the release leaves its own drag standing: the scrub
	// input never fires `onScrubEnd`, so the edit transaction it opened
	// at drag start stays open, and the engine records history only at
	// depth zero. From that moment nothing in the app is undoable.
	const { lease, interrupted, dispose } = surfaceUnderTest();
	lease.claim(anElement(), 1);
	dispose();
	// Cancelled, not released: the surface is going away under the pointer, which
	// is the reader having finished nothing.
	assertEquals(interrupted, ["cancelled"]);
});

Deno.test("unmount with no gesture in flight releases nothing", () => {
	const { router, lease, interrupted, dispose } = surfaceUnderTest();
	const stage = router.lease("stage");
	stage.claim(anElement(), 1);
	// This surface holds nothing, so its teardown must not end the
	// gesture someone else is driving, and must not tell its own
	// surface a drag ended that never started — an idle resize handle
	// leaving the tree would otherwise flush a delta nobody dragged.
	assertEquals(lease.pointer(), null);
	dispose();
	assertEquals(router.current()?.tag, "stage");
	assertEquals(interrupted.length, 0);
});

Deno.test("unmount detaches every listener it attached", () => {
	const { win, dispose } = surfaceUnderTest();
	assertEquals(win.count(), 5);
	dispose();
	assertEquals(win.count(), 0);
});

Deno.test("the move watch captures and the end watch bubbles", () => {
	// Load-bearing, and invisible at any single call site. A phantom
	// move must be recognized BEFORE the surface's own move handler
	// reads a drag that is already over; a pointer-up must arrive
	// AFTER the surface's own up handler, which is where a click
	// that never became a drag decides what it was instead.
	const { win } = surfaceUnderTest();
	assertEquals(win.phaseOf("pointermove"), "capture");
	assertEquals(win.phaseOf("pointerup"), "bubble");
	assertEquals(win.phaseOf("pointercancel"), "bubble");
	assertEquals(win.phaseOf("lostpointercapture"), "bubble");
});

Deno.test("a move with no button held ends the gesture", () => {
	// The pointer-up went missing (released over OS chrome). The
	// watch listens in the capture phase, so it ends the drag before
	// the surface's own move handler can act on a gesture that is
	// already over.
	const { router, lease, win, interrupted } = surfaceUnderTest();
	lease.claim(anElement(), 1);
	win.fire("pointermove", { pointerId: 1, buttons: 1 });
	assertEquals(interrupted.length, 0, "a held drag keeps going");
	win.fire("pointermove", { pointerId: 1, buttons: 0 });
	assertEquals(interrupted.length, 1);
	assertEquals(router.current(), null);
});

Deno.test("another pointer's stream does not end this gesture", () => {
	const { router, lease, win, interrupted } = surfaceUnderTest();
	lease.claim(anElement(), 1);
	win.fire("pointermove", { pointerId: 2, buttons: 0 });
	win.fire("pointerup", { pointerId: 2 });
	win.fire("pointercancel", { pointerId: 2 });
	assertEquals(interrupted.length, 0);
	assertEquals(router.current()?.pointerId, 1);
	win.fire("pointerup", { pointerId: 1 });
	assertEquals(interrupted.length, 1);
	assertEquals(router.current(), null);
});

Deno.test("capture loss and pointer cancel end the gesture", () => {
	for (const type of ["lostpointercapture", "pointercancel"]) {
		const { router, lease, win, interrupted } = surfaceUnderTest();
		lease.claim(anElement(), 7);
		win.fire(type, { pointerId: 7 });
		assertEquals(interrupted.length, 1, type);
		assertEquals(router.current(), null, type);
	}
});

/**
 * Which end each event is, which is the half of the question only this watch can
 * answer.
 *
 * A surface downstream sees one call either way, and its own state looks the same
 * for both: a marquee interrupted at full stretch is `dragging` whether the reader
 * let go or the system took the pointer away. So a surface left to guess commits
 * the cancellations, and does it invisibly — there is no error, just a selection
 * the reader did not ask for. `use-surface-pointer.ts` asks this AND
 * `hasSomethingToCommit` (`pointer-machine-test/commit.test.ts`), and needs both.
 *
 * Validated by injection, one per row: filing `pointercancel` under `released`
 * fails that row, and so does filing `pointerup` under `cancelled`.
 */
Deno.test("each end says whether the reader let go", () => {
	const cases: ReadonlyArray<
		[type: string, ev: Record<string, unknown>, reason: GestureEndReason]
	> = [
		// The reader let go somewhere this surface could not see it.
		["pointerup", { pointerId: 4 }, "finished"],
		// The up went missing and this move is how we found out — the button is
		// already up, so the release has already happened.
		["pointermove", { pointerId: 4, buttons: 0 }, "finished"],
		// Alone, capture loss means the pointer is gone for good; behind a
		// pointerup it lands on a surface that has already committed.
		["lostpointercapture", { pointerId: 4 }, "finished"],
		// The system took the gesture back: a palm on a trackpad, a touch that
		// became a scroll. The reader never finished it.
		["pointercancel", { pointerId: 4 }, "cancelled"],
		// Focus went elsewhere mid-drag, so the reader is no longer driving.
		["blur", {}, "cancelled"],
	];
	for (const [type, ev, reason] of cases) {
		const { lease, win, interrupted } = surfaceUnderTest();
		lease.claim(anElement(), 4);
		win.fire(type, ev);
		assertEquals(interrupted, [reason], type);
	}
});

Deno.test("window blur ends a held gesture and nothing else", () => {
	const { router, lease, win, interrupted } = surfaceUnderTest();
	win.fire("blur");
	assertEquals(interrupted.length, 0, "idle blur is inert");
	lease.claim(anElement(), 3);
	win.fire("blur");
	assertEquals(interrupted.length, 1);
	assertEquals(router.current(), null);
});

Deno.test("a surface interrupted twice tears down once", () => {
	const { lease, win, interrupted } = surfaceUnderTest();
	lease.claim(anElement(), 1);
	win.fire("pointerup", { pointerId: 1 });
	win.fire("lostpointercapture", { pointerId: 1 });
	win.fire("blur");
	assertEquals(interrupted.length, 1);
});
