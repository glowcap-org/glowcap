/**
 * Gesture router, cross-surface mutual exclusion.
 *
 * Problem: in a multi-surface app (Stage + Timeline + UI chrome),
 * an interaction that starts on one surface MUST NOT bleed into a
 * concurrent interaction on another. With `setPointerCapture` the
 * native pointer stream is already pinned to one element, but
 * surfaces with ad-hoc handlers, multi-touch, and synthetic React
 * delegation can still cross-pollinate.
 *
 * Solution: one process-wide `GestureRouter`. A surface takes a
 * `SurfaceLease` from it and claims through that lease when a
 * gesture starts. The lock persists until the lease releases. A
 * capture-phase listener on `document` watches `pointerdown`, if
 * the event hits a surface other than the active claimant,
 * propagation is stopped before any handler downstream can react.
 * `preventDefault` is NEVER called: text-selection, native scroll,
 * focus changes, and the OS context menu still work.
 *
 * A held lock that nobody gives back freezes every other surface
 * in the app, so the lease is the only way to take one and its
 * `release` is the only way back to a free router: `GestureRouter`
 * has no public claim of its own. `useGestureSurface` is what
 * holds a lease in React and releases it when the surface leaves
 * the tree.
 *
 * A modal is the one claimant that is not dragging anything. It
 * holds the lock for as long as it is up, through
 * `holdPointerForModal`, because "which surface may be pressed
 * right now" is the same question for a dialog as for a drag.
 *
 * Tags are opaque strings. Convention is one tag per logical
 * surface ("stage", "timeline", "ui-resize", ...). The router
 * compares by string equality. It does not interpret hierarchy.
 * A tag names a KIND of surface, not an instance, two scrub
 * inputs share one tag, so a tag can never stand in for the
 * proof that a particular claimant holds the lock. That proof is
 * the granted `ActiveGesture` object itself, which lives inside
 * the lease that was granted it and is compared by identity.
 *
 * No React, no Pixi. Trivially unit-testable.
 */

export type SurfaceTag = string;

/** A granted claim. Identity is the proof: the router drops the
 *  lock only when handed back the exact object it granted, so a
 *  surface cannot end a gesture it did not start, not even
 *  another instance of its own kind, which the tag alone cannot
 *  tell apart. */
export type ActiveGesture = {
	readonly tag: SurfaceTag;
	readonly pointerId: number;
};

// `data-pointer-surface=<tag>` marks an element as owning a
// surface. `composedPath()` walking finds the nearest such
// ancestor; that ancestor's tag determines which surface the
// event "belongs to."
const SURFACE_DATASET_KEY = "pointerSurface";

// Lease-only entry points. The symbols are module-private, so
// `SurfaceLease` below is the only code that can reach them and a
// surface cannot take the lock without holding a lease that knows
// how to give it back.
const GRANT: unique symbol = Symbol("gesture-router.grant");
const REVOKE: unique symbol = Symbol("gesture-router.revoke");

export class GestureRouter {
	#active: ActiveGesture | null = null;
	#listeners = new Set<(active: ActiveGesture | null) => void>();
	#registered = new Set<HTMLElement>();

	/** Mark `element` as owning surface `tag`. Returns an
	 *  unregister fn, call on unmount. Multiple calls with
	 *  different tags on the same element overwrite. */
	register(element: HTMLElement, tag: SurfaceTag): () => void {
		element.dataset[SURFACE_DATASET_KEY] = tag;
		this.#registered.add(element);
		return () => {
			this.#registered.delete(element);
			// Only clear if we still own the attribute (another caller
			// may have re-tagged the same element).
			if (element.dataset[SURFACE_DATASET_KEY] === tag) {
				delete element.dataset[SURFACE_DATASET_KEY];
			}
		};
	}

	/** Walk `event.composedPath()` for the deepest registered
	 *  surface ancestor. Returns its tag, or `null` if no
	 *  registered surface owns the target. */
	surfaceFor(event: Event): SurfaceTag | null {
		for (const node of event.composedPath()) {
			if (!(node instanceof HTMLElement)) continue;
			const tag = node.dataset[SURFACE_DATASET_KEY];
			if (tag) return tag;
		}
		return null;
	}

	/** Take a lease for surface `tag`. This is the only route to
	 *  the gesture lock, see `SurfaceLease`. One lease per surface
	 *  instance, held for that instance's lifetime. */
	lease(tag: SurfaceTag): SurfaceLease {
		return new SurfaceLease(this, tag);
	}

	current(): ActiveGesture | null {
		return this.#active;
	}

	subscribe(fn: (active: ActiveGesture | null) => void): () => void {
		this.#listeners.add(fn);
		return () => {
			this.#listeners.delete(fn);
		};
	}

	/** Test seam, drop every registration and the active lock. */
	reset(): void {
		for (const el of this.#registered) {
			if (el.dataset[SURFACE_DATASET_KEY] !== undefined) {
				delete el.dataset[SURFACE_DATASET_KEY];
			}
		}
		this.#registered.clear();
		this.#active = null;
		this.#listeners.clear();
	}

	/** Grant the lock when it is free. Refused while ANY claim is
	 *  live, including one held by another instance of the same
	 *  tag: two surfaces of one kind are still two surfaces. */
	[GRANT](tag: SurfaceTag, pointerId: number): ActiveGesture | null {
		if (this.#active !== null) return null;
		this.#active = { tag, pointerId };
		this.#notify();
		return this.#active;
	}

	/** Drop the lock iff `claim` is the object granted. */
	[REVOKE](claim: ActiveGesture): void {
		if (this.#active !== claim) return;
		this.#active = null;
		this.#notify();
	}

	#notify(): void {
		for (const fn of this.#listeners) fn(this.#active);
	}
}

/**
 * One surface's whole relationship with the router: the element
 * tag the root guard reads, and the claim on the lock. Both are
 * taken by `claim` at pointer-down and both are given back by
 * `release`.
 *
 * The lease keeps the granted `ActiveGesture` private, so nothing
 * outside it can end this surface's gesture and nothing inside it
 * can end anyone else's. Take one through `GestureRouter.lease`.
 */
export class SurfaceLease {
	readonly tag: SurfaceTag;
	#router: GestureRouter;
	#claim: ActiveGesture | null = null;
	#unregister: (() => void) | null = null;

	constructor(router: GestureRouter, tag: SurfaceTag) {
		this.#router = router;
		this.tag = tag;
	}

	/** Take the gesture lock and mark `element` as this surface for
	 *  the root guard. `false` when a claim is already live, on
	 *  another surface, or on another instance of this one, and
	 *  then `element` is left untagged, which is what the guard
	 *  should see: this surface is not the one driving. */
	claim(element: HTMLElement, pointerId: number): boolean {
		const granted = this.#router[GRANT](this.tag, pointerId);
		if (granted === null) return false;
		this.#unregister?.();
		this.#unregister = this.#router.register(element, this.tag);
		this.#claim = granted;
		return true;
	}

	/** The pointer this surface's live claim was granted to, or
	 *  `null` when it holds none. The single answer to "is a drag
	 *  in progress on this surface". A handler that keeps its own
	 *  second copy of that fact will disagree with this one. */
	pointer(): number | null {
		return this.#claim?.pointerId ?? null;
	}

	/** Give the lock and the element tag back. Idempotent. With
	 *  `pointerId`, ignored unless the live claim was granted to
	 *  that pointer, so a second finger's release cannot end the
	 *  first finger's gesture. */
	release(pointerId?: number): void {
		const claim = this.#claim;
		if (claim === null) return;
		if (pointerId !== undefined && claim.pointerId !== pointerId) return;
		this.#claim = null;
		this.#unregister?.();
		this.#unregister = null;
		this.#router[REVOKE](claim);
	}
}

/** Single process-wide router. Surfaces and the root guard share
 *  this instance. Tests can construct a fresh `GestureRouter`
 *  directly and pass it to `installRootGuard` for isolation. */
export const gestureRouter = new GestureRouter();

// ─────────────────────── Root guard ────────────────────────────────────

const guardedDocs = new WeakSet<Document>();

/** Install a capture-phase `pointerdown` listener on `doc`. While
 *  a gesture is active, the listener stops propagation of any
 *  pointer-down whose target lies on a foreign surface (different
 *  tag from the active claimant, or unregistered). Idempotent per
 *  document. Subsequent calls return the original uninstaller. */
export function installRootGuard(
	doc: Document = globalThis.document,
	router: GestureRouter = gestureRouter,
): () => void {
	if (guardedDocs.has(doc)) return () => {};
	guardedDocs.add(doc);

	const onPointerDown = (ev: PointerEvent) => {
		const active = router.current();
		if (active === null) return;
		const tag = router.surfaceFor(ev);
		if (tag !== null && tag === active.tag) return;
		// Foreign surface (or untagged target) during an active
		// gesture. Stop propagation so no downstream handler reacts;
		// never preventDefault (would kill native focus/scroll/text
		// selection on benign clicks elsewhere on the page).
		ev.stopPropagation();
		ev.stopImmediatePropagation();
	};

	doc.addEventListener("pointerdown", onPointerDown, { capture: true });
	return () => {
		doc.removeEventListener("pointerdown", onPointerDown, {
			capture: true,
		});
		guardedDocs.delete(doc);
	};
}

// ─────────────────────── Modal hold ────────────────────────────────────

/** The surface a modal owns. One tag for every modal, because the guard asks
 *  which KIND of surface a press belongs to, and a modal opened over another
 *  one is still a press on a modal. */
export const MODAL_SURFACE_TAG: SurfaceTag = "modal";

/** The pointer behind a modal's claim. A modal is not a drag, so there is no
 *  real one, and `-1` is a value no pointer event carries, so no stray
 *  pointer-up can be read as the end of this claim. */
const MODAL_POINTER = -1;

/** What holding the pointer for a modal needs of a window: the blur every
 *  gesture watch already treats as its interruption. */
export type ModalHoldSource = {
	dispatchEvent(event: Event): unknown;
};

/**
 * Take the pointer for something modal, and give it back.
 *
 * A modal owns input while it is up. For pointers that promise is already
 * decided in one place, the root guard, which passes a press only when it
 * lands on the surface holding the lock. So a modal takes the same claim, for
 * as long as it is up rather than for the length of a drag, and `element` is
 * the surface it holds: a press inside reaches the modal's own handlers and
 * every press outside stops at the guard. Nothing else can start a gesture
 * meanwhile, because a claim is refused while one is live.
 *
 * A gesture already in flight would refuse this claim, and its surface is
 * behind the modal where the person can no longer reach it, so it is ended status-allow: lifecycle transition
 * first. A window blur is the interruption every gesture watch already
 * listens for, so this dispatches one rather than spelling a second way to
 * interrupt.
 *
 * The element is tagged whether or not the claim was granted, so a modal
 * opened over one that already holds the lock is still a surface the guard
 * passes.
 *
 * Returns the release. It is the whole teardown, so a React effect returns
 * it and the take cannot be dropped without the release going with it.
 */
export function holdPointerForModal(
	element: HTMLElement,
	router: GestureRouter = gestureRouter,
	source: ModalHoldSource = globalThis,
): () => void {
	source.dispatchEvent(new Event("blur"));
	const lease = router.lease(MODAL_SURFACE_TAG);
	const claimed = lease.claim(element, MODAL_POINTER);
	const unregister = claimed ? null : router.register(element, MODAL_SURFACE_TAG);
	return () => {
		unregister?.();
		lease.release();
	};
}

// ─────────────────────── Gesture-end watch ─────────────────────────────

/**
 * How a gesture ended, for a surface that could not see it end.
 *
 * `finished`, the reader let go. A `pointerup` delivered over other chrome or
 * off the document, a capture loss, or a move that arrived with no button held
 * because the up went missing. The gesture ran its course, so whatever it had in
 * flight is what the reader meant by it.
 *
 * It says the reader finished rather than that anything was committed, because
 * committing is the surface's call and not always yes: a press that never
 * crossed the drag threshold finishes and still commits nothing, since there was
 * never anything in flight to commit.
 *
 * `cancelled`, the gesture was taken away. The system claimed the pointer, the
 * window lost focus, or the surface left the tree mid-drag. Nobody finished
 * anything, and there is nothing to commit.
 *
 * The two are told apart HERE because this is the only place that knows which
 * event arrived. A surface handed one undifferentiated "it ended" has to guess
 * from its own state, and the guess is wrong for exactly the cancellations: a
 * marquee would commit a selection the system interrupted, and it would do it
 * invisibly, because the shape of a taken-away gesture is otherwise identical
 * to a release.
 *
 * A surface with nothing to revert may ignore this and end the same way for
 * both. A scrub input has already applied every value it passed through, so its
 * whole teardown is closing the brackets it opened. Only a surface that holds
 * something back until the release has a decision to make.
 */
export type GestureEndReason = "finished" | "cancelled";

/** What `watchGestureEnd` needs of a window. Narrow so a test can
 *  hand it a stand-in. */
export type GestureEndSource = {
	addEventListener(
		type: string,
		listener: (ev: Event) => void,
		options?: { capture?: boolean },
	): void;
	removeEventListener(
		type: string,
		listener: (ev: Event) => void,
		options?: { capture?: boolean },
	): void;
};

/**
 * Watch `source` for the ends of a gesture that `lease`'s own
 * element never sees: a release over OS chrome or off-document, a
 * capture loss, a window blur, and a move that arrives with no
 * primary button held (the pointer-up went missing). Each of them
 * calls `onEnd` so the surface tears down its own drag state, then
 * releases the lease.
 *
 * `onEnd` is told WHICH of those happened, as a `GestureEndReason`,
 * because a release and a cancellation are the same event stream to
 * everyone downstream and only this function can still tell them
 * apart.
 *
 * The surface leaving the tree is one more of them, and it is the
 * one no handler on the element can ever report, because React has
 * already detached them. So the returned disposer ends a held
 * gesture exactly as the watch does before it stops watching: the
 * lock coming back is not the gesture ending, and a surface that
 * hears only the first leaves its own drag standing. That standing
 * drag is what a host feels, the scrub input that never fires
 * `onScrubEnd` leaves the edit transaction it opened at drag start
 * open, and the engine records history only at depth zero, so from
 * that moment nothing in the app is undoable. Every surface here
 * ends the same way for the same reason, which is why the disposer
 * says it once instead of five hosts each remembering to.
 *
 * The disposer is therefore the entire teardown a React effect
 * needs, see `useGestureSurface`, whose effect returns it.
 *
 * The phantom-move watch listens in the capture phase and the ends
 * in the bubble phase, and the difference is load-bearing. A
 * phantom move must be recognized BEFORE the surface's own move
 * handler acts on it, or the surface reads a drag that is already
 * over and emits one bogus value. A pointer-up must arrive AFTER
 * the surface's own up handler, which is where a click that never
 * became a drag decides what it was instead.
 */
export function watchGestureEnd(
	lease: SurfaceLease,
	onEnd: (reason: GestureEndReason) => void,
	source: GestureEndSource = globalThis as unknown as GestureEndSource,
): () => void {
	const end = (reason: GestureEndReason) => {
		onEnd(reason);
		lease.release();
	};
	const pointerOf = (ev: Event) => (ev as unknown as { pointerId?: number }).pointerId;
	const buttonsOf = (ev: Event) => (ev as unknown as { buttons?: number }).buttons ?? 0;

	// Only the pointer this surface actually holds ends its gesture;
	// another pointer's stream is not ours to read.
	const endedBy = (reason: GestureEndReason) => (ev: Event) => {
		if (lease.pointer() !== pointerOf(ev)) return;
		end(reason);
	};
	// A capture loss is filed with the releases: on an ordinary release it
	// arrives right behind the pointer-up, and when it arrives alone the pointer
	// is gone for good, which is the reader having let go somewhere this window
	// could not see either.
	const onUp = endedBy("finished");
	const onLostCapture = endedBy("finished");
	const onCancel = endedBy("cancelled");
	const onMove = (ev: Event) => {
		if (lease.pointer() !== pointerOf(ev)) return;
		if ((buttonsOf(ev) & 1) !== 0) return;
		// The button is up, so the release already happened; this move is only how
		// we found out.
		end("finished");
	};
	// Focus went elsewhere mid-drag, so the reader is no longer driving this status-allow: lifecycle transition
	// gesture and never ended it.
	const onBlur = () => {
		if (lease.pointer() === null) return;
		end("cancelled");
	};

	source.addEventListener("pointerup", onUp);
	source.addEventListener("pointercancel", onCancel);
	source.addEventListener("lostpointercapture", onLostCapture);
	source.addEventListener("pointermove", onMove, { capture: true });
	source.addEventListener("blur", onBlur);
	return () => {
		source.removeEventListener("pointerup", onUp);
		source.removeEventListener("pointercancel", onCancel);
		source.removeEventListener("lostpointercapture", onLostCapture);
		source.removeEventListener("pointermove", onMove, { capture: true });
		source.removeEventListener("blur", onBlur);
		// A held claim means a gesture is still in flight, so the surface
		// hears the same cancellation a blur would have given it, the
		// surface is going away under the pointer, which is as far from a
		// reader finishing a gesture as this watch ever gets. With none
		// held there is nothing to interrupt and `release` is
		// already a no-op, which is what keeps a surface that holds
		// nothing from ending someone else's gesture.
		onBlur();
		lease.release();
	};
}
