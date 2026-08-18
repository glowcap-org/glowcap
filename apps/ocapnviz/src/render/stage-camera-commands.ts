/**
 * How a named camera command becomes a viewport mutation.
 *
 * The camera itself lives in pixi-viewport; the controls know only the
 * four things they can ask for (`StageCameraCommand`). This module is
 * the mapping between those two, including Fit's layer list — which
 * layers count as the picture is a fact about the command, not about
 * the React host that attached the port.
 *
 * Wheel zoom/pan is the same mapping from the other door: a
 * `WheelEffect` rather than a named command, still a viewport mutation,
 * still not a React concern.
 */

import type { WheelEffect } from "../interactions/use-surface-wheel.ts";
import type { StageCameraCommand } from "./stage-camera.ts";
import { clampStageZoom, DEFAULT_STAGE_VIEW, fitStageView, steppedStageZoom, unionBounds } from "./stage-view.ts";

/**
 * Breathing room Fit leaves around the content, in screen pixels.
 *
 * Screen pixels because it is margin for a reader rather than a fact about the
 * world, and generous enough that a node's focus ring and caption — which hold
 * their own screen size and so are not in the world bounds Fit measures — still
 * have somewhere to be.
 */
export const FIT_PADDING_PX = 24;

/** The slice of pixi-viewport a named command needs. */
export type StageCameraTarget = {
  readonly center: { readonly x: number; readonly y: number };
  readonly scale: { readonly x: number };
  readonly screenWidth: number;
  readonly screenHeight: number;
  setZoom(zoom: number, center?: boolean): unknown;
  moveCenter(x: number, y: number): unknown;
};

/** A layer Fit may measure. Empty layers are skipped by `unionBounds`. */
export type StageFitLayer = {
  readonly children: { readonly length: number };
  getLocalBounds(): { x: number; y: number; width: number; height: number };
};

/**
 * Run one named command against the live viewport.
 *
 * Fit measures the document's own picture from the scene graph rather than
 * recomputing from entity positions, so a thing that is drawn cannot be left
 * out of the fit. Three layers rather than the viewport whole, and each
 * exclusion is load-bearing. The GRID spans the world, so fitting it fits the
 * world and a three-node document lands at 16% in an empty field — which is
 * exactly what fitting the viewport did. The AFFORDANCE layer is a wire
 * preview chasing the cursor, which is not content. And the LABELS hold
 * constant screen size, so their world bounds depend on the current zoom:
 * fitting them would make the answer depend on the question. `FIT_PADDING_PX`
 * is what leaves them room.
 *
 * Which layers those are is checked by nothing: there is no test that builds
 * a viewport, so the exclusions are held by the caller's list and this
 * comment. `unionBounds` skips empty rectangles (the always-present edge
 * stroke batch reports origin bounds when nothing is stroked) and
 * `fitStageView` carries the arithmetic; both are covered in
 * `stage-view.test.ts`. A new content layer has to be added at the call site
 * by hand, and fitting the world instead of the picture is what it looks like
 * when one is missing.
 */
export function runStageCameraCommand(
  viewport: StageCameraTarget,
  fitLayers: readonly StageFitLayer[],
  command: StageCameraCommand,
): void {
  switch (command.kind) {
    case "zoom-to": {
      const held = viewport.center;
      viewport.setZoom(clampStageZoom(command.zoom), true);
      viewport.moveCenter(held.x, held.y);
      break;
    }
    case "zoom-in":
    case "zoom-out": {
      // About the viewport's center, unlike the wheel's cursor pivot: hold
      // the center world point, rescale, put it back.
      const held = viewport.center;
      viewport.setZoom(
        steppedStageZoom(viewport.scale.x, command.kind === "zoom-out"),
        true,
      );
      viewport.moveCenter(held.x, held.y);
      break;
    }
    case "fit": {
      const drawn = fitLayers
        .filter((layer) => layer.children.length > 0)
        .map((layer) => layer.getLocalBounds());
      const content = unionBounds(drawn);
      // Nothing drawn is nothing to fit, and moving the camera to say so
      // would lose the reader their place.
      if (!content) break;
      const view = fitStageView(
        content,
        { width: viewport.screenWidth, height: viewport.screenHeight },
        FIT_PADDING_PX,
      );
      viewport.setZoom(view.zoom, true);
      viewport.moveCenter(view.center.x, view.center.y);
      break;
    }
    case "go-to": {
      // Both at once, because the caller is naming a whole view rather
      // than adjusting the one the camera holds.
      viewport.setZoom(clampStageZoom(command.view.zoom), true);
      viewport.moveCenter(command.view.center.x, command.view.center.y);
      break;
    }
    case "home": {
      // The middle of the world at 1:1. Not the document's stored view,
      // which is the document panel's business: its Opens-at row is where
      // a reader both sets that view and goes back to it.
      viewport.setZoom(DEFAULT_STAGE_VIEW.zoom, true);
      viewport.moveCenter(
        DEFAULT_STAGE_VIEW.center.x,
        DEFAULT_STAGE_VIEW.center.y,
      );
      break;
    }
  }
}

/** The slice of pixi-viewport a wheel effect mutates. */
export type StageWheelTarget = {
  readonly scale: { readonly x: number };
  readonly position: { x: number; y: number };
  setZoom(zoom: number, center?: boolean): unknown;
  toWorld(x: number, y: number): { x: number; y: number };
  toScreen(x: number, y: number): { x: number; y: number };
};

/**
 * Apply one wheel effect to the viewport, or ignore it when the cursor is
 * outside the Stage marker.
 *
 * The canvas is shared with Timeline / Overview; a zoom whose pivot is not
 * in the Stage region is somebody else's. Pan-step skips that check (rare
 * in practice — trackpad horizontal swipes anywhere on the canvas pan the
 * stage, which is the right behavior since the stage is the primary spatial
 * surface).
 */
export function applyStageWheel(
  viewport: StageWheelTarget,
  effect: WheelEffect,
  host: Pick<HTMLElement, "getBoundingClientRect"> | null,
  canvas: Pick<HTMLElement, "getBoundingClientRect"> | null,
): void {
  if (effect.kind === "zoom-step") {
    if (host && canvas) {
      const r = host.getBoundingClientRect();
      const c = canvas.getBoundingClientRect();
      const pivotClientX = c.left + effect.pivotX;
      const pivotClientY = c.top + effect.pivotY;
      if (
        pivotClientX < r.left || pivotClientX > r.right ||
        pivotClientY < r.top || pivotClientY > r.bottom
      ) {
        return;
      }
    }
    // pixi-viewport's `clampZoom` plugin still constrains the
    // assigned scale; we just compute the target and let it
    // clamp via setZoom (which respects the plugin).
    const nextScale = viewport.scale.x * effect.factor;
    // Anchor the zoom around the cursor: convert the pivot from
    // screen coords (host-relative) into world coords BEFORE the
    // scale change, then re-position the viewport so that world
    // point still maps to the same screen point AFTER.
    const worldPivot = viewport.toWorld(effect.pivotX, effect.pivotY);
    viewport.setZoom(nextScale, true);
    const screenAfter = viewport.toScreen(worldPivot.x, worldPivot.y);
    viewport.position.x += effect.pivotX - screenAfter.x;
    viewport.position.y += effect.pivotY - screenAfter.y;
    return;
  }
  // Horizontal pan from trackpad swipe or Shift+wheel.
  viewport.position.x -= effect.delta.dx;
  viewport.position.y -= effect.delta.dy;
}
