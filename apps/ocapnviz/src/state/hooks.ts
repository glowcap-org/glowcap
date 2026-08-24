/**
 * Custom hooks for App-level concerns. Each owns a slice of UI
 * state that isn't part of the reducer — typically because the
 * state is too high-frequency (theme toggle, layout drag) or
 * crosses concerns the reducer shouldn't (keyboard listeners,
 * `<html data-theme>` mirror).
 */

import { useCallback, useEffect, useRef, useState } from "react";
import type { StageVisibility } from "../render/types.ts";
import { CANVAS_ELEMENT_ID } from "../render/UnifiedCanvas.tsx";
import { isTextInputTarget } from "../interactions/text-input-target.ts";
import type { KeyboardShortcutBindings } from "./keyboard-shortcuts.ts";
import {
	type HeldGestureContext,
	type HeldGestures,
	NO_HELD_GESTURES,
	resolveBlur,
	resolveKeyDown,
	resolveKeyUp,
} from "./keyboard-input.ts";
import { Engine } from "../engine/engine.ts";
import type { TimelineDocument } from "../engine/timeline.ts";
import { dialLiveFeed, startLiveMode } from "../engine/live/mode.ts";
import type { LiveFeed } from "../engine/live/connection.ts";
import type { EngineError } from "../engine/errors.ts";
import { pushError } from "../ui/error/error-bus.ts";
import type { Theme } from "../ui/tokens.ts";
import {
	APP_STATE_STORAGE_KEY,
	type AppState,
	clampSizes,
	DEFAULT_SIZES,
	DEFAULT_VISIBILITY,
	type LayoutSizes,
	SIZES_STORAGE_KEY,
	THEME_STORAGE_KEY,
	VISIBILITY_STORAGE_KEY,
} from "./app-state.ts";

/** Pane sizes, persisted to localStorage. `set` accepts a partial
 * or an updater function; values are clamped to their min/max. */
export function useLayoutSizes(): [
	LayoutSizes,
	(updater: Partial<LayoutSizes> | ((s: LayoutSizes) => LayoutSizes)) => void,
	(override?: Partial<LayoutSizes>) => void,
] {
	const [sizes, setSizes] = useState<LayoutSizes>(() => {
		if (typeof globalThis.window === "undefined") return DEFAULT_SIZES;
		const raw = globalThis.localStorage?.getItem(SIZES_STORAGE_KEY);
		if (!raw) return DEFAULT_SIZES;
		try {
			const parsed = JSON.parse(raw) as Partial<LayoutSizes>;
			return clampSizes({ ...DEFAULT_SIZES, ...parsed });
		} catch {
			return DEFAULT_SIZES;
		}
	});
	useEffect(() => {
		globalThis.localStorage?.setItem(
			SIZES_STORAGE_KEY,
			JSON.stringify(sizes),
		);
	}, [sizes]);
	const update = useCallback(
		(
			updater:
				| Partial<LayoutSizes>
				| ((s: LayoutSizes) => LayoutSizes),
		) => {
			setSizes((s) => {
				const next = typeof updater === "function" ? updater(s) : { ...s, ...updater };
				return clampSizes(next);
			});
		},
		[],
	);
	// Wipes persisted entry too; reloading would otherwise restore
	// whatever bad state prompted the reset. An optional `override`
	// lets the caller substitute specific fields in the same commit
	// (e.g. "reset, but pin bottom pane to the current intrinsic")
	// so there's no flash from a default value paint followed by an
	// effect-driven re-pin on the next tick.
	const reset = useCallback((override?: Partial<LayoutSizes>) => {
		globalThis.localStorage?.removeItem(SIZES_STORAGE_KEY);
		setSizes(clampSizes({ ...DEFAULT_SIZES, ...override }));
	}, []);
	return [sizes, update, reset];
}

/** Per-layer Stage visibility, persisted. `toggle` flips one
 * layer; `reset` restores all-on. */
export function useStageVisibility(): [
	StageVisibility,
	(layer: keyof StageVisibility) => void,
	() => void,
] {
	const [visibility, setVisibility] = useState<StageVisibility>(() => {
		if (typeof globalThis.window === "undefined") return DEFAULT_VISIBILITY;
		const raw = globalThis.localStorage?.getItem(VISIBILITY_STORAGE_KEY);
		if (!raw) return DEFAULT_VISIBILITY;
		try {
			const parsed = JSON.parse(raw) as Partial<StageVisibility>;
			return { ...DEFAULT_VISIBILITY, ...parsed };
		} catch {
			return DEFAULT_VISIBILITY;
		}
	});
	useEffect(() => {
		globalThis.localStorage?.setItem(
			VISIBILITY_STORAGE_KEY,
			JSON.stringify(visibility),
		);
	}, [visibility]);
	const toggle = useCallback(
		(layer: keyof StageVisibility) => setVisibility((v) => ({ ...v, [layer]: !v[layer] })),
		[],
	);
	const reset = useCallback(() => {
		globalThis.localStorage?.removeItem(VISIBILITY_STORAGE_KEY);
		setVisibility(DEFAULT_VISIBILITY);
	}, []);
	return [visibility, toggle, reset];
}

/** Theme state, persisted and mirrored to `<html data-theme>` for
 * CSS custom-property switching. First-load follows
 * `prefers-color-scheme`. */
export function useTheme(): [Theme, () => void] {
	const [theme, setTheme] = useState<Theme>(() => {
		if (typeof globalThis.window === "undefined") return "light";
		const stored = globalThis.localStorage?.getItem(THEME_STORAGE_KEY);
		if (stored === "dark" || stored === "light") return stored;
		return globalThis.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
	});
	useEffect(() => {
		document.documentElement.dataset.theme = theme;
		globalThis.localStorage?.setItem(THEME_STORAGE_KEY, theme);
	}, [theme]);
	const toggle = useCallback(
		() => setTheme((t) => (t === "dark" ? "light" : "dark")),
		[],
	);
	return [theme, toggle];
}

// What each key means is decided by two data tables and one
// resolver, in `keyboard-input.ts` and `keyboard-shortcuts.ts`. The
// hooks below own the DOM and nothing else: they read facts off
// events, hand them to the resolver, and publish what comes back.

/** Where a view publishes its shortcut bindings for the keyboard
 *  listener to read. `null` until a view attaches. */
export type ShortcutSink = { current: KeyboardShortcutBindings | null };

/**
 * The app's one keyboard listener. Returns the gestures currently
 * held, and the sink a view publishes its shortcut bindings into.
 *
 * One listener, not one per concern, because precedence between
 * held gestures and one-shot commands has to be decided somewhere a
 * reader can check it. `resolveKeyDown` decides it in a function
 * body. Two listeners would decide it by whichever the browser
 * called first, which is not a contract anything can rely on.
 *
 * It watches keys only. What a press *became* once a gesture began
 * belongs to the pointer FSM, which is the only layer that knows,
 * and a reader that needs it asks `inFlightGesture` there.
 */
export function useKeyboardInput(
	ctx: HeldGestureContext,
): { held: HeldGestures; shortcuts: ShortcutSink } {
	const [held, setHeld] = useState<HeldGestures>(NO_HELD_GESTURES);
	// Refs, so the listener attaches ONCE for the component's
	// lifetime instead of re-running every render. The bindings and
	// context are fresh literals at the call site each render, so
	// depending on them would tear down and re-add the global
	// listeners on every state change — measurable during play, where
	// the engine notifies subscribers each tick and that propagates a
	// re-render up here.
	const ctxRef = useRef(ctx);
	ctxRef.current = ctx;
	const shortcuts = useRef<KeyboardShortcutBindings | null>(null);
	// The held set is read at event time and rendered from, so it
	// lives in both a ref and state. The ref is the one the resolver
	// reads; state only mirrors it for the render.
	const heldRef = useRef<HeldGestures>(NO_HELD_GESTURES);

	useEffect(() => {
		const apply = (next: HeldGestures) => {
			if (next === heldRef.current) return;
			heldRef.current = next;
			setHeld(next);
		};
		const onDown = (e: KeyboardEvent) => {
			const result = resolveKeyDown(
				heldRef.current,
				{
					key: e.key,
					cmd: e.metaKey || e.ctrlKey,
					shift: e.shiftKey,
					alt: e.altKey,
					repeat: e.repeat,
					textInput: isTextInputTarget(e.target),
				},
				ctxRef.current,
				shortcuts.current,
			);
			apply(result.held);
			if (result.preventDefault) e.preventDefault();
		};
		const onUp = (e: KeyboardEvent) => {
			apply(resolveKeyUp(heldRef.current, e.key));
		};
		const onBlur = () => apply(resolveBlur(heldRef.current));
		globalThis.addEventListener("keydown", onDown);
		globalThis.addEventListener("keyup", onUp);
		globalThis.addEventListener("blur", onBlur);
		return () => {
			globalThis.removeEventListener("keydown", onDown);
			globalThis.removeEventListener("keyup", onUp);
			globalThis.removeEventListener("blur", onBlur);
		};
	}, []);

	return { held, shortcuts };
}

/** Publish this view's shortcut bindings to the keyboard listener.
 *
 *  Written during render rather than from an effect, because the
 *  bindings close over handlers that are rebuilt every render and a
 *  keypress must reach the current ones. React runs a passive
 *  effect after paint, so an effect would leave one render's worth
 *  of window where a shortcut acted on the previous render's
 *  handlers. Writing the same value twice is a no-op, so the double
 *  render a strict-mode pass performs changes nothing. */
export function useShortcutBindings(
	sink: ShortcutSink,
	b: KeyboardShortcutBindings,
): void {
	sink.current = b;
	useEffect(() => () => {
		sink.current = null;
	}, [sink]);
}

/** Whether the pointer's topmost hit target is the stage canvas.
 * The panes, topbar, and timeline are pointer-events-auto DOM
 * above the one full-viewport canvas, so the canvas is the target
 * exactly when the pointer is over the visible stage. This is the
 * fact the `space-pan` gesture keys off: over the stage Space pans,
 * elsewhere it is transport. The gesture reads it once, when the
 * key goes down. */
export function useOverStage(): boolean {
	const [over, setOver] = useState(false);
	useEffect(() => {
		// `pointerover` fires on every target change with the new
		// target; one window listener tracks the whole app.
		const onOver = (ev: PointerEvent) => {
			setOver(
				(ev.target as HTMLElement | null)?.id === CANVAS_ELEMENT_ID,
			);
		};
		const onLeaveWindow = () => setOver(false);
		globalThis.addEventListener("pointerover", onOver);
		document.documentElement.addEventListener(
			"pointerleave",
			onLeaveWindow,
		);
		return () => {
			globalThis.removeEventListener("pointerover", onOver);
			document.documentElement.removeEventListener(
				"pointerleave",
				onLeaveWindow,
			);
		};
	}, []);
	return over;
}

/** Mirror `state` into `localStorage` on every change. Persistence
 * failures (quota, private mode, …) silently no-op so a broken
 * storage doesn't break the app. */
export function useAppStatePersistence(state: AppState): void {
	useEffect(() => {
		if (typeof globalThis.window === "undefined") return;
		try {
			globalThis.localStorage?.setItem(
				APP_STATE_STORAGE_KEY,
				JSON.stringify(state),
			);
		} catch {
			// give up
		}
	}, [state]);
}

/**
 * Buffer engine — the in-memory document that backs both Play
 * (replay) and Build (edit). Single source-of-truth; the active
 * mode just changes which verbs the UI exposes against it.
 *
 * App resolves which document is the source (edited fork → opened
 * file → live recording → fixture) and passes it as `sourceDoc`;
 * the Source panel displays the same resolution, so the picker
 * can never disagree with what the engine plays.
 *
 * The source is forked into a working copy, so editing never
 * touches it; the fork keeps its own layout mode, and an authored
 * peer position acts as a pin within it.
 *
 * Returns `null` until the first source is resolvable — typical
 * cold start has a fixture, so this is rarely null in practice.
 */
export function useBufferEngine(input: {
	/** The one document the buffer is built from. App owns the
	 * precedence that picks it (edited fork → opened file → live
	 * recording → fixture) so the picker and this hook read the
	 * same answer. */
	sourceDoc: TimelineDocument | null;
}): { bufferEngine: Engine | null } {
	const sourceDoc = input.sourceDoc;
	const [bufferEngine, setBufferEngine] = useState<Engine | null>(null);
	const held = useRef<BufferSourceTracker | null>(null);
	if (held.current === null) held.current = bufferSourceTracker();
	const sources = held.current;

	useEffect(() => {
		if (!sourceDoc) return;
		if (!sources.needsRebuild(bufferEngine, sourceDoc)) return;
		const next = new Engine(structuredClone(sourceDoc));
		next.enqueue({ kind: "pause" });
		setBufferEngine(next);
	}, [sourceDoc, bufferEngine, sources]);

	return { bufferEngine };
}

/**
 * What the buffer has been asked to play, and whether the next
 * document means a new one.
 *
 * The verdict and the record are one thing, because they are wrong
 * apart. Deciding not to rebuild is still having seen that source, and
 * a tracker that only wrote down the sources it rebuilt for compares
 * the next one against a document two steps back: leave Build once and
 * the fixture you then pick from the picker reads as the source
 * already playing, so the explicit switch does nothing.
 */
export type BufferSourceTracker = {
	/**
	 * Whether `nextSource` means a new buffer, recording it as seen
	 * either way.
	 *
	 * Only a genuinely different document does. Two things that look
	 * like one are not:
	 *
	 * Switching Play and Build is not a new document. It changes which
	 * verbs the UI offers, and the buffer under them is the same one —
	 * rebuilding for it threw away the edit history, so a round trip
	 * through Play silently emptied Undo. Every author action is one
	 * undo step, and looking at your own work is not an action.
	 *
	 * Neither is the working document handed back as the source, which
	 * is what leaving Build does to keep the edited fork ahead of the
	 * fixture in the precedence order. Rebuilding from it would fork
	 * the buffer off itself and lose the history for the same reason.
	 */
	needsRebuild(buffer: Engine | null, nextSource: TimelineDocument): boolean;
};

export function bufferSourceTracker(): BufferSourceTracker {
	let lastSource: TimelineDocument | null = null;
	return {
		needsRebuild(buffer, nextSource) {
			const seen = lastSource;
			lastSource = nextSource;
			if (buffer === null) return true;
			if (nextSource === buffer.doc) return false;
			return nextSource !== seen;
		},
	};
}

/**
 * The live feed's connection, and the capture that rides on it.
 *
 * These are two facts and this hook keeps them apart. A URL means a
 * socket: entering Live mode dials, and `connected` says only that a
 * feed is there to record if the reader wants one. Recording is the
 * reader's own act, and it is what mounts an `Engine` folding arriving
 * events into a document — the capture. Connected is not recording,
 * and a reader can watch the dot go green, drive the sim, and never
 * record at all.
 *
 * Pressing Record re-dials, which is what makes the capture whole. A
 * producer replays its live topology to each viewer that connects and
 * closes the batch with `trace.replay-end`, so a fresh socket is how
 * the capture learns the sessions that were already open before anyone
 * pressed anything. The capture's t=0 is therefore the press, and the
 * replay materializes that moment's topology as state inside it. A
 * capture that inherited the idle socket would have missed the replay
 * and started blind, with edges appearing only as traffic happened to
 * mention them.
 *
 * Passing `sturdyref = ""` dials nothing (the hook stays unconditionally
 * called for React rules-of-hooks; the body early-returns).
 */
export function useLiveConnection(input: {
	sturdyref: string;
	recording: boolean;
}): {
	/** The trace capability is subscribed. Says nothing about recording. */
	connected: boolean;
	/** At least one record has arrived on this dial. Independent of
	 *  `connected`: a quiet feed that has spoken is not a new endpoint
	 *  still waiting for its first observation. */
	observed: boolean;
	/** The engine capturing arriving events, or null when nothing is
	 * recording. Its document is what Stop claims as the buffer. */
	captureEngine: Engine | null;
} {
	const { sturdyref, recording } = input;
	const [captureEngine, setCaptureEngine] = useState<Engine | null>(null);
	const [connected, setConnected] = useState(false);
	const [observed, setObserved] = useState(false);

	useEffect(() => {
		if (!sturdyref) {
			setCaptureEngine(null);
			setConnected(false);
			setObserved(false);
			return;
		}
		// A sturdyref that cannot be parsed, dialed, or enlivened is the user's
		// typo or a stale capability, and it
		// belongs on the error bus beside every other thing the user can
		// get wrong. Left to throw out of this effect body it would reach
		// `AppErrorBoundary` instead and replace the running app.
		const onError = (error: EngineError) => pushError({ error, source: "engine" });
		// One dial, two things built on it. Recording adds the document and the
		// appender folding arrivals into it (`startLiveMode`); idle is the dial
		// and nothing else (`dialLiveFeed`). They differ in what they hand back,
		// never in how they subscribe, so the capability act is spelled once.
		const dial = {
			sturdyref,
			onConnectionChange: (up: boolean) => {
				setConnected(up);
				if (!up) setObserved(false);
			},
			onError,
		};
		const handle: {
			engine: Engine | null;
			feed: LiveFeed;
			dispose: () => void;
		} = recording ? startLiveMode(dial) : { ...dialLiveFeed(dial), engine: null };
		setCaptureEngine(handle.engine);
		const unsubObserved = handle.feed.subscribe(() => setObserved(true));
		return () => {
			unsubObserved();
			handle.dispose();
			setCaptureEngine(null);
			setConnected(false);
			setObserved(false);
		};
		// Deps: the sturdyref, because a different capability is a different feed, and
		// `recording`, because starting and stopping a capture each re-dial
		// — see the replay contract above. Nothing else may re-dial: every
		// one of them throws a running capture away.
	}, [sturdyref, recording]);

	return { connected, observed, captureEngine };
}
