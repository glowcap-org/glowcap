/**
 * Builder node-drag on the stage: tap vs translate, group follow, and
 * two-click arming while the pointer is captured.
 *
 * `Stage.tsx` is the React host. `use-stage-scene.ts` owns the Pixi scene.
 * This module owns the gesture that
 * starts on a peer or endpoint body — threshold, axis lock, sibling
 * offsets, and closing the engine transaction on the same handler
 * that opened it. Empty-stage rubber-band stays in
 * `use-stage-empty-gestures.ts`.
 */

import type { MutableRefObject } from "react";
import { type Application, type Container, type FederatedPointerEvent } from "pixi.js";
import type { Viewport } from "pixi-viewport";
import { entityKey, type EntityRefKey, isTwoClickTool, type SurfaceGestureCtx } from "../interactions/types.ts";
import type { Engine } from "../engine/engine.ts";
import type { Vec2 } from "../engine/world.ts";
import { safeListener } from "./safeTick.ts";
import type { SelectMode, StageHover, StageSelection } from "./types.ts";
import type { PeerSprite, StartNodeDrag } from "./sprites/types.ts";

/** World cursor the wire preview reads. Node-drag writes it while
 *  pointer-capture suppresses the viewport's own pointermove. */
export type StageNodeDragCursor = {
  x: number;
  y: number;
  hasValue: boolean;
};

export type StageNodeDragHost = {
  app: Application;
  engine: Engine;
  viewport: Viewport;
  peerSprites: Map<string, PeerSprite>;
  selectionRef: MutableRefObject<ReadonlySet<EntityRefKey>>;
  hoverRef: MutableRefObject<StageHover>;
  onSelectRef: MutableRefObject<
    | ((
      sel: StageSelection,
      opts?: { mode?: SelectMode },
    ) => void)
    | undefined
  >;
  onNodeDragRef: MutableRefObject<
    | ((
      kind: "peer" | "endpoint",
      nodeId: string,
      phase: "start" | "move" | "end",
      worldX: number,
      worldY: number,
      group?: ReadonlyArray<{
        kind: "peer" | "endpoint";
        id: string;
        x: number;
        y: number;
      }>,
    ) => void)
    | undefined
  >;
  resolvedGestureCtxRef: MutableRefObject<SurfaceGestureCtx>;
  cursor: StageNodeDragCursor;
  cleanups: Array<() => void>;
};

export type StageNodeDrag = {
  startNodeDrag: StartNodeDrag;
  /** Close an in-flight translate without selecting. Region resize
   *  and scene teardown use this so an open engine transaction ends. */
  abortDrag: () => void;
};

export function createStageNodeDrag(host: StageNodeDragHost): StageNodeDrag {
  const {
    app,
    engine,
    viewport,
    peerSprites,
    selectionRef,
    hoverRef,
    onSelectRef,
    onNodeDragRef,
    resolvedGestureCtxRef,
    cursor,
    cleanups,
  } = host;

  // Builder peer-drag bookkeeping. Each peer body's pointerdown
  // calls `startPeerDrag` and stops propagation; the viewport's
  // own `globalpointermove` then routes each move through the
  // captured handler until pointerup. `pickupOffset` preserves
  // the cursor↔peer-center offset across the drag; `startScreen*`
  // anchors the tap-vs-drag threshold check.
  //
  // `boundHandler` is captured at the moment the gesture
  // commits to a real drag (first move past the threshold) so
  // the entire start/move/end lifecycle uses ONE handler. Prop
  // changes mid-drag — spacebar pressed, tool switched, mode
  // flipped — can't orphan an open engine transaction by
  // pointing the ref at `undefined` between `start` and `end`.
  type NodeDragHandler = (
    kind: "peer" | "endpoint",
    nodeId: string,
    phase: "start" | "move" | "end",
    worldX: number,
    worldY: number,
    group?: ReadonlyArray<{
      kind: "peer" | "endpoint";
      id: string;
      x: number;
      y: number;
    }>,
  ) => void;
  /** Members of the selection that ride along when the lead node
   *  is dragged. Each carries its world-space offset from the
   *  lead node's starting position so we can translate the group
   *  by a single delta per move event. Empty when the dragged
   *  node isn't in the selection or the selection is just it. */
  type DragSibling = {
    kind: "peer" | "endpoint";
    nodeId: string;
    offsetX: number;
    offsetY: number;
  };
  type ActiveDrag = {
    kind: "peer" | "endpoint";
    nodeId: string;
    siblings: DragSibling[];
  };
  /** Lead plus siblings at the lead's current target — one list the
   *  host pins in a single placement pass. */
  const dragGroup = (
    drag: ActiveDrag,
    leadX: number,
    leadY: number,
  ): Array<{
    kind: "peer" | "endpoint";
    id: string;
    x: number;
    y: number;
  }> => [
    { kind: drag.kind, id: drag.nodeId, x: leadX, y: leadY },
    ...drag.siblings.map((s) => ({
      kind: s.kind,
      id: s.nodeId,
      x: leadX + s.offsetX,
      y: leadY + s.offsetY,
    })),
  ];
  let activeDrag:
    | {
      kind: "peer" | "endpoint";
      nodeId: string;
      pointerId: number;
      moved: boolean;
      pickupOffsetX: number;
      pickupOffsetY: number;
      lastTargetX: number;
      lastTargetY: number;
      startScreenX: number;
      startScreenY: number;
      /** Modifier-derived select mode captured at pointerdown
       *  (Adobe convention: shift = add, shift+option = remove,
       *  neither = replace). The click branch of finishDrag
       *  reports it to `onSelect` so a no-drag tap on a peer
       *  applies the right semantic. */
      modeAtDown: SelectMode;
      /** Lead peer's starting world position; siblings move
       *  with `lead.target + sibling.offset`. */
      leadStartX: number;
      leadStartY: number;
      siblings: DragSibling[];
      boundHandler: NodeDragHandler | null;
      /** True once the drag crossed the threshold in a two-click
       *  tool (Open Session / Send Message) and we already armed
       *  peer A via `onSelect`. Makes `finishDrag` skip the
       *  press-peer re-arm so a drag-to-B doesn't fire `A, A, B`
       *  (which would cancel via `advanceTwoClick`'s same-peer
       *  branch). */
      armedDuringDrag: boolean;
    }
    | null = null;
  // Matches PixiJS's built-in tap threshold so tap-vs-drag is
  // consistent with the viewport's `clicked` event.
  const DRAG_THRESHOLD_PX = 4;
  const startNodeDrag: StartNodeDrag = (
    kind,
    nodeId,
    pointerId,
    screenX,
    screenY,
    nodeWorldX,
    nodeWorldY,
    modeAtDown,
  ) => {
    // Capture so PixiJS keeps receiving moves/ups even when the
    // cursor crosses a side panel or leaves the window. Some
    // browsers reject non-primary-pointer capture; the window-
    // level pointerup fallback handles those.
    try {
      app.canvas.setPointerCapture(pointerId);
    } catch {
      // best-effort
    }
    const cursorWorld = viewport.toWorld(screenX, screenY);
    // Group-drag setup: if the lead peer is in the selection,
    // every OTHER selected peer rides along with the same world
    // delta. Capture each sibling's offset from the lead peer's
    // starting position once; per-move math then is just
    // `sibling.target = leadTarget + sibling.offset`.
    const sel = selectionRef.current;
    const leadKey = entityKey({ kind, id: nodeId });
    const siblings: DragSibling[] = [];
    if (sel.has(leadKey) && sel.size > 1) {
      // Both node kinds ride along, because both hold a position the
      // group translate can write. A selection mixing peers and ends
      // moves as one thing, which is what the user picked.
      const led: { kind: "peer" | "endpoint"; id: string; pos: Vec2 }[] = [];
      for (const e of engine.queries.peers) {
        led.push({ kind: "peer", id: e.peer.id, pos: e.position });
      }
      for (const e of engine.queries.endpoints) {
        led.push({ kind: "endpoint", id: e.endpoint.id, pos: e.position });
      }
      for (const n of led) {
        if (n.kind === kind && n.id === nodeId) continue;
        if (!sel.has(entityKey({ kind: n.kind, id: n.id }))) continue;
        siblings.push({
          kind: n.kind,
          nodeId: n.id,
          offsetX: n.pos.x - nodeWorldX,
          offsetY: n.pos.y - nodeWorldY,
        });
      }
    }
    activeDrag = {
      kind,
      nodeId,
      pointerId,
      moved: false,
      pickupOffsetX: nodeWorldX - cursorWorld.x,
      pickupOffsetY: nodeWorldY - cursorWorld.y,
      lastTargetX: nodeWorldX,
      lastTargetY: nodeWorldY,
      startScreenX: screenX,
      startScreenY: screenY,
      modeAtDown,
      leadStartX: nodeWorldX,
      leadStartY: nodeWorldY,
      siblings,
      boundHandler: null,
      armedDuringDrag: false,
    };
  };
  viewport.on("globalpointermove", (ev: FederatedPointerEvent) => {
    if (!activeDrag || activeDrag.pointerId !== ev.pointerId) return;
    const dragPt = viewport.toWorld(ev.global.x, ev.global.y);
    // Keep the outer cursorWorld in sync during a captured drag.
    // Pointer-capture stops `viewport.on("pointermove")` from
    // firing while the canvas holds the pointer, so without this
    // the wire-preview tail would freeze the moment the user
    // started dragging on a peer in the two-click tools.
    cursor.x = dragPt.x;
    cursor.y = dragPt.y;
    cursor.hasValue = true;
    let targetX = dragPt.x + activeDrag.pickupOffsetX;
    let targetY = dragPt.y + activeDrag.pickupOffsetY;
    // Shift-axis-lock (Adobe / Macromedia convention). Live —
    // recomputed each move, not latched at shift-press, so
    // crossing the 45° line from origin flips the locked
    // axis (matches Photoshop / Illustrator Move tool with
    // shift held). Reference point is the LEAD peer's start,
    // not the last unconstrained position: lock + unlock +
    // re-lock returns the user to a predictable axis.
    // Releasing shift drops the lock; the cursor snaps back
    // to its actual position immediately. Group drag inherits
    // the lock for free — siblings translate by the SAME
    // delta from `targetX/Y`, so a locked lead pulls the
    // whole group along one axis.
    if (ev.shiftKey) {
      const dx = targetX - activeDrag.leadStartX;
      const dy = targetY - activeDrag.leadStartY;
      if (Math.abs(dx) >= Math.abs(dy)) {
        targetY = activeDrag.leadStartY;
      } else {
        targetX = activeDrag.leadStartX;
      }
    }
    activeDrag.lastTargetX = targetX;
    activeDrag.lastTargetY = targetY;
    // Sub-threshold movement is bookkeeping only; crossing the
    // threshold commits to drag — bind the host handler NOW
    // and fire `"start"` against it. The same `boundHandler`
    // services every subsequent `"move"` and the eventual
    // `"end"` so a mid-drag prop change (spacebar pressed,
    // tool switched) can't leak the engine transaction.
    if (!activeDrag.moved) {
      const dx = ev.global.x - activeDrag.startScreenX;
      const dy = ev.global.y - activeDrag.startScreenY;
      if (Math.hypot(dx, dy) < DRAG_THRESHOLD_PX) return;
      const handler = onNodeDragRef.current;
      if (!handler) {
        activeDrag.moved = true;
        // Which mode we are in, asked of the tool rather than inferred from
        // the missing handler. "No translate handler" was standing in for
        // "a two-click tool is active", and it is also true in Play and
        // Live, where nothing can be moved and nothing can be armed — so
        // dragging a peer there ran the arming path and selected it, and a
        // reader who saw the peer stay put had opened the Inspector on it
        // without asking.
        if (isTwoClickTool(resolvedGestureCtxRef.current.activeTool)) {
          // Arm peer A on threshold cross so the dotted wire preview tracks
          // the cursor for the rest of the drag. `finishDrag` then only
          // fires the second-pick `onSelect` when the release lands on a
          // different peer.
          activeDrag.armedDuringDrag = true;
          onSelectRef.current?.(
            { kind: activeDrag.kind, id: activeDrag.nodeId },
            { mode: activeDrag.modeAtDown },
          );
        }
        // Otherwise the gesture is a drag this mode has no verb for. It is
        // marked moved so the release is not read as a tap, and the
        // selection is left exactly as the reader had it.
        //
        // No test holds any of this: the suite cannot drive a Pixi viewport
        // through a captured pointer drag, so what the drag closure does
        // with a gesture is browser evidence rather than suite evidence.
        // Checked by hand across the cases the change reaches — in Play and
        // with the Add-peer tool a drag off a peer now moves nothing and
        // selects nothing, a tap still selects in every mode, a marquee
        // still replaces, and Open Session still opens a session when
        // dragged from one peer to another.
        return;
      }
      activeDrag.moved = true;
      activeDrag.boundHandler = handler;
      // One start for the whole gesture: lead plus every sibling at
      // its baseline-offset position. The host opens ONE engine
      // transaction and pins the group in one placement pass —
      // N sibling start/move/end callbacks used to mean N layout
      // solves per pointermove. Skip `"move"` on this same event:
      // start already wrote these coordinates, and without a no-op
      // guard a second placement pass would anneal twice.
      handler(
        activeDrag.kind,
        activeDrag.nodeId,
        "start",
        targetX,
        targetY,
        dragGroup(activeDrag, targetX, targetY),
      );
      return;
    }
    activeDrag.boundHandler?.(
      activeDrag.kind,
      activeDrag.nodeId,
      "move",
      targetX,
      targetY,
      dragGroup(activeDrag, targetX, targetY),
    );
    // Two-click drag (Open Session / Send Message): sync hover
    // state to whatever peer is under the cursor. Pointer-capture
    // suppresses the peer body's own `pointerover`/`pointerout`
    // while we hold the pointer, so without this the hover ring
    // never lights up over the prospective second-pick peer.
    // Render path already gates the hover affordance through
    // `resolveGesture` — for `two-click-pick` over `stage-peer`
    // it returns a verb that arms, so just setting `hoverRef`
    // is enough to light the ring.
    if (activeDrag.armedDuringDrag) {
      const overPeerId = peerIdAtLocal(ev.global.x, ev.global.y);
      const cur = hoverRef.current;
      if (overPeerId === null) {
        if (cur && cur.kind === "peer") hoverRef.current = null;
      } else if (!cur || cur.kind !== "peer" || cur.id !== overPeerId) {
        hoverRef.current = { kind: "peer", id: overPeerId };
      }
    }
  });
  // Walk a Pixi hit-test result up to a peer body and return
  // its peer id. Used by `finishDrag` to detect "drag started
  // on peer A, released on peer B" for the two-click tools.
  // Iterating `peerSprites` (peer count is small) avoids
  // stashing a back-reference on every sprite body.
  const peerIdAtLocal = (
    localX: number,
    localY: number,
  ): string | null => {
    const target = app.renderer.events.rootBoundary.hitTest(
      localX,
      localY,
    );
    let cur: Container | null = target;
    while (cur) {
      for (const [pid, sprite] of peerSprites) {
        if (sprite.body === cur) return pid;
      }
      cur = cur.parent;
    }
    return null;
  };
  const finishDrag = (
    pointerId: number,
    fireSelect: boolean,
    // Canvas-local coords of the up event. Used to detect
    // "released on another peer" for two-click tools. Pass
    // the lead peer's last known target as a fallback for
    // off-canvas releases where no hit is meaningful.
    upLocalX: number,
    upLocalY: number,
  ) => {
    if (!activeDrag || activeDrag.pointerId !== pointerId) return;
    const wasDrag = activeDrag.moved;
    const kind = activeDrag.kind;
    const nodeId = activeDrag.nodeId;
    const lastX = activeDrag.lastTargetX;
    const lastY = activeDrag.lastTargetY;
    const mode = activeDrag.modeAtDown;
    const boundHandler = activeDrag.boundHandler;
    activeDrag = null;
    // 1. Real translate gesture: close the engine transaction
    //    on the SAME handler that opened it (even if the prop
    //    has since retargeted). Window fallbacks pass
    //    `fireSelect: false` since off-canvas releases aren't
    //    meaningful selections.
    if (wasDrag && boundHandler) {
      boundHandler(kind, nodeId, "end", lastX, lastY);
      return;
    }
    if (!fireSelect) return;
    // 2. Tap-on-peer OR Open-Session / Send-Message drag-to-peer.
    //    For two-click tools (no `onPeerDrag` handler bound,
    //    matching the `if (!handler)` arm in globalpointermove),
    //    a release on a DIFFERENT peer than the press fires
    //    onSelect twice — arm A then complete on B — so a
    //    single drag gesture is equivalent to two taps through
    //    `advanceTwoClick`. Release on the same peer, off-peer,
    //    or in Select tool falls back to the historic
    //    single-tap arm. Asked of the active tool, the same way
    //    the threshold-cross arm above asks: a missing translate
    //    handler used to stand in for this, and it is also
    //    missing in Play and Live.
    const upPeerId = isTwoClickTool(resolvedGestureCtxRef.current.activeTool)
      ? peerIdAtLocal(upLocalX, upLocalY)
      : null;
    // A tap selects; a drag does not. `wasDrag` rather than
    // `!armedDuringDrag`, which agreed with it in every case
    // that could reach here and stopped agreeing once a drag in
    // Play arms nothing: re-firing there would select the peer
    // on release, which is the same surprise moved one event
    // later. In a two-click tool the arm already happened on
    // threshold-cross, and re-firing onSelect on the same peer
    // would route through `advanceTwoClick`'s same-peer branch
    // and CANCEL the pick.
    if (!wasDrag) {
      onSelectRef.current?.(
        { kind, id: nodeId },
        { mode },
      );
    }
    if (upPeerId !== null && upPeerId !== nodeId) {
      onSelectRef.current?.(
        { kind: "peer", id: upPeerId },
        { mode },
      );
    }
  };
  viewport.on(
    "pointerup",
    (ev: FederatedPointerEvent) => finishDrag(ev.pointerId, true, ev.global.x, ev.global.y),
  );
  viewport.on(
    "pointerupoutside",
    (ev: FederatedPointerEvent) => finishDrag(ev.pointerId, false, ev.global.x, ev.global.y),
  );
  // Window fallback for off-canvas / off-document releases —
  // without this, `activeDrag` leaks and corrupts the next
  // gesture. The pointer-id check leaves unrelated pointers
  // (other touches, panel-resize handles) alone.
  // `safeListener` so a throw inside `finishDrag` surfaces once
  // through the error bus instead of escaping into the browser's
  // event dispatch path — drag/rename/paste land in this surface
  // soon and need the quarantine.
  const handleWindowPointerUp = safeListener<PointerEvent>(
    (ev) => {
      // Window-level release is off-host by definition —
      // `fireSelect: false` skips both the tap-arm and the
      // two-click drag-to-peer completion. Coords are unused
      // in that branch; pass 0 to satisfy the signature.
      finishDrag(ev.pointerId, false, 0, 0);
    },
  );
  // Two more ends, neither of which arrives on a pointer, so both
  // finish whichever pointer the drag is holding.
  //
  // The first is a window blur. Every other gesture surface in the
  // app already reads one as its interruption (`watchGestureEnd`),
  // and a modal takes the pointer by dispatching one
  // (`holdPointerForModal`), so a peer drag that did not listen was
  // the one gesture a dialog could open over and leave running
  // underneath it.
  const endDragUnheld = () => {
    if (activeDrag) finishDrag(activeDrag.pointerId, false, 0, 0);
  };
  const handleWindowBlur = safeListener<Event>(() => endDragUnheld());
  globalThis.addEventListener("pointerup", handleWindowPointerUp);
  globalThis.addEventListener("pointercancel", handleWindowPointerUp);
  globalThis.addEventListener("blur", handleWindowBlur);
  cleanups.push(() => {
    globalThis.removeEventListener("pointerup", handleWindowPointerUp);
    globalThis.removeEventListener("pointercancel", handleWindowPointerUp);
    globalThis.removeEventListener("blur", handleWindowBlur);
    // The second is the scene going away, and no listener can
    // report it, because this cleanup is what removes them. A live
    // drag holds an engine transaction opened at drag-start, and
    // the engine records history only at depth zero, so a scene
    // torn down mid-drag left the app with nothing undoable. An
    // `engine` identity change is enough to do it.
    endDragUnheld();
  });

  return {
    startNodeDrag,
    abortDrag: () => {
      if (activeDrag?.boundHandler) {
        activeDrag.boundHandler(
          activeDrag.kind,
          activeDrag.nodeId,
          "end",
          activeDrag.lastTargetX,
          activeDrag.lastTargetY,
        );
      }
      activeDrag = null;
    },
  };
}
