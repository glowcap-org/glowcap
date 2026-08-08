/**
 * React hook adapter for the wheel pipeline — implements § 8.2 of the
 * interaction model.
 *
 * Wheel is a SIBLING pipeline to the pointer FSM — same Effect
 * families (pan-step, zoom-step), no pointer state. Replaces the
 * pixi-viewport wheel-plugin on Stage and the inline `applyWheel`
 * handlers on Scrubber / Overview.
 */

import { useEffect, useRef } from "react";
import type { SurfaceId } from "./types.ts";
import {
  type WheelEffect,
  type WheelPolicy,
  wheelToEffect,
} from "./wheel-helpers.ts";

export {
  WHEEL_FAST_FACTOR,
  WHEEL_ZOOM_RATE,
  type WheelEffect,
  type WheelPolicy,
  wheelToEffect,
} from "./wheel-helpers.ts";

export type SurfaceWheelHandlers = {
  onEffect: (effect: WheelEffect) => void;
};

export function useSurfaceWheel(
  host: HTMLElement | null,
  surface: SurfaceId,
  policy: WheelPolicy,
  handlers: SurfaceWheelHandlers,
): void {
  const handlersRef = useRef(handlers);
  handlersRef.current = handlers;

  useEffect(() => {
    if (!host) return;
    const onWheel = (ev: WheelEvent) => {
      // preventDefault keeps the page from scrolling; requires
      // `{ passive: false }`.
      ev.preventDefault();
      const effect = wheelToEffect(ev, surface, policy);
      handlersRef.current.onEffect(effect);
    };
    host.addEventListener("wheel", onWheel, { passive: false });
    return () => host.removeEventListener("wheel", onWheel);
  }, [host, surface, policy]);
}
