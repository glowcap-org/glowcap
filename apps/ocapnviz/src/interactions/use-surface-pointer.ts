/**
 * React hook adapter for the pointer FSM — implements § 8.1 of the
 * interaction model.
 *
 * Attaches native pointer listeners to a host element, runs each
 * event through a per-host `PointerMachine` instance, and forwards
 * the returned `Effect`s to the consumer via `onEffect`.
 *
 * Native listeners (not React synthetic events) so that:
 *   - We own `setPointerCapture` lifecycle directly.
 *   - Wheel + pointer event modes don't interact via React's
 *     synthetic delegation.
 *   - `passive: false` is available for cases that need it.
 *
 * Handler refs box `onEffect` and `ctx` so the listener attachment
 * stays stable across host re-renders.
 */

import { useEffect, useRef } from "react";
import { hasSomethingToCommit, pointerReducer } from "./pointer-machine.ts";
import { type GestureEndReason, type SurfaceTag } from "./gesture-router.ts";
import { isTextInputTarget } from "./text-input-target.ts";
import { useGestureSurface } from "./use-gesture-surface.ts";
import {
  type BuilderTool,
  type Effect,
  type GestureContext,
  type Hit,
  IDLE_MACHINE,
  type ModifierSet,
  NO_MODIFIERS,
  type PointerMachineState,
  type PointerSnapshot,
  type SurfaceId,
} from "./types.ts";

/** What the host tells the machine about a press beyond the pointer event
 *  itself. Exactly what `resolveGesture` reads: the modifiers come off the
 *  event, the hit off `makeHit`, and these two off the host. */
export type SurfacePointerCtx = {
  spaceHeld: boolean;
  activeTool: BuilderTool;
};

export type SurfacePointerHandlers = {
  onEffect: (effect: Effect) => void;
};

/** Make a hit producer for a host surface. Returning `null` from
 *  `makeHit` skips the pointer-down (the gesture won't initiate).
 *  Used by surfaces whose host element extends past the relevant
 *  region — e.g., the Stage marker covers the canvas but should
 *  ignore clicks over the chrome that bleed through. */
export type MakeHit<SurfId extends SurfaceId = SurfaceId> = (
  ev: { clientX: number; clientY: number; target: EventTarget | null },
) => (Hit & { surface: SurfId }) | null;

/** The surface's live FSM state. The machine is the authority on what the
 *  surface is doing — only it knows what a press resolved to — so readers that
 *  must agree with the gesture take it from here. The cursor is the one that
 *  matters: it reports what is happening, and re-deriving that from live key
 *  or pointer state gets the Space-released-mid-drag case wrong.
 *
 *  A ref rather than React state: the FSM turns at pointer rate, and its
 *  readers run in the Pixi ticker, not in a render. */
export type PointerMachineRef = { readonly current: PointerMachineState };

export function useSurfacePointer<SurfId extends SurfaceId = SurfaceId>(
  host: HTMLElement | null,
  makeHit: MakeHit<SurfId>,
  handlers: SurfacePointerHandlers,
  ctx: SurfacePointerCtx,
  /** Gesture-router tag for cross-surface mutual exclusion. When
   *  set, the hook (1) marks `host` as owning this surface and
   *  (2) claims/releases the router lock around each gesture so
   *  the root guard can block foreign surfaces. Omitting leaves
   *  the surface outside the router (legacy mode). */
  surfaceTag?: SurfaceTag,
): PointerMachineRef {
  // How this surface ends a gesture it did not see end, filled in by the effect
  // below (which is where the FSM dispatch lives) and called from the window
  // watch for the ends the host element never sees.
  const endFromWatchRef = useRef<(reason: GestureEndReason) => void>(() => {});
  /** The last move's snapshot and hit, so a gesture can be ended by a path that
   *  carries no event of its own. Cleared whenever a gesture ends. */
  const lastSeenRef = useRef<
    { snapshot: PointerSnapshot; hit: Hit | null } | null
  >(null);
  // The surface's lease on the gesture lock. Held for this hook's
  // lifetime and released by it on unmount; the claim below is
  // what fills it. Without a `surfaceTag` the hook still runs
  // (Rules of Hooks) but nothing ever claims, which is the legacy
  // mode described on the parameter.
  //
  // The lock coming back is not the same thing as the gesture
  // ending, and the FSM is what has to hear the second one. A blur
  // or an off-document release that only freed the lease left this
  // machine in `dragging` with no drag: the next press reset it to
  // `pressed` with no `drag-end` in between, so a consumer that
  // opened an engine transaction at drag-start never got the call
  // that closes it.
  const surface = useGestureSurface(surfaceTag ?? "", (reason) => {
    endFromWatchRef.current(reason);
  });
  // Box callbacks + context in refs so the listener attachment is
  // stable across re-renders. The effect's dep is the `host`
  // element itself — when it appears (e.g. async PixiJS init), the
  // effect re-runs and the listeners attach.
  const handlersRef = useRef(handlers);
  handlersRef.current = handlers;
  const ctxRef = useRef(ctx);
  ctxRef.current = ctx;
  const makeHitRef = useRef(makeHit);
  makeHitRef.current = makeHit;

  // Per-host machine instance lives here. Mutated by the reducer
  // wrappers below; never read by render code.
  const machineRef = useRef<PointerMachineState>(IDLE_MACHINE);
  // Track primary-button state so `space-up` can report whether
  // the pointer is still held (for Figma-convert: drag-resume vs
  // drag-end). The FSM consults this to decide which transition.
  const pointerHeldRef = useRef(false);
  // Down-time hit, preserved across the press → dragging transition.
  // The FSM's `dragging` state intentionally drops `ctxAtDown` (a
  // drag-in-flight has no use for the down's hit; the FSM emits
  // `drag-end` with the snapshot alone). But pointer-up still needs
  // to dispatch SOMETHING with a `ctxAtUp.hit` for the type signature
  // — and when the user releases off-surface, the up-time hit-test
  // returns null. Falling back to this ref keeps the commit firing
  // for release-off-surface marquees / drags.
  const hitAtDownRef = useRef<Hit | null>(null);

  useEffect(() => {
    if (!host) return;

    const dispatch = (
      state: PointerMachineState,
      event: Parameters<typeof pointerReducer>[1],
    ) => {
      const result = pointerReducer(state, event);
      machineRef.current = result.state;
      for (const effect of result.effects) {
        handlersRef.current.onEffect(effect);
      }
    };

    const onPointerDown = (ev: PointerEvent) => {
      // Only primary button initiates gestures.
      if (ev.button !== 0) return;
      pointerHeldRef.current = true;
      const hit = makeHitRef.current({
        clientX: ev.clientX,
        clientY: ev.clientY,
        target: ev.target,
      });
      if (!hit) return;
      // Cross-surface lock — bail if another surface owns the
      // gesture. The root guard normally suppresses this event
      // before reaching us, but defending here keeps the FSM
      // honest when the guard isn't installed (tests).
      if (surfaceTag && !surface.claim(host, ev.pointerId)) {
        return;
      }
      ev.preventDefault();
      try {
        host.setPointerCapture(ev.pointerId);
      } catch {
        // capture may fail on some elements; harmless
      }
      hitAtDownRef.current = hit;
      const snapshot = snapshotOf(ev);
      const gctx: GestureContext = {
        hit,
        modifiers: snapshot.modifiers,
        spaceHeld: ctxRef.current.spaceHeld,
        activeTool: ctxRef.current.activeTool,
      };
      dispatch(machineRef.current, {
        kind: "pointer-down",
        surface: hit.surface,
        snapshot,
        ctx: gctx,
      });
    };

    // One teardown for every way a gesture ends with nothing to commit: the
    // system taking the pointer back, a window blur, and any of the finish paths
    // arriving in a state `hasSomethingToCommit` refuses. The FSM's `cancel` is
    // what unwinds a drag in flight, so every one of them has to reach it —
    // spelled once here rather than repeated at each caller, where one copy
    // going missing is invisible until an interrupted drag leaves a
    // transaction open.
    const cancelGesture = (pointerId?: number) => {
      surface.release(pointerId);
      pointerHeldRef.current = false;
      hitAtDownRef.current = null;
      dispatch(machineRef.current, { kind: "cancel" });
    };
    // What the window watch calls. A drag the reader finished is ENDED, not
    // cancelled: the watch fires when the pointer this surface holds goes up
    // anywhere, and letting go is finishing. Cancelling instead is what discarded
    // a marquee on a fast drag — a buttonless pointermove reaches the window
    // while the button is coming up mid-motion, the watch calls this, and the
    // whole selection went with it before the surface's own pointerup ever
    // arrived.
    //
    // Which of the two it was comes from the watch rather than from this machine,
    // because a gesture taken away and one the reader finished leave the FSM in
    // the same state and only the watch saw which event arrived.
    endFromWatchRef.current = (reason) => {
      if (reason === "finished" && hasSomethingToCommit(machineRef.current)) {
        endGestureFromLastSeen();
      } else cancelGesture();
    };

    const onPointerMove = (ev: PointerEvent) => {
      // Phantom-drag recovery — the button is up and we never heard the
      // pointerup (off-document, OS chrome, or a release delivered mid-motion,
      // where a move can carry `buttons: 0` ahead of the up).
      //
      // A missed release is a COMPLETION, not a cancellation. The reader did let
      // go, so a drag in flight has to commit what it was showing: cancelling
      // instead threw away a marquee's whole selection, and because it took only
      // one buttonless move to happen, it read as a fast drag randomly selecting
      // nothing. `onPointerUp`'s own note on committing a release that lands
      // off-stage is the same rule; this path was the one place that broke it.
      // The timeline never did, which is why its marquee behaved: its recovery
      // has always ended the drag rather than cancelled it
      // (`Timeline/Scrubber.tsx`'s `endDrag`).
      //
      // Only a drag commits. A press that never moved has nothing in flight, and
      // ending it would fire a click — at wherever the pointer happens to be
      // when the news arrives, which may be nowhere near what was pressed.
      if (machineRef.current.fsm.kind !== "idle" && (ev.buttons & 1) === 0) {
        if (hasSomethingToCommit(machineRef.current)) endGesture(ev);
        else cancelGesture(ev.pointerId);
        return;
      }
      const snapshot = snapshotOf(ev);
      const hit = makeHitRef.current({
        clientX: ev.clientX,
        clientY: ev.clientY,
        target: ev.target,
      });
      // Held so a gesture can be ended when the news arrives with no event of
      // its own — the window watch below has only the fact that it is over.
      lastSeenRef.current = { snapshot, hit };
      dispatch(machineRef.current, {
        kind: "pointer-move",
        snapshot,
        hit,
      });
    };

    /**
     * End a gesture at `ev`, committing whatever it had in flight.
     *
     * Split out from `onPointerUp` because the release is not always the event
     * that tells us about it: a pointermove can arrive with the button already
     * up, and that move IS the news that the gesture is over. Both paths owe the
     * same bookkeeping and the same `pointer-up`, so they are one function.
     */
    const endGesture = (ev: PointerEvent) => {
      pointerHeldRef.current = false;
      lastSeenRef.current = null;
      surface.release(ev.pointerId);
      const snapshot = snapshotOf(ev);
      // For pointer-up we need the FULL ctx (hit + modifiers) so the
      // FSM can re-resolve the click verb (D). The hit comes from
      // the current pointer position; for clicks where the cursor
      // hasn't moved this matches the down's hit.
      const hit = makeHitRef.current({
        clientX: ev.clientX,
        clientY: ev.clientY,
        target: ev.target,
      });
      // If hit went null (cursor moved off the surface during a
      // press/drag), fall back to the captured down hit so the
      // gesture commits against the original target — critical for
      // marquee drags whose release lands outside the host (Bug 3:
      // "release off-stage should commit the highlights"). FSM
      // tracks ctxAtDown on `pressed`; the hook ref covers the
      // dragging / paused-pan branches the FSM drops it on.
      const hitForUp = hit ?? hitAtDownRef.current;
      hitAtDownRef.current = null;
      if (!hitForUp) return;
      const ctxAtUp: GestureContext = {
        hit: hitForUp,
        modifiers: snapshot.modifiers,
        spaceHeld: ctxRef.current.spaceHeld,
        activeTool: ctxRef.current.activeTool,
      };
      dispatch(machineRef.current, {
        kind: "pointer-up",
        snapshot,
        ctxAtUp,
      });
    };

    const onPointerUp = (ev: PointerEvent) => {
      if (ev.button !== 0) return;
      endGesture(ev);
    };

    /**
     * End a drag whose release we learned about without an event.
     *
     * The window watch (`watchGestureEnd`) reports that the pointer this surface
     * holds has gone up somewhere it could not see. There is no position to read,
     * and none is needed: what a drag commits is what it was already showing, and
     * every surface keeps that itself — a marquee's rect, a node's last target.
     * All this has to supply is the fact that the gesture is over.
     *
     * The hit falls back to the one captured at pointer-down, the same fallback
     * `endGesture` uses for a release that lands off the surface.
     */
    const endGestureFromLastSeen = () => {
      const last = lastSeenRef.current;
      pointerHeldRef.current = false;
      lastSeenRef.current = null;
      surface.release();
      const hitForUp = last?.hit ?? hitAtDownRef.current;
      hitAtDownRef.current = null;
      if (!last || !hitForUp) {
        dispatch(machineRef.current, { kind: "cancel" });
        return;
      }
      dispatch(machineRef.current, {
        kind: "pointer-up",
        snapshot: last.snapshot,
        ctxAtUp: {
          hit: hitForUp,
          modifiers: last.snapshot.modifiers,
          spaceHeld: ctxRef.current.spaceHeld,
          activeTool: ctxRef.current.activeTool,
        },
      });
    };

    /**
     * Capture is gone, so no more of this gesture is coming.
     *
     * On an ordinary release this arrives AFTER the pointerup that already
     * committed, and lands on an idle machine where it does nothing. When it
     * arrives while a drag is still in flight it is the last thing we will hear,
     * and the reader has let go — so it ends the gesture for the same reason the
     * phantom-move recovery does, and cancelling instead is what threw a
     * marquee's whole selection away on a fast release.
     *
     * `pointercancel` below is NOT this. That one means the system took the
     * gesture back — a palm landing on a trackpad, a touch turned into a scroll —
     * and there the reader never finished, so cancelling is the honest answer.
     */
    const onLostCapture = (ev: PointerEvent) => {
      if (hasSomethingToCommit(machineRef.current)) endGesture(ev);
      else cancelGesture(ev.pointerId);
    };

    const onPointerCancel = (ev: PointerEvent) => cancelGesture(ev.pointerId);

    const onPointerLeave = (ev: PointerEvent) => {
      // Clear hover when the pointer leaves the host (idle only;
      // during a press the captured drag continues to receive moves).
      if (machineRef.current.fsm.kind === "idle") {
        dispatch(machineRef.current, {
          kind: "pointer-move",
          snapshot: snapshotOf(ev),
          hit: null,
        });
      }
    };

    // Forward Space keydown/keyup to the FSM so mid-drag space-
    // press triggers the paused-pan (Figma-convert) transition.
    // The FSM ignores space events that arrive in irrelevant
    // states (e.g. space-down while idle is a no-op), so the
    // bridge is safe to attach regardless of what the FSM is
    // doing. INPUT/TEXTAREA targets bypass to let text-input
    // spaces type a literal space character.
    //
    // This is the physical key, not the `space-pan` held gesture
    // that `keyboard-input.ts` decides. The two cannot contradict
    // each other, and the reason is a condition rather than a
    // coincidence: this hook's only host is the Stage canvas
    // (`Stage.tsx`), which is the same element `useOverStage` keys
    // on, and the host holds `setPointerCapture` for the length of
    // a gesture. So a drag on this surface runs with `overStage`
    // true, which is exactly when the pan claims. A press the
    // gesture declined reaches an idle FSM, where space-down is a
    // no-op. Put this hook on a second surface and that stops
    // being true: the claim would have to be routed in from the
    // authority instead of re-derived here.
    const onKeyDown = (ev: KeyboardEvent) => {
      if (ev.key !== " " && ev.key !== "Spacebar") return;
      if (isTextInputTarget(ev.target)) return;
      // Suppress key-repeat — FSM treats space-down in paused-pan
      // as a no-op anyway, but the early-return keeps the event
      // loop cleaner.
      if (ev.repeat) return;
      dispatch(machineRef.current, { kind: "space-down" });
    };
    const onKeyUp = (ev: KeyboardEvent) => {
      if (ev.key !== " " && ev.key !== "Spacebar") return;
      dispatch(machineRef.current, {
        kind: "space-up",
        pointerHeld: pointerHeldRef.current,
      });
    };

    host.addEventListener("pointerdown", onPointerDown);
    host.addEventListener("pointermove", onPointerMove);
    host.addEventListener("pointerup", onPointerUp);
    host.addEventListener("lostpointercapture", onLostCapture);
    host.addEventListener("pointercancel", onPointerCancel);
    host.addEventListener("pointerleave", onPointerLeave);
    globalThis.addEventListener("keydown", onKeyDown);
    globalThis.addEventListener("keyup", onKeyUp);
    return () => {
      host.removeEventListener("pointerdown", onPointerDown);
      host.removeEventListener("pointermove", onPointerMove);
      host.removeEventListener("pointerup", onPointerUp);
      host.removeEventListener("lostpointercapture", onLostCapture);
      host.removeEventListener("pointercancel", onPointerCancel);
      host.removeEventListener("pointerleave", onPointerLeave);
      globalThis.removeEventListener("keydown", onKeyDown);
      globalThis.removeEventListener("keyup", onKeyUp);
    };
    // `surface` is the same lease for this hook's whole life, so
    // it never re-runs the attachment; it is listed because the
    // listeners close over it.
  }, [host, surfaceTag, surface]);

  return machineRef;
}

// ─────────────────────── Helpers ──────────────────────────────────────

function snapshotOf(ev: PointerEvent): PointerSnapshot {
  return {
    clientX: ev.clientX,
    clientY: ev.clientY,
    buttons: ev.buttons,
    modifiers: modifiersOf(ev),
    timestampMs: ev.timeStamp,
  };
}

export function modifiersOf(
  ev: Pick<PointerEvent, "shiftKey" | "metaKey" | "ctrlKey" | "altKey">,
): ModifierSet {
  return {
    shift: ev.shiftKey,
    cmd: ev.metaKey || ev.ctrlKey,
    alt: ev.altKey,
  };
}

/** Reusable helper for callers that want to construct a snapshot
 *  from a non-PointerEvent (rare; tests). */
export function snapshotFromCoords(
  clientX: number,
  clientY: number,
  modifiers: ModifierSet = NO_MODIFIERS,
  timestampMs = performance.now(),
  buttons = 1,
): PointerSnapshot {
  return { clientX, clientY, buttons, modifiers, timestampMs };
}
