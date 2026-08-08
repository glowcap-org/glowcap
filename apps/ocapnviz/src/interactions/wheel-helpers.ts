/**
 * Pure helpers for the wheel hook (§ 8.2). Split from
 * `use-surface-wheel.ts` so unit tests can import without
 * transitively pulling in React.
 */

import type { SurfaceId } from "./types.ts";

export type WheelEffect =
  | {
    kind: "zoom-step";
    surface: SurfaceId;
    /** Cursor position in host coords (offsetX/Y). Zoom anchors here. */
    pivotX: number;
    pivotY: number;
    /** Multiplicative zoom factor. `>1` zooms in; `<1` zooms out. */
    factor: number;
  }
  | {
    kind: "pan-step";
    surface: SurfaceId;
    /** Pan delta in host coords. */
    delta: { dx: number; dy: number };
  };

/** Wheel sensitivity for zoom. Empirical: matches the pixi-viewport
 *  feel users have today. */
export const WHEEL_ZOOM_RATE = 0.0015;
/** Multiplier applied to wheel-zoom rate when Shift is held. */
export const WHEEL_FAST_FACTOR = 4;

/** Per-surface wheel policy. Different surface kinds want different
 *  semantics for the same wheel input:
 *
 *  - **spatial** (Stage): a 2D canvas. Vertical scroll zooms around
 *    the cursor. That's it — no auto-pan from wheel or trackpad.
 *    Pan requires Spacebar (or the Hand tool when added). Predictable
 *    > clever: trackpad two-finger gestures often have small
 *    incidental horizontal/vertical components users didn't intend;
 *    routing those to pan creates "what just happened?" surprises.
 *    Shift fast-zooms for traversing zoom space quickly.
 *  - **linear** (Timeline): a 1D track. Horizontal swipe OR
 *    Shift+vertical pans the time window; pure vertical wheel
 *    zooms. Matches DAW / NLE timeline convention where the
 *    primary axis is time (horizontal) and zoom changes the
 *    time-window scale. */
export type WheelPolicy = "spatial" | "linear";

export type WheelInput = {
  deltaX: number;
  deltaY: number;
  shiftKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  offsetX: number;
  offsetY: number;
};

/** Map a `WheelEvent`-shaped input to a `WheelEffect`. Pure;
 *  policy decides the routing. */
export function wheelToEffect(
  ev: WheelInput,
  surface: SurfaceId,
  policy: WheelPolicy,
): WheelEffect {
  if (policy === "spatial") return spatialWheel(ev, surface);
  return linearWheel(ev, surface);
}

function spatialWheel(ev: WheelInput, surface: SurfaceId): WheelEffect {
  // Spatial policy: zoom around cursor on vertical scroll, full
  // stop. deltaX is intentionally ignored — trackpad two-finger
  // gestures often carry small unintended horizontal components,
  // and routing those to pan competes with the spacebar/Hand
  // pan path that's already the documented gesture. Shift
  // fast-zooms. To pan: hold Space (or use Hand tool when added).
  return zoomEffect(ev, surface, ev.shiftKey);
}

function linearWheel(ev: WheelInput, surface: SurfaceId): WheelEffect {
  // Horizontal pan path: trackpad swipe OR shift + vertical scroll.
  const horizontalIntent = Math.abs(ev.deltaX) > Math.abs(ev.deltaY) ||
    ev.shiftKey;
  if (horizontalIntent) {
    const dx = Math.abs(ev.deltaX) > Math.abs(ev.deltaY)
      ? ev.deltaX
      : ev.deltaY;
    return { kind: "pan-step", surface, delta: { dx, dy: 0 } };
  }
  // Default vertical scroll on a linear track: zoom around cursor.
  // Shift+vertical already routed above (it's the horizontal-pan
  // path for keyboard-only users on linear surfaces).
  return zoomEffect(ev, surface, ev.shiftKey);
}

function zoomEffect(
  ev: WheelInput,
  surface: SurfaceId,
  fast: boolean,
): WheelEffect {
  const fastness = fast ? WHEEL_FAST_FACTOR : 1;
  const zoomDelta = -ev.deltaY * WHEEL_ZOOM_RATE * fastness;
  const factor = Math.exp(zoomDelta);
  return {
    kind: "zoom-step",
    surface,
    pivotX: ev.offsetX,
    pivotY: ev.offsetY,
    factor,
  };
}
