import { useEffect, useRef } from "react";
import {
  Container,
  Culler,
  type FederatedPointerEvent,
  Graphics,
  Point,
  Rectangle,
} from "pixi.js";
import { Viewport } from "pixi-viewport";
import {
  cursorFor,
  type ToolWillPick,
  verbArmsForTool,
  verbIsPan,
  verbSelectsEntity,
} from "../interactions/cursor.ts";
import { nodeKindOf } from "../schema/topology.ts";
import { resolveGesture } from "../interactions/gesture-resolver.ts";
import { layerInteractivity } from "../interactions/layer-interactivity.ts";
import { isTextInputTarget } from "../interactions/text-input-target.ts";
import {
  type Effect,
  entityKey,
  type EntityRefKey,
  type Hit,
  isTwoClickTool,
  NO_MODIFIERS,
  type PointerMachineState,
  type ResolvedGesture,
  stageHitFor,
  type SurfaceGestureCtx,
} from "../interactions/types.ts";
import { useSurfacePointer } from "../interactions/use-surface-pointer.ts";
import {
  useSurfaceWheel,
  type WheelEffect,
} from "../interactions/use-surface-wheel.ts";
import type { Engine } from "../engine/engine.ts";
import { findNode, type Vec2 } from "../engine/world.ts";
import { claimTargets } from "../engine/session-geometry.ts";
import {
  drawArmedRing,
  drawLooseEndBody,
  drawMarchingLine,
  LOOSE_END_ALONE,
  NODE_RADIUS,
} from "./draw-helpers.ts";
import { PROFILE_FALLBACK_COLOR, themedColors } from "./palette.ts";
import { twoClickAccepts } from "../builder/helpers.ts";
import { type Theme } from "../ui/tokens.ts";
import { safeListener, safeTick } from "./safeTick.ts";
import { useUnifiedCanvas } from "./UnifiedCanvas.tsx";
import {
  type EdgeSprite,
  endpointBodyRadius,
  type EndpointSprite,
  MESSAGE_RADIUS,
  type MessageSprite,
  type PeerSprite,
  renderFrame,
  type RenderFrameArgs,
  type StartNodeDrag,
} from "./render-frame.ts";
import {
  clampRectToBounds,
  paintMarchingAntsBand,
  rectCircleOverlap,
  rectFromCorners,
  rectSegmentOverlap,
} from "./geometry.ts";
import { gridTierOpacity, populateGridLOD, WORLD_SIZE } from "./grid-lod.ts";
import { stageCamera } from "./stage-camera.ts";
import {
  clampStageZoom,
  DEFAULT_STAGE_VIEW,
  fitStageView,
  initialStageView,
  MAX_STAGE_SCALE,
  MIN_STAGE_SCALE,
  steppedStageZoom,
  unionBounds,
} from "./stage-view.ts";

// Stage's pure data types live in `./types.ts` so consumers that only need a
// `StageSelection` shape don't drag in Pixi + React. Imported from there, not
// re-exported from here: a second door onto one type is a second name for it.
import {
  type PeerActivity,
  type SelectMode,
  selectModeFromModifiers,
  type StageHover,
  type StageSelection,
  type StageVisibility,
} from "./types.ts";

/**
 * Stage scene — a sub-container of the unified PixiJS canvas, bound
 * to a DOM region marker for layout. The scene tracks the marker's
 * `getBoundingClientRect()` each frame via the `RegionRegistry`.
 *
 *   app.stage
 *   └── stageScene (positioned to marker rect, masked + cullable)
 *       └── Viewport (pixi-viewport: pan / pinch / wheel / decelerate)
 *           ├── gridLayer    (world-space dot grid, three LOD tiers, tiled)
 *           ├── edgeLayer
 *           ├── peerLayer
 *           ├── labelLayer
 *           └── messageLayer (drawn last so in-flight dots stay on top)
 */

export type StageProps = {
  engine: Engine;
  /** Click on a Stage entity (or `null` for empty stage). `opts.mode`
   * carries the modifier-derived intent (see {@link SelectMode}).
   * Defaulting to "replace" matches the no-modifier behavior. */
  onSelect?: (
    selection: StageSelection,
    opts?: { mode?: SelectMode },
  ) => void;
  theme: Theme;
  visibility: StageVisibility;
  /**
   * Fires on a click of empty viewport space. World-space coords
   * (post-viewport-transform). When set, an empty-canvas click does
   * NOT also call `onSelect(null)` — the assumption is the builder
   * tool is consuming the click. The `| undefined` is for
   * `exactOptionalPropertyTypes`: callers pass `cond ? fn : undefined`.
   */
  onCanvasClick?: ((worldX: number, worldY: number) => void) | undefined;
  /**
   * Node-body drag lifecycle, phases:
   *   `"start"` — cursor world coords at pointerdown.
   *   `"move"`  — target node position (cursor + pickup offset).
   *   `"end"`   — last known target position.
   *
   * When set, node bodies become draggable; when undefined, they're
   * click-only. A node is a peer or an unattributed session end: both
   * hold a place on the stage and both take an authored position, and the
   * `kind` says which table the host writes that position to.
   *
   * On `"start"` and `"move"`, `group` lists every node in the gesture
   * (lead first, then multi-select siblings) at their target positions.
   * The host applies the whole group in one placement pass; `"end"` has
   * no group — it only closes the transaction.
   */
  onNodeDrag?:
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
    | undefined;
  /** First-picked peer waiting for its partner in a two-click
   * tool. Drives the node-editor "wire preview" overlay: a marching
   * dashed ring on the armed peer and a dashed line from its edge
   * to the cursor. `tool` colors the overlay (session vs message).
   */
  armedNode?:
    | { nodeId: string; tool: "open-session" | "send-message" }
    | undefined;
  /** Single source of truth for the gesture pipeline: the resolver,
   * the hover-halo preview, the canvas cursor, and layer
   * pointer-events (interaction model § 7, via `layerInteractivity`)
   * all read this. While `spaceHeld` is true or the active tool is
   * `hand`, every sprite layer falls pointer-silent so the FSM's pan
   * verbs receive the gesture.
   *
   * `modifiers` are the keys held right now, from the app's one
   * keyboard listener rather than from a pointer event, because a
   * modifier pressed while the pointer sits still still changes what
   * the next click would do and the cursor has to say so. */
  gestureCtx: SurfaceGestureCtx;
  /** Called when the user finishes a rubber-band drag on empty
   * stage. `entities` is the set of entity keys that overlapped
   * the rect at drag-end; `mode` reflects the modifiers latched
   * during the gesture:
   *   "replace" — no modifier; replace selection.
   *   "add"     — shift; add captured to selection.
   *   "remove"  — shift+option; remove captured from selection.
   * App routes to the selection-store. */
  onRubberBandCommit?: (
    entities: ReadonlySet<EntityRefKey>,
    mode: "replace" | "add" | "remove",
  ) => void;
  /** THE selection — the set of entities (peers / sessions /
   * messages) the user has selected. SOLE source of truth for
   * which Stage entities paint their selected halo. Single-click
   * on an entity replaces this set with `[that entity]`; shift-
   * click toggles in/out; a marquee replaces (or shift-marquee
   * unions). Inspector follows the store's `anchor` slot, which
   * the same store reducer keeps consistent with this set. */
  selection?: ReadonlySet<EntityRefKey>;
  /** Anchor — the Inspector-follow entity, always also in
   * `selection` when set. Stage paints an additional inner
   * ring on the anchor's halo so the user can see WHICH
   * selected entity the Inspector tracks under multi-select. */
  anchor?: EntityRefKey | null;
};

// Entity shapes moved to `engine/world.ts` so the engine layer
// owns the canonical type for "what iterating queries.peers
// gives you". Re-imported here for the sprite-sync signatures
// below.

// Sprite shapes (`PeerSprite` / `EdgeSprite` / `MessageSprite`), the
// constants, and `renderFrame` itself live in `./render-frame.ts`; the
// pure-data render types (`PeerActivity`, `StageSelection`) live in
// `./types.ts`. `Stage` owns scene wiring (viewport, FSM, drag, layer
// creation) and allocates the sprite Maps but never reaches into a sprite's
// internals.

/** What a frame starts with before its first tick has resolved a claim: an
 *  empty resolution, so `renderArgs` is complete from the moment it is built
 *  rather than carrying a null nobody may read. */
const EMPTY_CLAIMS: ReadonlyMap<string, string> = new Map();

/**
 * How still the camera has to be before its position is written to the document,
 * in milliseconds.
 *
 * Long enough that one gesture is one write — a wheel or a drag arrives in a
 * stream of frames, and the reader has not chosen anything until they stop — and
 * short enough that letting go and reading the panel shows the number they landed
 * on. A quarter second is past the end of a scroll's inertia and under the time it
 * takes to look.
 */
const VIEW_SETTLE_MS = 250;

/** The pending settle report, and the view it is for. Keyed by engine so a stage
 *  rebuilt around a replaced buffer starts its own wait rather than inheriting
 *  the previous one's. */
const settling = new WeakMap<
  Engine,
  { timer: number; view: { zoom: number; center: { x: number; y: number } } }
>();

/**
 * Say where the camera came to rest, once it has stopped moving.
 *
 * Each call restarts the wait, so a stream of frames collapses into one report
 * after the last of them. Nothing is lost if the reader keeps moving: the view
 * reported is always the latest one seen.
 *
 * It reports rather than writes. Looking around is reading, so it changes no
 * document and records no history — what it does is let the document panel offer:
 * the Opens-at row's button compares this against what the document stores and
 * lights up when they differ. The settle is what makes that cheap enough to
 * publish at all, since it turns sixty frames of a pan into one wake.
 */
function noteViewWhenSettled(
  engine: Engine,
  zoom: number,
  centerX: number,
  centerY: number,
): void {
  const pending = settling.get(engine);
  if (
    pending && pending.view.zoom === zoom &&
    pending.view.center.x === centerX &&
    pending.view.center.y === centerY
  ) {
    // A still camera republishes the same numbers every frame; restarting the
    // timer for those would mean the write never lands.
    return;
  }
  // Three numbers rather than the view they describe, because this is called on
  // every frame and the common answer is "nothing moved". Building the view to
  // compare it would allocate one object and one center per frame of a still
  // stage, to throw both away.
  if (pending) clearTimeout(pending.timer);
  const view = { zoom, center: { x: centerX, y: centerY } };
  const timer = setTimeout(() => {
    settling.delete(engine);
    stageCamera.publishSettledView(view);
  }, VIEW_SETTLE_MS);
  settling.set(engine, { timer, view });
}

/**
 * Breathing room Fit leaves around the content, in screen pixels.
 *
 * Screen pixels because it is margin for a reader rather than a fact about the
 * world, and generous enough that a node's focus ring and caption — which hold
 * their own screen size and so are not in the world bounds Fit measures — still
 * have somewhere to be.
 */
const FIT_PADDING_PX = 24;

/** Shared empty-set sentinel for the `selection` / `previewSelection`
 * refs so the no-selection case doesn't churn set identity. */
const EMPTY_ENTITY_SET: ReadonlySet<EntityRefKey> = new Set();

export function Stage(
  {
    engine,
    onSelect,
    theme,
    visibility,
    onCanvasClick,
    onNodeDrag,
    armedNode,
    gestureCtx,
    onRubberBandCommit,
    selection,
    anchor,
  }: StageProps,
) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  // Refs let the long-lived Pixi ticker read current prop values
  // without remounting the scene each time a prop changes.
  const themeRef = useRef<Theme>(theme);
  themeRef.current = theme;
  // The view this document asks to open at, read once when the scene mounts.
  // Through a ref like everything else the scene effect needs: it must not be
  // an effect dependency, or saving a new opening view would tear the whole
  // Pixi scene down and rebuild it.
  const docInitialViewRef = useRef(engine.doc.initialView);
  docInitialViewRef.current = engine.doc.initialView;
  // Selection ref: the ticker reads the current set without
  // remounting the scene when it shifts. Entity-keyed so a single
  // ref serves all three sprite kinds (peer / session / message).
  const selectionRef = useRef<ReadonlySet<EntityRefKey>>(
    selection ?? EMPTY_ENTITY_SET,
  );
  selectionRef.current = selection ?? EMPTY_ENTITY_SET;
  // Anchor ref: same pattern as selectionRef. The per-tick paint
  // reads `.current` so anchor changes don't tear down the scene.
  const anchorRef = useRef<EntityRefKey | null>(anchor ?? null);
  anchorRef.current = anchor ?? null;
  // Preview-selection ref: while a rubber-band drag is in flight,
  // entities currently inside the marquee paint a hover-like ring
  // (the "would be selected on release" affordance). Stored
  // separately from `selectionRef` because the commit only lands
  // on drag-end.
  const previewSelectionRef = useRef<ReadonlySet<EntityRefKey>>(
    EMPTY_ENTITY_SET,
  );
  const onCanvasClickRef = useRef(onCanvasClick);
  onCanvasClickRef.current = onCanvasClick;
  const onNodeDragRef = useRef(onNodeDrag);
  onNodeDragRef.current = onNodeDrag;
  // `onSelect` is held via ref so a fresh `handleSelect` closure
  // (which changes whenever App state.firstPickNodeId / tool /
  // mode changes) doesn't tear down and rebuild the Pixi scene.
  // Sprite pointer listeners read `onSelectRef.current` so they
  // always see the latest. Without this, the scene-init effect's
  // `[ctx, engine, onSelect]` deps cause a full rebuild on every
  // selection-state change — and pointer events landing during
  // the rebuild are silently dropped (loses two-click commits).
  const onSelectRef = useRef(onSelect);
  onSelectRef.current = onSelect;
  const visibilityRef = useRef<StageVisibility>(visibility);
  visibilityRef.current = visibility;
  // Captured from inside the scene-init effect so the smaller
  // panEnabled effect below can pause/resume the drag plugin
  // without depending on the heavy init.
  const viewportRef = useRef<Viewport | null>(null);
  const messageLayerRef = useRef<Container | null>(null);
  const edgeLayerRef = useRef<Container | null>(null);
  const peerLayerRef = useRef<Container | null>(null);
  const armedNodeRef = useRef(armedNode);
  armedNodeRef.current = armedNode;

  // A Stage hover as the typed `Hit` the resolver consumes, so the per-tick
  // render gate asks affordances of the SAME resolver the click pipeline asks.
  // The mapping itself is `stageHitFor`, next to the `hitEntityRef` that reads
  // it back the other way; all this adds is that no hover is no hit.
  const stageHoverToHit = (h: StageHover): Hit | null =>
    h === null ? null : stageHitFor(h);

  // The PixiJS canvas (shared with Timeline / Overview / Scrubber via
  // the unified-canvas architecture) is the real event target — the
  // Stage's marker div sits OVER it with `pointer-events: none` so
  // Pixi's sprite hit-testing works. Hooks attach to the canvas; a
  // marker-rect bounds check in `makeStageHit` keeps stage-only
  // interactions from firing for events in the Timeline / Overview
  // regions of the same canvas.
  const unifiedCanvasCtx = useUnifiedCanvas();
  const canvas = (unifiedCanvasCtx?.app.canvas as HTMLCanvasElement | null) ??
    null;

  // Wheel pipeline (interaction model § 8.2). Replaces pixi-viewport's
  // `.wheel()` plugin. The hook fires a `WheelEffect` per wheel event
  // (zoom-step or pan-step); we apply it to the viewport in place.
  const handleWheel = (effect: WheelEffect) => {
    const viewport = viewportRef.current;
    if (!viewport) return;
    // Bounds check: the canvas is shared with Timeline / Overview;
    // ignore wheel events whose cursor isn't in the Stage region.
    // Only zoom-step carries a pivot today; pan-step skips the check
    // (rare in practice — trackpad horizontal swipes anywhere on
    // the canvas pan the stage, which is the right behavior since
    // the stage is the primary spatial surface).
    if (effect.kind === "zoom-step") {
      const host = hostRef.current;
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
    }
    if (effect.kind === "zoom-step") {
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
    } else {
      // Horizontal pan from trackpad swipe or Shift+wheel.
      viewport.position.x -= effect.delta.dx;
      viewport.position.y -= effect.delta.dy;
    }
  };
  useSurfaceWheel(canvas, "stage-empty", "spatial", {
    onEffect: handleWheel,
  });

  /**
   * A press on the stage hands the keyboard back to the stage.
   *
   * The canvas is deliberately not focusable, and the stage's own pointer
   * handling refuses the default that would move focus, so a click here does not
   * blur whatever had it. That is right for a button — the reader keeps their
   * shortcuts — and wrong for a TEXT FIELD, because every keyboard pipeline steps
   * aside while one is focused (`isTextInputTarget`). A reader who typed a title,
   * clicked the stage and pressed Space got a space in the title instead of a pan,
   * and nothing on screen said why.
   *
   * Only a text surface is blurred. A focused button is left alone, since it
   * swallows nothing and taking its focus would undo the ring a keyboard user is
   * navigating by.
   *
   * Capture phase, because the stage's own handlers call `preventDefault` on the
   * way down and this has to run before they do.
   */
  useEffect(() => {
    if (!canvas) return;
    const handOverKeyboard = () => {
      const active = globalThis.document?.activeElement;
      if (isTextInputTarget(active)) (active as HTMLElement).blur();
    };
    canvas.addEventListener("pointerdown", handOverKeyboard, { capture: true });
    return () =>
      canvas.removeEventListener("pointerdown", handOverKeyboard, {
        capture: true,
      });
  }, [canvas]);

  // ─── Empty-stage gestures (interaction model § 8.1) ────────────────
  //
  // The host-level pointer adapter handles rubber-band selection and
  // spacebar-pan; sprite hits keep firing their own Pixi listeners
  // (peer-drag + onSelect). `makeStageHit` consults Pixi's own
  // hit-test (see below) so the FSM doesn't double-fire for sprite
  // clicks — that's the single source of truth for "did this click
  // land on an interactive sprite".
  //
  // Rubber-band rect bounds in host coords; null when no band-drag is
  // in flight. Painted into `rubberBandOverlayRef`.
  const rubberBandRef = useRef<
    | { startX: number; startY: number; curX: number; curY: number }
    | null
  >(null);
  const rubberBandOverlayRef = useRef<Graphics | null>(null);
  const onRubberBandCommitRef = useRef(onRubberBandCommit);
  onRubberBandCommitRef.current = onRubberBandCommit;

  // Gesture context ref for the resolver / FSM / cursor — the ticker
  // and event handlers read the latest value without re-mounting.
  const resolvedGestureCtxRef = useRef<StageProps["gestureCtx"]>(gestureCtx);
  resolvedGestureCtxRef.current = gestureCtx;

  // Producer for the host-level FSM. Returns `null` when:
  //   - the event is outside the Stage's marker region (events on
  //     the same canvas in Timeline / Overview area), or
  //   - the click landed on an interactive Pixi sprite under one
  //     of our layers (so the FSM stays out — the sprite's own
  //     click / drag handler takes the gesture).
  // Otherwise returns `stage-empty`.
  //
  // We use Pixi's own hit-test (`rootBoundary.hitTest`) instead
  // of trying to observe bubbled pointerdowns at the layer level
  // — peer sprites `stopPropagation` to claim peer-drag, so the
  // layer never sees the event. Pixi's hit-test runs the same
  // logic Pixi uses internally to decide which sprite to dispatch
  // to, so it's the single source of truth for "is the click on
  // an interactive sprite".
  const scratchHitPoint = useRef(new Point(0, 0));
  const makeStageHit = (
    ev: { clientX: number; clientY: number; target: EventTarget | null },
  ): (Hit & { surface: "stage-empty" }) | null => {
    const host = hostRef.current;
    if (host) {
      const r = host.getBoundingClientRect();
      if (
        ev.clientX < r.left || ev.clientX > r.right ||
        ev.clientY < r.top || ev.clientY > r.bottom
      ) {
        return null;
      }
    }
    const app = unifiedCanvasCtx?.app;
    if (app && canvas) {
      const c = canvas.getBoundingClientRect();
      const p = scratchHitPoint.current;
      p.set(ev.clientX - c.left, ev.clientY - c.top);
      const target = app.renderer.events.rootBoundary.hitTest(p.x, p.y);
      if (isInteractiveSpriteHit(target)) return null;
    }
    return { surface: "stage-empty" };
  };

  // Walk up from a hit-test result to one of our interactive
  // entity layers. The viewport itself (and its non-interactive
  // children — grid, labels, overlay) doesn't count as a sprite
  // hit; only peer / edge / message sprites do.
  const isInteractiveSpriteHit = (target: Container | null): boolean => {
    if (!target) return false;
    let cur: Container | null = target;
    while (cur) {
      if (
        cur === peerLayerRef.current ||
        cur === edgeLayerRef.current ||
        cur === messageLayerRef.current
      ) {
        return true;
      }
      cur = cur.parent;
    }
    return false;
  };

  // Convert a DOM client coord to viewport-world coords.
  //
  // `viewport.toWorld` delegates to PixiJS's `toLocal`, which
  // accepts a GLOBAL (canvas-local) point and walks the parent
  // chain — including `stageScene.position` (the sidebar/topbar
  // offset). The unified canvas is `position: fixed; inset: 0`,
  // so DOM clientX/Y already equals pixi global. Subtracting
  // `host.rect.left/top` here would double-subtract that offset
  // and place every world coord too far up-left by the
  // sidebar/topbar size — exactly the Add-Peer-lands-offset bug.
  const clientToWorld = (
    clientX: number,
    clientY: number,
  ): { x: number; y: number } | null => {
    const viewport = viewportRef.current;
    if (!viewport) return null;
    const world = viewport.toWorld(clientX, clientY);
    return { x: world.x, y: world.y };
  };

  // Paint (or clear) the rubber-band overlay based on `rubberBandRef`.
  //
  // Marching-ants: 1px alternating fg/bg pixels around the rect
  // perimeter, with a `phase` offset advanced by the Pixi ticker so
  // the ants "march". The pattern is the perimeter analogue of the
  // ghost-playhead column (`ghostPlayhead.ts`): contrast survives
  // any background because half the pixels disagree with it, and
  // the 1-px scale reads as "tool affordance" rather than "marker".
  const paintRubberBand = () => {
    const overlay = rubberBandOverlayRef.current;
    if (!overlay) return;
    overlay.clear();
    const band = rubberBandRef.current;
    if (!band) return;
    const host = hostRef.current;
    if (!host) return;
    const rect = host.getBoundingClientRect();
    // Clamp the visible band to the Stage host bounds. The unified
    // pixi canvas spans the viewport with this overlay unmasked, so
    // an unclamped rect can bleed into sibling panels (Timeline,
    // Sidebar) when the pointer drags off the Stage region. Commit
    // (`entitiesInBand`) clamps to the same bounds so what you see
    // is what you select. Shared helper with the Scrubber marquee
    // — both surfaces define their own bounds and call
    // `clampRectToBounds`.
    const raw = rectFromCorners(
      band.startX - rect.left,
      band.startY - rect.top,
      band.curX - rect.left,
      band.curY - rect.top,
    );
    const clamped = clampRectToBounds(raw, {
      minX: 0,
      minY: 0,
      maxX: rect.width,
      maxY: rect.height,
    });
    paintMarchingAntsBand(
      overlay,
      Math.round(clamped.x),
      Math.round(clamped.y),
      Math.round(clamped.width),
      Math.round(clamped.height),
    );
  };

  // Latched modifier state for the in-flight rubber-band drag.
  // Each modifier is set the moment it's pressed during the
  // gesture and remains set for the rest of the drag (a brief
  // release doesn't flip the commit mode mid-stride). Photoshop /
  // Illustrator commit mode at drag-end:
  //   shift              → add captured to selection
  //   shift + option     → remove captured from selection
  //   neither            → replace selection with captured
  //   option alone       → reserved (no marquee meaning yet)
  const rubberBandModRef = useRef<{ shift: boolean; alt: boolean }>({
    shift: false,
    alt: false,
  });

  // Compute the set of entities (peers, sessions, messages) whose
  // visual bounds OVERLAP the current marquee rect (Adobe /
  // Figma convention: any pixel of the entity's visual shape
  // intersecting the rect counts). Used both for the live preview
  // (drag-move) and the commit (drag-end).
  //
  // Per entity kind:
  //   - peer:    bounding circle of radius NODE_RADIUS (screen-px)
  //              vs. rect — closest-point-on-rect-to-circle test.
  //   - endpoint: the same test at the radius that end was actually
  //              painted at (`endpointBodyRadius`) — a claim is half a
  //              node wide, and measuring it as a peer would sweep in
  //              claims the marquee never visibly touched.
  //   - session: line segment between endpoint peers (screen-px)
  //              vs. rect — endpoint-in-rect OR segment crosses
  //              any of the four edges. Arced sessions are
  //              approximated as a straight segment; the user
  //              gets the same "did I touch this wire" answer.
  //   - message: small bounding circle (MESSAGE_RADIUS, screen-px)
  //              at the in-flight position vs. rect.
  //
  // Coordinate frame: band start/cur are DOM clientX/Y (== pixi
  // global, since canvas is `position: fixed; inset: 0`).
  // `viewport.toScreen` returns global too. Radii scale with
  // viewport zoom (NODE_RADIUS is in world units; multiply by
  // viewport.scale.x for screen-px).
  const entitiesInBand = (): Set<EntityRefKey> => {
    const band = rubberBandRef.current;
    const out = new Set<EntityRefKey>();
    if (!band) return out;
    const viewport = viewportRef.current;
    if (!viewport) return out;
    // Clamp the selection rect to the Stage host's client-space
    // bounds — same clamp the visible marquee paints with, so the
    // committed selection matches what the user saw. `band.startX/Y`
    // and `viewport.toScreen(...)` both live in client/global coords
    // (canvas is fixed/full-viewport); the host rect translates the
    // Stage region's edges into that same space.
    // Mirror paintRubberBand's hard guard — without a host rect we
    // can't clamp to the visible region, so selecting "the
    // unclamped raw band" would silently commit entities the user
    // never saw highlighted. Better to commit nothing.
    const host = hostRef.current;
    if (!host) return out;
    const hostRect = host.getBoundingClientRect();
    const clamped = clampRectToBounds(
      rectFromCorners(band.startX, band.startY, band.curX, band.curY),
      {
        minX: hostRect.left,
        minY: hostRect.top,
        maxX: hostRect.right,
        maxY: hostRect.bottom,
      },
    );
    const x0 = clamped.x;
    const x1 = clamped.x + clamped.width;
    const y0 = clamped.y;
    const y1 = clamped.y + clamped.height;
    const zoom = viewport.scale.x;
    const peerR = NODE_RADIUS * zoom;
    const msgR = MESSAGE_RADIUS * zoom;
    for (const peer of engine.queries.peers) {
      const pos = peer.position;
      if (!pos) continue;
      const s = viewport.toScreen(pos.x, pos.y);
      if (rectCircleOverlap(x0, y0, x1, y1, s.x, s.y, peerR)) {
        out.add(entityKey({ kind: "peer", id: peer.peer.id }));
      }
    }
    // The same resolution the renderer draws these ends with, so the shape
    // the marquee measures is the shape the user saw.
    const claimsToward = claimTargets(engine.world, engine.claims);
    for (const e of engine.queries.endpoints) {
      const s = viewport.toScreen(e.position.x, e.position.y);
      const r = endpointBodyRadius(e.endpoint.id, claimsToward) * zoom;
      if (rectCircleOverlap(x0, y0, x1, y1, s.x, s.y, r)) {
        out.add(entityKey({ kind: "endpoint", id: e.endpoint.id }));
      }
    }
    for (const sess of engine.queries.sessions) {
      // `findNode`: an end the marquee has to reach may be a loose claim
      // rather than a peer, and a peer-only lookup skipped the whole edge.
      const a = findNode(engine.world, sess.endpoints.a);
      const b = findNode(engine.world, sess.endpoints.b);
      if (!a?.position || !b?.position) continue;
      const sa = viewport.toScreen(a.position.x, a.position.y);
      const sb = viewport.toScreen(b.position.x, b.position.y);
      if (rectSegmentOverlap(x0, y0, x1, y1, sa.x, sa.y, sb.x, sb.y)) {
        out.add(entityKey({ kind: "session", id: sess.session.id }));
      }
    }
    for (const m of engine.queries.messagesInFlight) {
      const pos = m.position;
      if (!pos) continue;
      const s = viewport.toScreen(pos.x, pos.y);
      if (rectCircleOverlap(x0, y0, x1, y1, s.x, s.y, msgR)) {
        out.add(entityKey({ kind: "message", id: m.messageInFlight.id }));
      }
    }
    return out;
  };

  const commitRubberBand = () => {
    const out = entitiesInBand();
    const m = rubberBandModRef.current;
    const mode: "replace" | "add" | "remove" = m.shift && m.alt
      ? "remove"
      : m.shift
      ? "add"
      : "replace";
    onRubberBandCommitRef.current?.(out, mode);
  };

  // The FSM's effect handler. Routes by `effect.kind` (and the
  // resolved verb's tier for clicks / drags). The FSM is per-host
  // (one instance lives inside `useSurfacePointer`); we just react
  // to the effects it emits.
  //
  // Two verb-tier "modes" of drag-move:
  //   - space-pan / hand-tool: pan the viewport by the per-frame
  //     pointer delta (carry the previous position to compute it).
  //   - rubber-band: update the band's curX/curY and repaint.
  // Pan also kicks in via `pan-step` when the user space-converts
  // mid-rubber-band (Figma-style). All three paths converge on the
  // same `viewport.position.x/y -=` mutation.
  const lastDragPosRef = useRef<{ x: number; y: number } | null>(null);
  const isPanVerb = (verb: ResolvedGesture): boolean =>
    verb.tier === "space-pan" || verb.tier === "hand-tool";

  const handlePointerEffect = (effect: Effect) => {
    // Dev introspection — last few FSM effects for `__ocv.lastEffects`.
    // Cheap (ring buffer of stringified summaries); helpful when a
    // gesture goes somewhere unexpected.
    const g = globalThis as unknown as { __ocv?: { lastEffects?: string[] } };
    if (!g.__ocv) g.__ocv = {};
    const log = g.__ocv.lastEffects ?? [];
    const verbStr = "verb" in effect
      ? effect.verb.tier === "tool-refuses"
        ? effect.verb.tier
        : `${effect.verb.tier}/${effect.verb.verb.kind}`
      : "";
    const mods = "at" in effect
      ? ` shift=${effect.at.modifiers.shift ? "1" : "0"}`
      : "";
    log.push(`${effect.kind} ${verbStr}${mods}`.trim());
    while (log.length > 40) log.shift();
    g.__ocv.lastEffects = log;
    switch (effect.kind) {
      case "drag-start": {
        if (isPanVerb(effect.verb)) {
          lastDragPosRef.current = {
            x: effect.at.clientX,
            y: effect.at.clientY,
          };
        } else if (
          (effect.verb.tier === "default" ||
            effect.verb.tier === "modifier") &&
          effect.verb.verb.kind === "rubber-band"
        ) {
          rubberBandRef.current = {
            startX: effect.at.clientX,
            startY: effect.at.clientY,
            curX: effect.at.clientX,
            curY: effect.at.clientY,
          };
          // Seed the latch with whatever modifiers are held now;
          // subsequent moves can add more (one-way latch — see
          // drag-move). A brief release mid-drag won't flip the
          // commit mode.
          rubberBandModRef.current = {
            shift: effect.at.modifiers.shift,
            alt: effect.at.modifiers.alt,
          };
          previewSelectionRef.current = EMPTY_ENTITY_SET;
          paintRubberBand();
        }
        break;
      }
      case "drag-move": {
        if (isPanVerb(effect.verb)) {
          const last = lastDragPosRef.current;
          if (last) {
            const dx = effect.at.clientX - last.x;
            const dy = effect.at.clientY - last.y;
            const viewport = viewportRef.current;
            if (viewport) {
              viewport.position.x += dx;
              viewport.position.y += dy;
            }
          }
          lastDragPosRef.current = {
            x: effect.at.clientX,
            y: effect.at.clientY,
          };
        } else if (rubberBandRef.current) {
          rubberBandRef.current.curX = effect.at.clientX;
          rubberBandRef.current.curY = effect.at.clientY;
          // One-way latch: pressing a modifier mid-drag sets it
          // for the rest of the gesture, releasing it doesn't
          // clear. Keeps the commit mode predictable from the
          // user's intent at any point in the drag.
          if (effect.at.modifiers.shift) rubberBandModRef.current.shift = true;
          if (effect.at.modifiers.alt) rubberBandModRef.current.alt = true;
          // Live "would be selected" preview — recompute each
          // move. The set is small (only entities currently
          // enclosed) so allocation cost is bounded by the visible
          // scene complexity, which is what the user already pays
          // for in renderFrame.
          previewSelectionRef.current = entitiesInBand();
          paintRubberBand();
        }
        break;
      }
      case "drag-end": {
        if (isPanVerb(effect.verb)) {
          lastDragPosRef.current = null;
        } else if (rubberBandRef.current) {
          commitRubberBand();
          rubberBandRef.current = null;
          rubberBandModRef.current = { shift: false, alt: false };
          previewSelectionRef.current = EMPTY_ENTITY_SET;
          paintRubberBand();
        }
        break;
      }
      case "drag-cancel": {
        rubberBandRef.current = null;
        rubberBandModRef.current = { shift: false, alt: false };
        previewSelectionRef.current = EMPTY_ENTITY_SET;
        lastDragPosRef.current = null;
        paintRubberBand();
        break;
      }
      case "drag-pause": {
        // Marquee stays visible; pan-step translates its
        // coordinates so it appears anchored to the same world
        // position (the entities it covers stay covered as the
        // viewport pans). Seed lastDragPos so pan-step can
        // compute deltas.
        lastDragPosRef.current = {
          x: effect.at.clientX,
          y: effect.at.clientY,
        };
        break;
      }
      case "drag-resume": {
        // Marquee's start stays where it was translated to (it's
        // anchored to its world position); the cursor's current
        // screen position becomes the new endpoint so the user
        // picks up drawing from where the cursor actually is.
        // The carriedOrigin IS the cursor's post-pan screen
        // position (FSM § 5.3 — re-emit drag-resume with the
        // current snapshot as carried origin).
        if (rubberBandRef.current) {
          rubberBandRef.current.curX = effect.carriedOrigin.clientX;
          rubberBandRef.current.curY = effect.carriedOrigin.clientY;
          previewSelectionRef.current = entitiesInBand();
          paintRubberBand();
        }
        lastDragPosRef.current = null;
        break;
      }
      case "pan-step": {
        // Paused-pan emits pan-step directly (FSM does the delta
        // math against panOrigin). Apply to the viewport AND
        // translate the in-flight marquee by the same delta so
        // it stays anchored to its world position (doc § 11.2 —
        // "marquee origin transforms with pan"). The user sees
        // the marquee slide with the world it's selecting.
        const viewport = viewportRef.current;
        if (viewport) {
          viewport.position.x += effect.delta.dx;
          viewport.position.y += effect.delta.dy;
        }
        if (rubberBandRef.current) {
          rubberBandRef.current.startX += effect.delta.dx;
          rubberBandRef.current.startY += effect.delta.dy;
          rubberBandRef.current.curX += effect.delta.dx;
          rubberBandRef.current.curY += effect.delta.dy;
          // Recompute preview: marquee translated AND entities'
          // screen positions moved (viewport panned); both inputs
          // changed, so the enclosed set may have shifted.
          previewSelectionRef.current = entitiesInBand();
          paintRubberBand();
        }
        break;
      }
      case "click": {
        // Tool-create verbs (§ 4.6): Add Peer's empty-stage click
        // routes to `onCanvasClick` (the host consults its clock
        // for `t` — the verb's t=0 is a sentinel); a two-click
        // pick routes through `onSelect` like a sprite click, so
        // the host's arm/commit flow is one path for both origins.
        if (effect.verb.tier === "tool-create") {
          const v = effect.verb.verb;
          if (v.kind === "create-peer-at") {
            const place = onCanvasClickRef.current;
            if (place) {
              const world = clientToWorld(effect.at.clientX, effect.at.clientY);
              if (world) place(world.x, world.y);
            }
          } else {
            // The pick names a stage node, and the two kinds share one id
            // namespace, so the selection is spelled from the id itself.
            onSelectRef.current?.({
              kind: nodeKindOf(v.nodeId),
              id: v.nodeId,
            });
          }
          break;
        }
        // Click on empty stage: route to the existing onCanvasClick
        // (Add Peer mode) or to onSelect(null) (clear). Skip for
        // pan-tier verbs (clicks while space-held don't deselect).
        // The captured modifier mode flows through so an empty
        // click with shift / shift+option is a NO-OP — "add to
        // selection" and "remove from selection" both reduce to
        // "nothing to do" when there's no target. Only a plain
        // empty click clears.
        if (
          (effect.verb.tier === "default" ||
            effect.verb.tier === "modifier") &&
          effect.verb.verb.kind === "rubber-band"
        ) {
          const place = onCanvasClickRef.current;
          if (place) {
            const world = clientToWorld(effect.at.clientX, effect.at.clientY);
            if (world) place(world.x, world.y);
            return;
          }
          onSelectRef.current?.(null, {
            mode: selectModeFromModifiers({
              shiftKey: effect.at.modifiers.shift,
              altKey: effect.at.modifiers.alt,
            }),
          });
        }
        break;
      }
      case "double-click": {
        // Drill-in not yet wired in PR 3c — host doesn't act on
        // double-click for now. PR 4/5 wire the coordinated focus
        // effect (Inspector + Stage + Timeline).
        break;
      }
    }
  };

  // The pointer FSM for this surface. Its state is the cursor's other input:
  // what the surface is DOING outranks what it offers, and only the machine
  // knows what a press resolved to.
  const machineRef = useSurfacePointer(
    canvas,
    makeStageHit,
    { onEffect: handlePointerEffect },
    {
      spaceHeld: resolvedGestureCtxRef.current.spaceHeld,
      activeTool: resolvedGestureCtxRef.current.activeTool,
    },
    "stage",
  );

  // Ref (not state) — hover changes shouldn't re-reconcile React;
  // the Pixi ticker observes the change on its next paint.
  const hoverRef = useRef<StageHover>(null);

  // `null` until UnifiedCanvas finishes async init; effect re-runs
  // once the context populates. Alias of `unifiedCanvasCtx` above
  // (single source) — the legacy name is retained in this scope so
  // the heavy scene-init below stays readable as one block.
  const ctx = unifiedCanvasCtx;

  useEffect(() => {
    const host = hostRef.current;
    if (!host || !ctx) return;
    const { app, regions, setCursor } = ctx;

    const peerSprites = new Map<string, PeerSprite>();
    const endpointSprites = new Map<string, EndpointSprite>();
    const edgeSprites = new Map<string, EdgeSprite>();
    const messageSprites = new Map<string, MessageSprite>();
    // Per-tick scratch — owned here, reused each frame to avoid
    // per-frame Map/Set allocations in the hot path.
    const scratchActivity = new Map<string, PeerActivity>();
    const scratchPeerIds = new Set<string>();
    const scratchEndpointIds = new Set<string>();
    const scratchSessionIds = new Set<string>();
    const scratchMessageIds = new Set<string>();

    const cleanups: Array<() => void> = [];

    const stageScene = new Container();
    stageScene.eventMode = "static";
    stageScene.hitArea = new Rectangle(0, 0, 0, 0);
    // Cull handles fully-outside content (vertex work); the mask
    // clips partial-overlap content (edges across the boundary,
    // counter-scaled labels at low zoom) so it doesn't leak under
    // adjacent panels. Note: even for axis-aligned rects, Pixi v8.18
    // dispatches `container.mask` through `StencilMask` because no
    // `ScissorMaskPipe` is registered — scissor isn't an option.
    const stageMask = new Graphics();
    stageScene.addChild(stageMask);
    stageScene.mask = stageMask;
    app.stage.addChild(stageScene);

    {
      // Initial size from the host; the first region poll will sync
      // both position and size before the next paint.
      const initialW = host.clientWidth;
      const initialH = host.clientHeight;

      const viewport = new Viewport({
        screenWidth: initialW,
        screenHeight: initialH,
        worldWidth: WORLD_SIZE,
        worldHeight: WORLD_SIZE,
        events: app.renderer.events,
      });

      // Both `.drag()` (click-drag pan) and `.wheel()` are removed
      // — interaction-model § 4.5/8.2: click-drag on empty stage
      // = rubber-band selection (`useSurfacePointer` below); pan
      // requires Spacebar or the Hand tool; wheel = zoom (via
      // `useSurfaceWheel` above). `.pinch()` still handles touch
      // pinch-to-zoom; `.decelerate` is harmless without drag and
      // kept so a future re-introduction stays a one-line change.
      // `.clampZoom` constrains the zoom assigned by the wheel
      // handler, at both ends, and `render/stage-view.ts` argues each. It is the
      // same pair `clampStageZoom` holds, said to the plugin because the wheel
      // path assigns a scale through `setZoom` rather than through that function.
      viewport
        .pinch()
        .decelerate({ friction: 0.92 })
        .clampZoom({
          minScale: MIN_STAGE_SCALE,
          maxScale: MAX_STAGE_SCALE,
        });

      // Where this document asks to open. A document that stored nothing gets
      // the default, which is the middle of the world at 1:1.
      const opening = initialStageView(docInitialViewRef.current);
      viewport.setZoom(opening.zoom, true);
      viewport.moveCenter(opening.center.x, opening.center.y);
      stageScene.addChild(viewport);
      viewportRef.current = viewport;
      // The controls' end of `stage-camera.ts`. Every command lands on the
      // viewport here, because this is where the viewport is; the controls know
      // only the four things they can ask for.
      stageCamera.publishZoom(viewport.scale.x);
      cleanups.push(stageCamera.attach({
        view: () => ({
          zoom: viewport.scale.x,
          center: { x: viewport.center.x, y: viewport.center.y },
        }),
        run: (command) => {
          if (viewportRef.current !== viewport) return;
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
              // The document's own picture, asked of the scene graph rather than
              // recomputed from entity positions, so a thing that is drawn cannot
              // be left out of the fit.
              //
              // Three layers rather than the viewport whole, and each exclusion is
              // load-bearing. The GRID spans the world, so fitting it fits the
              // world and a three-node document lands at 16% in an empty field —
              // which is exactly what fitting the viewport did. The AFFORDANCE
              // layer is a wire preview chasing the cursor, which is not content.
              // And the LABELS hold constant screen size, so their world bounds
              // depend on the current zoom: fitting them would make the answer
              // depend on the question. `FIT_PADDING_PX` is what leaves them room.
              //
              // Which layers those are is checked by nothing: there is no test
              // that builds a viewport, so the exclusions are held by this list
              // and this comment. `unionBounds` and `fitStageView` carry the
              // arithmetic and are covered in `stage-view.test.ts`; a new content
              // layer has to be added here by hand, and fitting the world instead
              // of the picture is what it looks like when one is missing.
              const drawn = [edgeLayer, peerLayer, messageLayer]
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
        },
      }));
      // Test introspection: exposes the live viewport so probes
      // can convert peer world coords to screen coords without
      // re-implementing pixi-viewport's transform math.
      (globalThis as unknown as { __ocvViewport?: Viewport }).__ocvViewport =
        viewport;
      cleanups.push(() => {
        if (viewportRef.current === viewport) viewportRef.current = null;
      });

      // ── Affordance overlays ──────────────────────────────────
      //
      // Every non-interactive "what would happen / what's in
      // progress" graphic on the Stage lives under this header.
      // Two physical layers because the affordances split on
      // coordinate system:
      //
      //   `hostAffordanceLayer` (HOST coords, above viewport):
      //     rubber-band selection rect. Painted in screen pixels
      //     because the user drags screen pixels — converting
      //     to world coords would jitter the rect at zoom != 1.
      //
      //   `worldAffordanceLayer` (WORLD coords, inside viewport):
      //     armed-peer ring + wire preview. Painted in world
      //     coords because they anchor to peer positions which
      //     live in world space — re-anchoring per frame would
      //     duplicate viewport math the viewport already does.
      //
      // Both have `eventMode="none"` so they never intercept
      // pointer events; the FSM and per-sprite handlers own all
      // interaction. New affordance graphics (Adobe Pen tool
      // preview, alignment guides, …) belong here too.
      const hostAffordanceLayer = new Container();
      hostAffordanceLayer.eventMode = "none";
      const rubberBandOverlay = new Graphics();
      rubberBandOverlay.eventMode = "none";
      hostAffordanceLayer.addChild(rubberBandOverlay);
      stageScene.addChild(hostAffordanceLayer);
      rubberBandOverlayRef.current = rubberBandOverlay;
      cleanups.push(() => {
        if (rubberBandOverlayRef.current === rubberBandOverlay) {
          rubberBandOverlayRef.current = null;
        }
      });

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
          const led: { kind: "peer" | "endpoint"; id: string; pos: Vec2 }[] =
            [];
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
        cursorWorld.x = dragPt.x;
        cursorWorld.y = dragPt.y;
        cursorWorldHasValue = true;
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
        const upPeerId =
          isTwoClickTool(resolvedGestureCtxRef.current.activeTool)
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
        (ev: FederatedPointerEvent) =>
          finishDrag(ev.pointerId, true, ev.global.x, ev.global.y),
      );
      viewport.on(
        "pointerupoutside",
        (ev: FederatedPointerEvent) =>
          finishDrag(ev.pointerId, false, ev.global.x, ev.global.y),
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

      // Viewport stays interactive for the peer-drag handlers above
      // (`globalpointermove`, `pointerup*`). Click-on-empty-stage
      // (Add Peer placement / deselect) used to fire from
      // `viewport.on("clicked")`; with `.drag()` removed the FSM
      // now owns that path: the host-level `useSurfacePointer` emits
      // `click(rubber-band)` for no-drag pointerups on empty
      // stage, which `handlePointerEffect` routes to onCanvasClick
      // or onSelect(null).
      viewport.eventMode = "static";

      // Three LOD tiers, each a Container of tile Graphics built
      // by `populateGridLOD`. Per-LOD alpha cascades from the
      // container; tiles cull individually against the marker rect.
      const gridLayer = new Container();
      const gridCoarse = new Container();
      const gridMedium = new Container();
      const gridFine = new Container();
      gridLayer.addChild(gridCoarse, gridMedium, gridFine);

      const edgeLayer = new Container();
      const peerLayer = new Container();
      const messageLayer = new Container();
      // `labelLayer` is a parent container holding three per-
      // category sublayers. The split is so the label z-order
      // mirrors the entity z-order: peer labels at the bottom,
      // session labels in the middle, message labels on top.
      // Without the split, message labels could be drawn UNDER
      // peer labels even though message dots draw above peer
      // bodies — visually confusing. Each sublayer keeps its
      // own per-entity zIndex ordering inside its category.
      //
      // Labels are pure decoration — they overlap peer bodies
      // and session edges and would otherwise consume hit-tests
      // (rubber-band marquee would refuse to start over a label
      // rect). `eventMode: "none"` on the parent cascades to
      // every child label container + Text + Graphics.
      const labelLayer = new Container();
      labelLayer.eventMode = "none";
      const peerLabelLayer = new Container();
      const sessionLabelLayer = new Container();
      const messageLabelLayer = new Container();
      labelLayer.addChild(
        peerLabelLayer,
        sessionLabelLayer,
        messageLabelLayer,
      );
      // Per-entity z-ordering — Adobe / Flash convention: top of
      // the Timeline gutter row = on top of the Stage canvas.
      // `renderFrame` reads `doc.rowOrder` each frame and assigns
      // sprite.zIndex; Pixi's sortableChildren sort runs lazily
      // only when zIndex actually changes. Each label sublayer
      // sorts its own siblings; cross-category order comes from
      // the parent `labelLayer`'s addChild order above.
      edgeLayer.sortableChildren = true;
      peerLayer.sortableChildren = true;
      messageLayer.sortableChildren = true;
      peerLabelLayer.sortableChildren = true;
      sessionLabelLayer.sortableChildren = true;
      messageLabelLayer.sortableChildren = true;
      // Persistent refs so the small layer-eventMode effect below
      // can flip whole layers without depending on the heavy
      // scene-init. `peerLayerRef` enables the hand-tool override
      // (spaceHeld) to disable peer interaction outright — the
      // peer body's `pointerdown` stops propagation to claim its
      // own drag, so without this the viewport never sees the
      // event for pan when a gesture starts on a peer.
      messageLayerRef.current = messageLayer;
      edgeLayerRef.current = edgeLayer;
      peerLayerRef.current = peerLayer;
      cleanups.push(() => {
        if (messageLayerRef.current === messageLayer) {
          messageLayerRef.current = null;
        }
        if (edgeLayerRef.current === edgeLayer) edgeLayerRef.current = null;
        if (peerLayerRef.current === peerLayer) peerLayerRef.current = null;
      });
      // Sprite-hit detection lives in `makeStageHit` above, which
      // consults Pixi's own hit-test (`rootBoundary.hitTest`) — the
      // same logic Pixi uses internally to route pointer events.
      // No layer-level listeners needed: peer sprites stop
      // propagation to claim peer-drag, so a layer-level handler
      // would never see them anyway.
      // World-coord affordance layer (see "Affordance overlays"
      // block above): two-click tool feedback — the armed-peer
      // marching-ants ring + the wire preview from armed peer to
      // cursor. Sits above messages so the wire reads on top of
      // in-flight dots (it's the user's active focus); below
      // labels so peer names stay legible. Empty when no two-click
      // tool is active.
      const worldAffordanceLayer = new Container();
      worldAffordanceLayer.eventMode = "none";
      const armedRingGfx = new Graphics();
      armedRingGfx.eventMode = "none";
      const wirePreviewGfx = new Graphics();
      wirePreviewGfx.eventMode = "none";
      // The end the wire would land on if the click happened here: Open
      // Session run out to nobody. Drawn as the very shape the click makes,
      // through the same helper the real one is painted with, so the preview
      // cannot promise a body the stage would not draw. Positioned at the
      // cursor rather than drawn there, because the helper centers its shape
      // on its own origin.
      const ghostEndGfx = new Graphics();
      ghostEndGfx.eventMode = "none";
      worldAffordanceLayer.addChild(armedRingGfx, wirePreviewGfx, ghostEndGfx);
      // Back-to-front; messages last so in-flight dots stay on top.
      viewport.addChild(
        gridLayer,
        edgeLayer,
        peerLayer,
        messageLayer,
        worldAffordanceLayer,
        labelLayer,
      );

      // Tier sizing/alpha: coarse reads as "major intersection"
      // against the field of finer ones at default zoom.
      //   fine    spacing  50, r 1.0, α 0.22
      //   medium  spacing 250, r 2.5, α 0.32
      //   coarse  spacing 1000, r 5.0, α 0.42 (always visible)
      // One row per tier, so the paint and the level-of-detail decision read
      // the same `step` instead of repeating the numbers apart from each other.
      const GRID_TIERS = [
        { layer: gridFine, step: 50, radius: 1.0, alpha: 0.22 },
        { layer: gridMedium, step: 250, radius: 2.5, alpha: 0.32 },
        { layer: gridCoarse, step: 1000, radius: 5.0, alpha: 0.42 },
      ] as const;
      const drawGrid = (theme: Theme) => {
        const themed = themedColors(theme);
        for (const tier of GRID_TIERS) {
          populateGridLOD(
            tier.layer,
            tier.step,
            tier.radius,
            themed.text,
            tier.alpha,
          );
        }
      };
      drawGrid(themeRef.current);
      let lastDrawnTheme = themeRef.current;

      // Each tier appears when its own dots are far enough apart on screen to
      // read as a grid, which `gridTierOpacity` decides from the spacing rather
      // than from the zoom. Every tier answers to the same rule, coarse
      // included: it used to be pinned always-on, which was true while the
      // camera stopped at 0.2 and became a sub-pixel haze once it could reach
      // one percent.
      const updateGridLod = () => {
        const z = viewport.scale.x;
        for (const tier of GRID_TIERS) {
          const layer = tier.layer;
          const opacity = gridTierOpacity(tier.step * z);
          layer.alpha = opacity;
          layer.visible = opacity > 0;
        }
      };
      updateGridLod();

      // Region sync. Each frame the registry polls the marker rect;
      // when it changes we reposition the scene, resize the viewport,
      // and redraw the mask. Recenter on the world point that was
      // previously under the canvas center so panel drags don't
      // strand content. No `renderer.resize` — the unified canvas
      // owns the canvas, only this scene's sub-region changes.
      let lastSyncedW = 0;
      let lastSyncedH = 0;
      // View rect for the per-frame culler. Marker rect from the
      // region poll; default to full screen so frames before the
      // first poll don't cull everything.
      const cullView = new Rectangle(
        0,
        0,
        app.renderer.screen.width,
        app.renderer.screen.height,
      );
      const handleRegionRect = (
        rect: { x: number; y: number; width: number; height: number },
      ) => {
        stageScene.position.set(rect.x, rect.y);
        stageScene.hitArea = new Rectangle(0, 0, rect.width, rect.height);
        cullView.x = rect.x;
        cullView.y = rect.y;
        cullView.width = rect.width;
        cullView.height = rect.height;
        if (rect.width !== lastSyncedW || rect.height !== lastSyncedH) {
          stageMask
            .clear()
            .rect(0, 0, rect.width, rect.height)
            .fill(0xffffff);
          // Bail any in-flight drag cleanly — world coords survive
          // a resize but the gesture's bookkeeping is brittle.
          // Use the bound handler captured at drag-start, not the
          // current ref, so a region-rect change concurrent with
          // a prop swap still closes the right transaction.
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
          if (rect.width > 0 && rect.height > 0) {
            const prevCenter = viewport.center;
            viewport.resize(rect.width, rect.height);
            viewport.moveCenter(prevCenter.x, prevCenter.y);
          }
          lastSyncedW = rect.width;
          lastSyncedH = rect.height;
        }
      };
      cleanups.push(regions.register("stage", host));
      cleanups.push(regions.subscribe("stage", handleRegionRect));

      // Cursor in viewport-world coords. Drives the wire-preview
      // overlay; the wire's tail end follows the cursor each tick.
      // Null until first pointermove (no overlay drawn until then).
      const cursorWorld: { x: number; y: number } = { x: 0, y: 0 };
      let cursorWorldHasValue = false;
      const onViewportPointerMove = (
        e: { global: { x: number; y: number } },
      ) => {
        const local = viewport.toWorld(e.global.x, e.global.y);
        cursorWorld.x = local.x;
        cursorWorld.y = local.y;
        cursorWorldHasValue = true;
      };
      // Viewport's `eventMode` was set "static" up top for the
      // drag handlers; just attach the cursor-tracking listener.
      viewport.on("pointermove", onViewportPointerMove);
      cleanups.push(() => viewport.off("pointermove", onViewportPointerMove));

      // Hover set/clear closed over `hoverRef`. `leaveHover` only
      // clears if WE are the recorded hover — avoids the race where
      // the new sibling's `pointerover` fires before the old one's
      // `pointerout` and the clear wipes the new hover.
      const enterHover = (h: StageHover) => {
        hoverRef.current = h;
      };
      const leaveHover = (
        kind: NonNullable<StageHover>["kind"],
        id: string,
      ) => {
        const cur = hoverRef.current;
        if (cur && cur.kind === kind && cur.id === id) {
          hoverRef.current = null;
        }
      };

      let lastWall = performance.now();
      // Marching-ants offset, advanced each tick. Drives both the
      // armed ring's dash rotation and the wire line's dash phase
      // so the two motions look like one system.
      let marchOffsetPx = 0;
      // Tracks whether the overlay layer currently has anything
      // drawn. Lets the per-tick teardown branch skip cheap-but-
      // unnecessary `.clear()` calls when no overlay is active.
      let overlayDirty = false;

      /**
       * Whether a two-click tool will take the node it is about to pick.
       * `cursorFor` is pure over the gesture context and this is a fact about
       * the document, so the cursor asks for it; the answer comes from the
       * same `twoClickAccepts` the click path consults.
       */
      const willPick: ToolWillPick = ({ tool, armedNodeId, nodeId }) =>
        twoClickAccepts(engine, tool, armedNodeId, {
          kind: nodeKindOf(nodeId),
          id: nodeId,
        }) === "takes";

      /**
       * What the cursor asks about: the FSM's state, with the sprite hovers
       * the FSM never sees folded in.
       *
       * `makeStageHit` returns null over a sprite so the FSM stays out of the
       * gesture the sprite's own listeners take, which leaves `machine.hover`
       * empty in exactly the places the pointer is over something. The Pixi
       * hover is that same fact arriving by the other door, so the cursor
       * reads both and prefers the nearer one.
       */
      const cursorMachine = (): PointerMachineState => {
        const machine = machineRef.current;
        const spriteHit = stageHoverToHit(hoverRef.current);
        if (spriteHit === null) return machine;
        return {
          ...machine,
          hover: { surface: spriteHit.surface, hit: spriteHit },
        };
      };

      // Stable args object — mutated each tick rather than
      // allocated, since `renderFrame` runs at 60 Hz. The
      // `selection` / `hover` / `colors` / `scale` / `counterScale`
      // fields are the only ones that change frame to frame.
      // Stable wrapper around the always-fresh `onSelectRef`.
      // Sprite listeners capture this once at sprite creation but
      // it dispatches through the ref, so React state updates in
      // App.handleSelect (e.g. firstPickNodeId churn during the
      // two-click tool flow) reach the listeners without needing
      // to rebuild the Pixi scene.
      const onSelectStable = (
        sel: StageSelection,
        opts?: { mode?: SelectMode },
      ) => onSelectRef.current?.(sel, opts);
      const renderArgs: RenderFrameArgs = {
        engine,
        edgeLayer,
        peerLayer,
        messageLayer,
        peerLabelLayer,
        sessionLabelLayer,
        messageLabelLayer,
        peerSprites,
        endpointSprites,
        edgeSprites,
        messageSprites,
        onSelect: onSelectStable,
        selection: selectionRef.current,
        anchor: anchorRef.current,
        previewSelection: previewSelectionRef.current,
        hover: hoverRef.current,
        enterHover,
        leaveHover,
        colors: themedColors(themeRef.current),
        counterScale: 1,
        scale: 1,
        startNodeDrag,
        claimsToward: EMPTY_CLAIMS,
        scratchActivity,
        scratchPeerIds,
        scratchEndpointIds,
        scratchSessionIds,
        scratchMessageIds,
      };
      // Named so we can remove it on cleanup. The ticker outlives
      // this effect (it's the unified canvas's long-lived
      // Application); a leaked callback writes into destroyed
      // layers and can wedge the renderer.
      const tickCb = () => {
        const now = performance.now();
        const wallDt = now - lastWall;
        lastWall = now;
        engine.tick(wallDt);
        if (themeRef.current !== lastDrawnTheme) {
          drawGrid(themeRef.current);
          lastDrawnTheme = themeRef.current;
        }
        const v = visibilityRef.current;
        peerLayer.visible = v.peers;
        edgeLayer.visible = v.connections;
        messageLayer.visible = v.messages;
        labelLayer.visible = v.labels;
        updateGridLod();
        renderArgs.selection = selectionRef.current;
        renderArgs.anchor = anchorRef.current;
        renderArgs.previewSelection = previewSelectionRef.current;
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
        const hovered = hoverRef.current;
        renderArgs.hover = null;
        if (hovered) {
          const hoverHit = stageHoverToHit(hovered);
          if (hoverHit) {
            const verb = resolveGesture({
              hit: hoverHit,
              modifiers: NO_MODIFIERS,
              spaceHeld: resolvedGestureCtxRef.current.spaceHeld,
              activeTool: resolvedGestureCtxRef.current.activeTool,
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
            const armedNow = armedNodeRef.current ?? null;
            const wouldTake = armedNow === null ||
              armedNow.tool !== resolvedGestureCtxRef.current.activeTool ||
              (hovered.kind !== "peer" && hovered.kind !== "endpoint") ||
              twoClickAccepts(engine, armedNow.tool, armedNow.nodeId, {
                  kind: hovered.kind,
                  id: hovered.id,
                }) === "takes";
            if (
              wouldTake && (verbSelectsEntity(verb) || verbArmsForTool(verb))
            ) {
              renderArgs.hover = hovered;
            }
          }
        }
        renderArgs.colors = themedColors(themeRef.current);
        // The frame's claim resolution, once: the projection draws these ends
        // with it, and the armed ring below sizes itself to the body the
        // projection drew.
        const claimsToward = claimTargets(engine.world, engine.claims);
        renderArgs.claimsToward = claimsToward;
        // THE cursor, once per frame (§ 10). Derived from the same resolver
        // the click goes through and the same FSM that runs it, so what the
        // pointer promises is what the click does. `setCursor` is the canvas
        // element's one writer and touches the DOM only on a change.
        setCursor(cursorFor(
          {
            ...resolvedGestureCtxRef.current,
            toolState: armedNodeRef.current ?? null,
          },
          cursorMachine(),
          willPick,
        ));
        // Inverse of viewport zoom — applied to label containers
        // so text stays at constant screen size while positions
        // remain in world space. The zoom itself goes too, because a
        // selection mark divides by it for the same reason and must
        // not re-derive the camera from its own reciprocal.
        renderArgs.scale = viewport.scale.x;
        renderArgs.counterScale = 1 / viewport.scale.x;
        // Same value the frame is about to draw with, so the readout cannot
        // disagree with the picture. The store compares before it notifies, so
        // this is a cheap call to make every frame.
        stageCamera.publishZoom(viewport.scale.x);
        // Where the camera is IS where the document opens, so a look around is
        // what sets it. Written as the camera settles rather than per frame: a
        // wheel gesture crosses dozens of scales on the way to one, and each
        // write notifies the app, so writing them all would re-render the tree at
        // the frame rate to record positions nobody stopped at.
        noteViewWhenSettled(
          engine,
          viewport.scale.x,
          viewport.center.x,
          viewport.center.y,
        );
        renderFrame(renderArgs);
        // Marching-ants animation: while a rubber-band drag is in
        // flight, repaint the overlay each tick so the phase
        // increments and ants visibly march. paintRubberBand
        // early-returns when no band is active (cheap no-op).
        if (rubberBandRef.current) paintRubberBand();
        // Advance marching offset proportional to wall time so the
        // dashes move at a constant screen-pixel speed regardless
        // of frame rate or playback speed.
        marchOffsetPx = (marchOffsetPx + wallDt * 0.04) % 1000;
        const armed = armedNodeRef.current ?? null;
        // A node, not a peer: the message tool arms an end nothing has
        // attributed just as it arms a peer, and an armed node with no ring
        // is the tool holding a pick it never says it holds.
        const armedEntity = armed ? findNode(engine.world, armed.nodeId) : null;
        if (armed && armedEntity?.position) {
          const themed = themedColors(themeRef.current);
          const color = armed.tool === "send-message"
            ? themed.messageInFlight
            : themed.accent;
          // Armed ring is tool STATE ("I picked Alice; waiting for
          // the second pick"). Persists across temporary
          // overrides — the user may be panning briefly to see
          // their second-pick target. Always drawn when armed.
          // Sized to the body it rings, the way the focus ring is: a claim
          // is half a peer's width, so a ring drawn at a peer's radius would
          // float clear of the thing it is meant to be holding.
          drawArmedRing(
            armedRingGfx,
            armedEntity.position.x,
            armedEntity.position.y,
            "endpoint" in armedEntity
              ? endpointBodyRadius(armedEntity.endpoint.id, claimsToward)
              : NODE_RADIUS,
            marchOffsetPx,
            color,
            viewport.scale.x,
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
          const ctxNow = resolvedGestureCtxRef.current;
          const previewVerb = resolveGesture({
            hit: { surface: "stage-empty" },
            modifiers: NO_MODIFIERS,
            spaceHeld: ctxNow.spaceHeld,
            activeTool: ctxNow.activeTool,
          });
          if (cursorWorldHasValue && !verbIsPan(previewVerb)) {
            drawMarchingLine(
              wirePreviewGfx,
              armedEntity.position.x,
              armedEntity.position.y,
              cursorWorld.x,
              cursorWorld.y,
              marchOffsetPx,
              color,
              viewport.scale.x,
            );
            // Over empty canvas, Open Session runs out to an end nothing has
            // attributed, so the wire ends in the body that click would make.
            // Over a node the click lands on that node instead, and there is
            // nothing to mint — the wire simply reaches it.
            if (armed.tool === "open-session" && hoverRef.current === null) {
              ghostEndGfx.clear();
              ghostEndGfx.position.set(cursorWorld.x, cursorWorld.y);
              drawLooseEndBody(
                ghostEndGfx,
                LOOSE_END_ALONE,
                PROFILE_FALLBACK_COLOR,
                color,
              );
            } else {
              ghostEndGfx.clear();
            }
          } else {
            wirePreviewGfx.clear();
            ghostEndGfx.clear();
          }
          overlayDirty = true;
        } else if (overlayDirty) {
          armedRingGfx.clear();
          wirePreviewGfx.clear();
          ghostEndGfx.clear();
          overlayDirty = false;
        }
        // PixiJS doesn't auto-install `CullerPlugin` (it'd cull
        // against `renderer.screen` — the whole canvas, including
        // under-panel area). Calling the shared culler ourselves
        // lets us pass the marker rect as the view. Default ticker
        // priority runs this before render (LOW).
        Culler.shared.cull(stageScene, cullView);
      };
      // Wrap so a per-frame throw in `tickCb` surfaces once via the
      // error bus rather than escaping into Pixi's rAF loop, where
      // it'd silently kill subsequent frames.
      const safeTickCb = safeTick(tickCb);
      app.ticker.add(safeTickCb);
      cleanups.push(() => app.ticker?.remove(safeTickCb));
    }

    return () => {
      for (const fn of cleanups) fn();
      // The scene that answered for the cursor is going away, so hand the
      // element back the plain arrow rather than leaving the last frame's
      // answer stamped on a canvas nothing is deriving one for.
      setCursor("default");
      app.stage?.removeChild(stageScene);
      if (!stageScene.destroyed) stageScene.destroy({ children: true });
    };
    // `onSelect` is intentionally NOT in this dep array — it's
    // read via `onSelectRef` so the entire Pixi scene doesn't
    // rebuild every time App.handleSelect's identity changes.
  }, [ctx, engine]);

  // pixi-viewport's drag plugin pauses cleanly; pinch / wheel /
  // decelerate stay live so trackpad zoom and momentum still work
  // when only mouse-drag pan is suppressed.
  // Layer-level event gating. Single source of truth: § 7 of the
  // interaction-model doc, encoded in `layerInteractivity(ctx)`.
  // Setting `eventMode` on the parent container cascades to every
  // current AND future child sprite, so one flip here governs
  // every peer / session / message in the lane at once.
  useEffect(() => {
    const peerLayer = peerLayerRef.current;
    const messageLayer = messageLayerRef.current;
    const edgeLayer = edgeLayerRef.current;
    const modes = layerInteractivity(gestureCtx);
    if (peerLayer) peerLayer.eventMode = modes.peers;
    if (messageLayer) messageLayer.eventMode = modes.messages;
    if (edgeLayer) edgeLayer.eventMode = modes.edges;
  }, [gestureCtx, ctx]);

  return (
    <div
      ref={hostRef}
      style={{
        width: "100%",
        height: "100%",
        position: "relative",
        // Marker is layout-only; PixiJS receives events on the
        // canvas behind it. `auto` would intercept and starve PixiJS.
        pointerEvents: "none",
      }}
    />
  );
}
