/**
 * The one channel between the stage camera and the controls that drive it.
 *
 * The camera itself lives inside `use-stage-scene.ts`, in a pixi-viewport the React tree
 * does not own. Two things have to cross that boundary and they run in opposite
 * directions, which is why they are here together rather than as props: the
 * controls send commands down, and the readout reads the scale back up.
 *
 * # Why the readout is not React state
 *
 * A wheel gesture changes the scale on every frame. Publishing that as state
 * would re-render on every frame of every zoom, and the app has no other reason
 * to re-render then. So the scale is published here and subscribers are woken
 * only when something they can SHOW has changed, the formatted
 * percentage, or whether stepping out would still move. A gesture that walks
 * 100% to 40% wakes them a handful of times instead of sixty times a second.
 *
 * That is also why the snapshot carries no raw `zoom`. A number that is only
 * refreshed when its own formatting changes is a stale number, and putting one
 * here would invite a caller to do arithmetic with it. Whoever needs the live
 * scale asks `readView`, which goes to the camera itself, the zoom field's scrub
 * gesture does exactly that, so its arithmetic starts from the true scale rather
 * than from whatever the last render happened to see.
 */

import {
	canStepIn,
	canStepOut,
	DEFAULT_STAGE_VIEW,
	formatStageZoom,
	sameStageView,
	type StageView,
} from "./stage-view.ts";

/** What a control can ask of the camera.
 *
 *  `zoom-in` / `zoom-out` step about the viewport's CENTRE, unlike the wheel,
 *  which steps about the cursor: a button has no cursor position to speak of,
 *  and a reader pressing it is looking at the middle of the picture. */
export type StageCameraCommand =
	| { kind: "zoom-in" }
	| { kind: "zoom-out" }
	/** An absolute scale, from the zoom field. About the viewport's center, like
	 *  the steps and unlike the wheel. */
	| { kind: "zoom-to"; zoom: number }
	/** A scale AND a center together, put the camera exactly here.
	 *
	 *  Distinct from `zoom-to`, which holds the center it has. This is for going to
	 *  a view somebody else named: the document panel's Opens-at row sends the view
	 *  the document stores, so its ✕ abandons a pending change by putting the camera
	 *  back where the document opens. */
	| { kind: "go-to"; view: StageView }
	| { kind: "fit" }
	/** The middle of the world at 1:1. Not "the view this document opens at":
	 *  looking around writes that, so it is wherever the reader is and going
	 *  back to it would do nothing (`render/stage-view.ts`). */
	| { kind: "home" };

/**
 * The camera, as everything outside it may use it: it takes commands, and it can
 * be asked where it is.
 *
 * One port rather than a channel per direction. The two are the same object's two
 * halves, a camera that can be driven can also be read, and splitting them
 * meant a consumer could attach one and forget the other, which is a camera that
 * answers commands and cannot say where it ended up.
 */
export type StageCameraPort = {
	run(command: StageCameraCommand): void;
	/** Where the camera is. Read rather than published, because the one caller
	 *  is an act the reader just asked for, and a value pushed every frame would be
	 *  a per-frame allocation nobody reads in between. */
	view(): StageView;
};

/** Everything the controls can display. */
export type StageCameraReadout = {
	/** The scale as a person reads it, e.g. `"40%"`.
	 *
	 *  The field renders the live scale through the same formatter rather than this
	 *  string, so what this is FOR is deciding when to wake: it is the coarsest
	 *  thing on screen that follows the scale, so a change to it means the reader
	 *  can see a difference and no change means they cannot. */
	label: string;
	/** Whether a step out would move the camera at all. */
	canZoomOut: boolean;
	/** And in. Both ends of the scale grey their own button. */
	canZoomIn: boolean;
	/**
	 * Where the camera came to rest, the last time it did.
	 *
	 * The one place a raw view belongs in this snapshot, and it is here because
	 * something outside the stage has to compare against it: the document panel's
	 * Opens-at row offers to record this view, and can only know whether there is
	 * anything to record by looking at it.
	 *
	 * It is safe to publish where a live scale would not be, because it changes once
	 * per gesture rather than once per frame. The stage waits for the camera to
	 * stop before it says so. A reader who pans for two seconds wakes this once.
	 */
	settled: StageView;
};

const INITIAL: StageCameraReadout = {
	label: formatStageZoom(1),
	canZoomOut: canStepOut(1),
	canZoomIn: canStepIn(1),
	settled: DEFAULT_STAGE_VIEW,
};

/** How long the camera must sit still before a look-around is a rest.
 *
 *  A quarter second is past the end of a scroll's inertia and under the time
 *  it takes to look. Tests that wait for a settle read this rather than
 *  restating it. */
export const VIEW_SETTLE_MS = 250;

/**
 * A live camera and the readout of it. One instance per app, and `stageCamera` below
 * is it. Exported as a class so a test can drive one without touching the
 * module-level instance.
 */
export class StageCamera {
	#readout: StageCameraReadout = INITIAL;
	/** The scale the held readout was built from.
	 *
	 *  The readout is derived from the scale and nothing else, so an unchanged
	 *  scale cannot change it, and the stage calls in once per frame whether or
	 *  not the camera moved. Comparing the number first is what makes a still
	 *  camera free: without it, every frame formatted a percentage string and built
	 *  a readout object in order to discover that both matched the ones it already
	 *  held, and threw them away. */
	#zoom = 1;
	#listeners = new Set<() => void>();
	/** Set by whoever owns the viewport, cleared when it goes away. A command that
	 *  arrives with no camera attached is dropped: the stage is mid-teardown or
	 *  has not built its viewport yet, and there is nothing to move.  status-allow: pending state or quoted runtime label */
	#port: StageCameraPort | null = null;
	/** The wait for the camera to stop moving, and the view that wait is for.
	 *  Restarted on every moved frame so a stream of pans collapses into one
	 *  report after the last of them. Cleared when the viewport detaches, so a
	 *  stage rebuilt around a replaced buffer does not inherit the previous
	 *  wait. */
	#pendingSettle: { timer: number; view: StageView } | null = null;

	/** Subscribe to readout changes. `useSyncExternalStore`-shaped. */
	subscribe = (onChange: () => void): () => void => {
		this.#listeners.add(onChange);
		return () => {
			this.#listeners.delete(onChange);
		};
	};

	/** The current readout. Referentially stable until it changes, which
	 *  is what lets `useSyncExternalStore` skip a render. */
	getReadout = (): StageCameraReadout => this.#readout;

	/**
	 * Where the camera last came to rest, on its own.
	 *
	 * The Opens-at row wants this and nothing else, and a subscriber is woken by
	 * every change to the readout, including the percentage, which moves on most
	 * frames of a zoom. Handing that row this reference instead of the whole
	 * readout is what keeps a zoom gesture from re-rendering it at the frame rate:
	 * `useSyncExternalStore` compares the snapshot it is given, and this one only
	 * changes when the camera settles somewhere new.
	 */
	getSettledView = (): StageView => this.#readout.settled;

	/**
	 * Tell the store the current scale. Called freely (once per frame is
	 * expected) because it compares before it does anything.
	 */
	publishZoom(zoom: number): void {
		// The scale itself, before any of the work of describing it: see `#zoom`.
		if (zoom === this.#zoom) return;
		this.#zoom = zoom;
		const held = this.#readout;
		const next: StageCameraReadout = {
			label: formatStageZoom(zoom),
			canZoomOut: canStepOut(zoom),
			canZoomIn: canStepIn(zoom),
			// Carried through untouched: this call is about the scale, and the settled
			// view is a different fact with a different pace.
			settled: held.settled,
		};
		if (
			next.label === held.label && next.canZoomOut === held.canZoomOut &&
			next.canZoomIn === held.canZoomIn
		) {
			return;
		}
		this.#readout = next;
		for (const listener of this.#listeners) listener();
	}

	/**
	 * Say where the camera came to rest.
	 *
	 * Called once per rest, after {@link noteViewWhenSettled} has waited for
	 * the camera to stop. Unconditional where `publishZoom` compares first,
	 * because the caller has already established that the view moved, and the
	 * comparison it would make is the one thing this snapshot exists to let somebody
	 * else make.
	 */
	publishSettledView(view: StageView): void {
		const held = this.#readout;
		if (sameStageView(view, held.settled)) return;
		this.#readout = { ...held, settled: view };
		for (const listener of this.#listeners) listener();
	}

	/**
	 * Say where the camera came to rest, once it has stopped moving.
	 *
	 * Each call restarts the wait, so a stream of frames collapses into one
	 * report after the last of them. Nothing is lost if the reader keeps moving:
	 * the view reported is always the latest one seen.
	 *
	 * It reports rather than writes. Looking around is reading, so it changes
	 * no document and records no history, what it does is let the document
	 * panel offer: the Opens-at row's button compares this against what the
	 * document stores and lights up when they differ. The settle is what makes
	 * that cheap enough to publish at all, since it turns sixty frames of a
	 * pan into one wake.
	 *
	 * Three numbers rather than the view they describe, because this is called
	 * on every frame and the common answer is "nothing moved". Building the
	 * view to compare it would allocate one object and one center per frame of
	 * a still stage, to throw both away.
	 *
	 * A still camera republishes the same numbers every frame. Restarting the
	 * timer for those would mean the write never lands.
	 */
	noteViewWhenSettled(zoom: number, centerX: number, centerY: number): void {
		const pending = this.#pendingSettle;
		if (
			pending && pending.view.zoom === zoom &&
			pending.view.center.x === centerX &&
			pending.view.center.y === centerY
		) {
			return;
		}
		if (pending) clearTimeout(pending.timer);
		const view = { zoom, center: { x: centerX, y: centerY } };
		const timer = setTimeout(() => {
			this.#pendingSettle = null;
			this.publishSettledView(view);
		}, VIEW_SETTLE_MS);
		this.#pendingSettle = { timer, view };
	}

	#clearSettle(): void {
		if (!this.#pendingSettle) return;
		clearTimeout(this.#pendingSettle.timer);
		this.#pendingSettle = null;
	}

	/** Attach the camera. Returns the detach, so the owner's cleanup is one call
	 *  and a late detach cannot unhook a camera that replaced this one. */
	attach(port: StageCameraPort): () => void {
		this.#clearSettle();
		this.#port = port;
		return () => {
			if (this.#port !== port) return;
			this.#port = null;
			this.#clearSettle();
		};
	}

	/** Ask the camera to move. Silently does nothing when nothing is attached. */
	send(command: StageCameraCommand): void {
		this.#port?.run(command);
	}

	/** Where the camera is, or null when there is no stage to ask. The caller is
	 *  an explicit act, so null means "there was nothing to save" rather than a
	 *  value worth substituting a default for. */
	readView(): StageView | null {
		return this.#port?.view() ?? null;
	}
}

export const stageCamera = new StageCamera();
