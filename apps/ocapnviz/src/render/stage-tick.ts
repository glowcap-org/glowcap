/**
 * One frame of the live stage: tick the engine, project the world, paint
 * affordances, publish the camera.
 *
 * `use-stage-scene.ts` mounts the graph and registers this as the ticker
 * callback. `render-frame.ts` is the world→sprite projection this frame
 * calls; this module is everything around that projection — visibility,
 * hover halo, cursor, overlays, settle, cull.
 */

import { type Container, Culler, type Graphics, type Rectangle } from "pixi.js";
import type { Viewport } from "pixi-viewport";
import { cursorFor, type ToolWillPick, verbArmsForTool, verbIsPan, verbSelectsEntity } from "../interactions/cursor.ts";
import { resolveGesture } from "../interactions/gesture-resolver.ts";
import {
  type EntityRefKey,
  type Hit,
  NO_MODIFIERS,
  type PointerMachineState,
  type SurfaceGestureCtx,
} from "../interactions/types.ts";
import type { Engine } from "../engine/engine.ts";
import { findNode } from "../engine/world.ts";
import { twoClickAccepts } from "../builder/two-click.ts";
import { type Theme } from "../ui/tokens.ts";
import { drawArmedRing, drawLooseEndBody, drawMarchingLine, LOOSE_END_ALONE, NODE_RADIUS } from "./draw-helpers.ts";
import { PROFILE_FALLBACK_COLOR, themedColors } from "./palette.ts";
import { renderFrame, type RenderFrameArgs } from "./render-frame.ts";
import { stageCamera } from "./stage-camera.ts";
import { endpointBodyRadius } from "./sprites/endpoint.ts";
import { type StageHover, type StageVisibility } from "./types.ts";

export type StageArmedNode = {
  nodeId: string;
  tool: "open-session" | "send-message";
};

export type StageFrame = {
  lastWall: number;
  lastDrawnTheme: Theme;
  marchOffsetPx: number;
  overlayDirty: boolean;
  engine: Engine;
  viewport: Viewport;
  stageScene: Container;
  cullView: Rectangle;
  peerLayer: Container;
  edgeLayer: Container;
  messageLayer: Container;
  labelLayer: Container;
  themeRef: { current: Theme };
  visibilityRef: { current: StageVisibility };
  selectionRef: { current: ReadonlySet<EntityRefKey> };
  anchorRef: { current: EntityRefKey | null };
  previewSelectionRef: { current: ReadonlySet<EntityRefKey> };
  hoverRef: { current: StageHover };
  armedNodeRef: { current: StageArmedNode | undefined };
  resolvedGestureCtxRef: { current: SurfaceGestureCtx };
  rubberBandRef: { current: unknown };
  setCursor: (cursor: string) => void;
  paintRubberBand: () => void;
  drawGrid: (theme: Theme) => void;
  updateGridLod: () => void;
  renderArgs: RenderFrameArgs;
  stageHoverToHit: (h: StageHover) => Hit | null;
  willPick: ToolWillPick;
  cursorMachine: () => PointerMachineState;
  armedRingGfx: Graphics;
  wirePreviewGfx: Graphics;
  ghostEndGfx: Graphics;
  cursorWorld: { x: number; y: number; hasValue: boolean };
};

export function tickStageFrame(frame: StageFrame): void {
  const now = performance.now();
  const wallDt = now - frame.lastWall;
  frame.lastWall = now;
  frame.engine.tick(wallDt);
  if (frame.themeRef.current !== frame.lastDrawnTheme) {
    frame.drawGrid(frame.themeRef.current);
    frame.lastDrawnTheme = frame.themeRef.current;
  }
  const v = frame.visibilityRef.current;
  frame.peerLayer.visible = v.peers;
  frame.edgeLayer.visible = v.connections;
  frame.messageLayer.visible = v.messages;
  frame.labelLayer.visible = v.labels;
  frame.updateGridLod();
  const renderArgs = frame.renderArgs;
  renderArgs.selection = frame.selectionRef.current;
  renderArgs.anchor = frame.anchorRef.current;
  renderArgs.previewSelection = frame.previewSelectionRef.current;
  // Hover-ring affordance gate (interaction-model § 1.1 +
  // § 4.5): "preview what the next click would do, using
  // the SAME resolver the click pipeline uses." Synthesize
  // the Hit for the hovered entity, run it through
  // `resolveGesture` with the current ctx, and show the
  // ring iff the resolved verb would select that entity.
  // The doctrine: render code never hard-codes tool /
  // modifier policy — it asks the resolver. New tools and
  // modifiers automatically propagate to affordances by
  // virtue of `resolveGesture` returning a different verb.
  const hovered = frame.hoverRef.current;
  renderArgs.hover = null;
  if (hovered) {
    const hoverHit = frame.stageHoverToHit(hovered);
    if (hoverHit) {
      const verb = resolveGesture({
        hit: hoverHit,
        modifiers: NO_MODIFIERS,
        spaceHeld: frame.resolvedGestureCtxRef.current.spaceHeld,
        activeTool: frame.resolvedGestureCtxRef.current.activeTool,
      });
      // Hover halo fires for any verb that would, on click,
      // act on the hovered entity — `select-or-drag-*` for
      // the Select tool AND `two-click-pick` for Open
      // Session / Send Message (the picked peer becomes
      // endpoint A / message origin). Without the
      // tool-create branch, the two-click tools lost their
      // "this peer is the pickable target" feedback.
      // And, mid-gesture, only when the tool would actually take this
      // node. The verb above answers from the tool and the surface
      // alone, which is the whole answer for a first pick; a second
      // pick also depends on the node already armed, and a ring on a
      // node the click will refuse is the same lie the cursor was.
      const armedNow = frame.armedNodeRef.current ?? null;
      const wouldTake = armedNow === null ||
        armedNow.tool !== frame.resolvedGestureCtxRef.current.activeTool ||
        (hovered.kind !== "peer" && hovered.kind !== "endpoint") ||
        twoClickAccepts(frame.engine, armedNow.tool, armedNow.nodeId, {
            kind: hovered.kind,
            id: hovered.id,
          }) === "takes";
      if (wouldTake && (verbSelectsEntity(verb) || verbArmsForTool(verb))) {
        renderArgs.hover = hovered;
      }
    }
  }
  renderArgs.colors = themedColors(frame.themeRef.current);
  // The frame's claim/bundle tables, once: flight already placed
  // dots from them; the projection draws ends and edges with the
  // same maps so a ring sizes to the body it rings and a wire
  // carries its own traffic.
  const { claimsToward, sessionCurves } = frame.engine.frameGeometry;
  renderArgs.claimsToward = claimsToward;
  renderArgs.sessionCurves = sessionCurves;
  // THE cursor, once per frame (cursor.md). Derived from the same resolver
  // the click goes through and the same FSM that runs it, so what the
  // pointer promises is what the click does. `setCursor` is the canvas
  // element's one writer and touches the DOM only on a change.
  frame.setCursor(cursorFor(
    {
      ...frame.resolvedGestureCtxRef.current,
      toolState: frame.armedNodeRef.current ?? null,
    },
    frame.cursorMachine(),
    frame.willPick,
  ));
  // Inverse of viewport zoom — applied to label containers
  // so text stays at constant screen size while positions
  // remain in world space. The zoom itself goes too, because a
  // selection mark divides by it for the same reason and must
  // not re-derive the camera from its own reciprocal.
  renderArgs.scale = frame.viewport.scale.x;
  renderArgs.counterScale = 1 / frame.viewport.scale.x;
  // Same value the frame is about to draw with, so the readout cannot
  // disagree with the picture. The store compares before it notifies, so
  // this is a cheap call to make every frame.
  stageCamera.publishZoom(frame.viewport.scale.x);
  // Where the camera is IS where the document opens, so a look around is
  // what sets it. Written as the camera settles rather than per frame: a
  // wheel gesture crosses dozens of scales on the way to one, and each
  // write notifies the app, so writing them all would re-render the tree at
  // the frame rate to record positions nobody stopped at.
  stageCamera.noteViewWhenSettled(
    frame.viewport.scale.x,
    frame.viewport.center.x,
    frame.viewport.center.y,
  );
  renderFrame(renderArgs);
  // Marching-ants animation: while a rubber-band drag is in
  // flight, repaint the overlay each tick so the phase
  // increments and ants visibly march. paintRubberBand
  // early-returns when no band is active (cheap no-op).
  if (frame.rubberBandRef.current) frame.paintRubberBand();
  // Advance marching offset proportional to wall time so the
  // dashes move at a constant screen-pixel speed regardless
  // of frame rate or playback speed.
  frame.marchOffsetPx = (frame.marchOffsetPx + wallDt * 0.04) % 1000;
  const armed = frame.armedNodeRef.current ?? null;
  // A node, not a peer: the message tool arms an end nothing has
  // attributed just as it arms a peer, and an armed node with no ring
  // is the tool holding a pick it never says it holds.
  const armedEntity = armed ? findNode(frame.engine.world, armed.nodeId) : null;
  if (armed && armedEntity?.position) {
    const themed = themedColors(frame.themeRef.current);
    const color = armed.tool === "send-message" ? themed.messageInFlight : themed.accent;
    // Armed ring is tool STATE ("I picked Alice; waiting for
    // the second pick"). Persists across temporary
    // overrides — the user may be panning briefly to see
    // their second-pick target. Always drawn when armed.
    // Sized to the body it rings, the way the focus ring is: a claim
    // is half a peer's width, so a ring drawn at a peer's radius would
    // float clear of the thing it is meant to be holding.
    drawArmedRing(
      frame.armedRingGfx,
      armedEntity.position.x,
      armedEntity.position.y,
      "endpoint" in armedEntity ? endpointBodyRadius(armedEntity.endpoint.id, claimsToward) : NODE_RADIUS,
      frame.marchOffsetPx,
      color,
      frame.viewport.scale.x,
    );
    // Wire preview is a PREVIEW — "if you click here, this
    // line becomes a session/message". When Space-pan or
    // Hand tool takes over (the verb at the cursor is a
    // pan), the click would NOT complete the pick; hide
    // the preview. Doctrine: previews of what-would-happen-
    // on-click derive from `resolveGesture`, not from raw
    // tool/modifier state. Synthesize a stage-empty hit —
    // pan-tier verbs (space-pan / hand-tool) override the
    // hit anyway, so the specific surface doesn't matter.
    const ctxNow = frame.resolvedGestureCtxRef.current;
    const previewVerb = resolveGesture({
      hit: { surface: "stage-empty" },
      modifiers: NO_MODIFIERS,
      spaceHeld: ctxNow.spaceHeld,
      activeTool: ctxNow.activeTool,
    });
    if (frame.cursorWorld.hasValue && !verbIsPan(previewVerb)) {
      drawMarchingLine(
        frame.wirePreviewGfx,
        armedEntity.position.x,
        armedEntity.position.y,
        frame.cursorWorld.x,
        frame.cursorWorld.y,
        frame.marchOffsetPx,
        color,
        frame.viewport.scale.x,
      );
      // Over empty canvas, Open Session runs out to an end nothing has
      // attributed, so the wire ends in the body that click would make.
      // Over a node the click lands on that node instead, and there is
      // nothing to mint — the wire simply reaches it.
      if (armed.tool === "open-session" && frame.hoverRef.current === null) {
        frame.ghostEndGfx.clear();
        frame.ghostEndGfx.position.set(frame.cursorWorld.x, frame.cursorWorld.y);
        drawLooseEndBody(
          frame.ghostEndGfx,
          LOOSE_END_ALONE,
          PROFILE_FALLBACK_COLOR,
          color,
        );
      } else {
        frame.ghostEndGfx.clear();
      }
    } else {
      frame.wirePreviewGfx.clear();
      frame.ghostEndGfx.clear();
    }
    frame.overlayDirty = true;
  } else if (frame.overlayDirty) {
    frame.armedRingGfx.clear();
    frame.wirePreviewGfx.clear();
    frame.ghostEndGfx.clear();
    frame.overlayDirty = false;
  }
  // PixiJS doesn't auto-install `CullerPlugin` (it'd cull
  // against `renderer.screen` — the whole canvas, including
  // under-panel area). Calling the shared culler ourselves
  // lets us pass the marker rect as the view. Default ticker
  // priority runs this before render (LOW).
  Culler.shared.cull(frame.stageScene, frame.cullView);
}
