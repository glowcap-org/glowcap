/**
 * `renderFrame` — per-tick world → scene-graph projection. Extracted
 * from `Stage.tsx` so the file holds scene wiring (viewport setup,
 * gesture FSM, drag handlers, layer creation, cull) and this module
 * holds the projection itself. Pure function: takes everything via
 * `RenderFrameArgs`, mutates the passed-in Pixi containers + sprite
 * Maps, returns void. No module-scope captures from `Stage.tsx`.
 *
 * Sprite shapes (`PeerSprite` / `EdgeSprite` / `MessageSprite`) live
 * here because they're an implementation detail of the projection
 * — `Stage` allocates the Maps but never reaches into a sprite's
 * internals. `PeerActivity` is the one type external panels (Sidebar,
 * EntityChips) also need, and it lives in `./types.ts` where they read it.
 */

import { Container, type FederatedPointerEvent, Graphics, Rectangle, Text } from "pixi.js";
import { captpVersionLabel } from "../schema/topology.ts";
import { entityKey, type EntityRefKey } from "../interactions/types.ts";
import type { Engine } from "../engine/engine.ts";
import type { EndpointEntity, MessageEntity, PeerEntity, SessionEntity } from "../engine/world.ts";
import { type SessionCurve } from "../engine/session-geometry.ts";
import {
  drawLooseEndBody,
  drawNodeActivity,
  drawNodeHalo,
  layoutPillBackground,
  looseEndStyle,
  NODE_RADIUS,
  positionEdgeLabel,
  strokeCurve,
} from "./draw-helpers.ts";
import { curveBoundsArea, curveHitArea } from "./curve-hit-area.ts";
import type { EdgeStrokeBatch } from "./edge-stroke-batch.ts";
import {
  CAPTP_VERSION_COLORS,
  type CodecLineStyle,
  colorForProfile,
  lineStyleForCodec,
  PROFILE_FALLBACK_COLOR,
  SESSION_STATE_WIDTH,
  type ThemedColors,
} from "./palette.ts";
import { FONT } from "../ui/tokens.ts";
import {
  EDGE_CHIP_LABEL,
  endpointLabelText,
  MESSAGE_LABEL,
  MESSAGE_LABEL_GAP_PX,
  NODE_LABEL,
  NODE_LABEL_GAP_PX,
  peerLabelText,
} from "./stage-labels.ts";
import {
  foldActivityByNode,
  type HaloTier,
  type SelectMode,
  selectModeFromModifiers,
  type StageHover,
  type StageSelection,
} from "./types.ts";

/** Half a message dot's width. The node half-width it sits beside is
 *  `NODE_RADIUS` in `draw-helpers.ts`, imported by name: a peer is always that
 *  wide, while a session end is whatever `endpointBodyRadius` says, and one
 *  number wearing two names is how those two facts get confused. */
export const MESSAGE_RADIUS = 7;
/** How far outside the dot the selection ring sits, and how far inside that the
 *  anchor's second ring sits. Screen pixels: see the selection-mark note in
 *  `draw-helpers.ts`. */
const MESSAGE_HALO_GAP_PX = 4;
const MESSAGE_HALO_INNER_GAP_PX = 3;
const MESSAGE_HALO_WIDTH_PX = 2.0;
const MESSAGE_HALO_INNER_WIDTH_PX = 1.0;
const MESSAGE_HOVER_GAP_PX = 2;
const MESSAGE_HOVER_WIDTH_PX = 1.2;

/** How much wider than the wire itself each tier of edge halo strokes. Screen
 *  pixels, so a selected edge stays findable when the wire is a hairline. */
const EDGE_HALO_SPREAD_PX = 6;
const EDGE_HALO_INNER_SPREAD_PX = 2;
const EDGE_HOVER_SPREAD_PX = 3;

/** Hand a pointerdown on a node body to the Stage's drag closure. Declared
 *  once because two sprite kinds raise it and `RenderFrameArgs` carries it. */
export type StartNodeDrag = (
  kind: "peer" | "endpoint",
  nodeId: string,
  pointerId: number,
  screenX: number,
  screenY: number,
  nodeWorldX: number,
  nodeWorldY: number,
  modeAtDown: SelectMode,
) => void;

/** Re-exported from `./types.ts`, where it lives so `draw-helpers.ts` can
 *  paint the ring without importing this module. */
export type { HaloTier } from "./types.ts";

export type PeerSprite = {
  body: Container;
  bodyGfx: Graphics;
  haloGfx: Graphics;
  label: Container;
  labelBg: Graphics;
  labelText: Text;
  lastHalo: HaloTier;
  lastHovered: boolean;
  lastActivity: PeerActivity;
  lastColor: number;
  lastColors: ThemedColors | null;
  lastLabelText: string;
  /** The camera scale the selection mark was last painted at. A mark holds one
   *  screen size, so its world geometry is a function of the zoom, and a sprite
   *  whose other inputs are unchanged still owes a repaint when the camera
   *  moves. Without it the compensation is inert: a stage's world geometry does
   *  not change when you zoom, so nothing else here would ever trip. */
  lastScale: number;
};

/** A session end nobody has attributed. Same parts as a peer's sprite minus
 *  the profile color: nothing here names an implementation. It keeps the
 *  activity badge, because who this end is and whether bytes are moving
 *  through it are two separate questions, and only the first one is open. */
export type EndpointSprite = {
  body: Container;
  bodyGfx: Graphics;
  haloGfx: Graphics;
  label: Container;
  labelBg: Graphics;
  labelText: Text;
  lastHalo: HaloTier;
  lastHovered: boolean;
  lastActivity: PeerActivity;
  /** Whether the end was last drawn as a claim on a peer the stage draws,
   *  which decides the body's weight and so has to be repainted when it
   *  changes. */
  lastClaiming: boolean;
  lastColors: ThemedColors | null;
  lastLabelText: string;
  /** The camera scale the selection mark was last painted at. A mark holds one
   *  screen size, so its world geometry is a function of the zoom, and a sprite
   *  whose other inputs are unchanged still owes a repaint when the camera
   *  moves. Without it the compensation is inert: a stage's world geometry does
   *  not change when you zoom, so nothing else here would ever trip. */
  lastScale: number;
};

export type EdgeSprite = {
  hitArea: Container;
  haloGfx: Graphics;
  /** Wire pixels live on `edgeStrokeBatch`, not a per-edge Graphics. */
  label: Container;
  labelBg: Graphics;
  labelText: Text;
  lastAx: number;
  lastAy: number;
  lastBx: number;
  lastBy: number;
  lastCx: number;
  lastCy: number;
  lastHalo: HaloTier;
  lastHovered: boolean;
  lastColor: number;
  lastWidth: number;
  lastLineStyle: CodecLineStyle;
  lastColors: ThemedColors | null;
  lastLabelText: string;
  /** The camera scale the selection mark was last painted at. A mark holds one
   *  screen size, so its world geometry is a function of the zoom, and a sprite
   *  whose other inputs are unchanged still owes a repaint when the camera
   *  moves. Without it the compensation is inert: a stage's world geometry does
   *  not change when you zoom, so nothing else here would ever trip. */
  lastScale: number;
};

export type MessageSprite = {
  container: Container;
  body: Graphics;
  haloGfx: Graphics;
  label: Container;
  labelBg: Graphics;
  labelText: Text;
  lastHalo: HaloTier;
  lastHovered: boolean;
  lastColors: ThemedColors | null;
  lastLabelText: string;
  /** The camera scale the selection mark was last painted at. A mark holds one
   *  screen size, so its world geometry is a function of the zoom, and a sprite
   *  whose other inputs are unchanged still owes a repaint when the camera
   *  moves. Without it the compensation is inert: a stage's world geometry does
   *  not change when you zoom, so nothing else here would ever trip. */
  lastScale: number;
  /** True after `"body"` vis mode cleared the dot Graphics. Forces one body
   *  redraw on unhide without making `lastColors` lie to the label path. */
  lastBodyCleared: boolean;
};

import type { PeerActivity } from "./types.ts";

/** Resolve an entity's halo tier from the selection set + anchor
 *  in one shot. Anchor wins over selected (it implies selected
 *  by invariant), so the call site doesn't repeat the subset
 *  check. */
function haloTierFor(
  selection: ReadonlySet<EntityRefKey>,
  anchor: EntityRefKey | null,
  key: EntityRefKey,
): HaloTier {
  if (anchor === key) return "anchor";
  if (selection.has(key)) return "selected";
  return "none";
}

export type RenderFrameArgs = {
  engine: Engine;
  edgeLayer: Container;
  peerLayer: Container;
  messageLayer: Container;
  /** Per-category label sublayers. Add a label to the matching
   *  one so the parent-side z-stack (peer < session < message)
   *  pins label layer-ordering to entity-layer ordering. */
  peerLabelLayer: Container;
  sessionLabelLayer: Container;
  messageLabelLayer: Container;
  peerSprites: Map<string, PeerSprite>;
  /** Keyed by endpoint stage id (`sessionId::side`), which cannot collide
   *  with a peer id, so the two node maps stay disjoint by construction. */
  endpointSprites: Map<string, EndpointSprite>;
  edgeSprites: Map<string, EdgeSprite>;
  /** One Graphics for every session wire — see `edge-stroke-batch.ts`. */
  edgeStrokeBatch: EdgeStrokeBatch;
  messageSprites: Map<string, MessageSprite>;
  onSelect:
    | ((
      selection: StageSelection,
      opts?: { mode?: SelectMode },
    ) => void)
    | undefined;
  /** THE selection — sole source of truth for the selected halo
   * gate. Peers, sessions, and messages by entity key. */
  selection: ReadonlySet<EntityRefKey>;
  /** Anchor — the Inspector-follow entity (and range-extension
   * pivot). Always inside `selection` when set. Used to paint
   * an additional inner ring on the anchor's halo so the user
   * can see WHICH selected entity the Inspector is tracking
   * when more than one is selected. Single-select case looks
   * the same as before — anchor + selection collapse. */
  anchor: EntityRefKey | null;
  /** Entities currently inside the in-flight marquee rect.
   * Painted as a "would be selected" affordance — visually
   * identical to hover. Empty when no drag is in flight. */
  previewSelection: ReadonlySet<EntityRefKey>;
  hover: StageHover;
  enterHover: (h: StageHover) => void;
  /** Race-safe: only clears if WE're the recorded hover. */
  leaveHover: (kind: NonNullable<StageHover>["kind"], id: string) => void;
  colors: ThemedColors;
  /** `1 / viewport.scale.x` — applied to label containers so text
   * stays at constant screen size while positions remain in world
   * space. */
  counterScale: number;
  /** The camera scale itself, which the selection marks divide by so they hold
   * one screen size at any zoom. Carried alongside its reciprocal rather than
   * derived from it, because the two are wanted in different forms: a Pixi
   * container takes the reciprocal as its own `scale`, and the draw helpers
   * divide (`drawNodeHalo`, `drawArmedRing`). Deriving one from the other at a
   * call site is where a second spelling of the camera would start. */
  scale: number;
  /** Sprite pointerdown signals the Stage's drag closure to claim
   * the gesture. Args: which kind of node and its id, pointer id, cursor
   * screen coords, the node's current world position.
   *
   * Both node kinds take a position an author can pin, so both drag; the
   * kind rides along because the id alone cannot say which table holds
   * that position. */
  startNodeDrag: StartNodeDrag;
  /** Which ends this frame draws as claims, and the peer each names —
   * `engine.frameGeometry.claimsToward`. Passed in rather than derived
   * here because the Stage's own overlays ask the same question of the
   * same frame, and two answers would size a ring differently from the
   * body it rings. */
  claimsToward: ReadonlyMap<string, string>;
  /** Per-session curves from the same `frameGeometry` flight used —
   * rebuild here and a wire and its dots disagree. */
  sessionCurves: ReadonlyMap<string, SessionCurve>;
  /** Per-frame scratch buffers — owned by the Stage closure and
   * cleared at the top of each `renderFrame` so the hot path
   * doesn't allocate fresh `Map`/`Set` instances each tick. */
  scratchActivity: Map<string, PeerActivity>;
  scratchPeerIds: Set<string>;
  scratchEndpointIds: Set<string>;
  scratchSessionIds: Set<string>;
  scratchMessageIds: Set<string>;
};

/** Per-frame world → scene-graph projection. Sprites are created on
 * first sight, destroyed when their entity disappears; the scene
 * graph is materialized ECS, never authoritative. */
export function renderFrame(args: RenderFrameArgs): void {
  const {
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
    edgeStrokeBatch,
    messageSprites,
    onSelect,
    hover,
    enterHover,
    leaveHover,
    colors,
    counterScale,
    scale,
    startNodeDrag,
  } = args;

  // Selected = a member of `selection`. The Inspector-follow
  // `anchor` slot lives in the same store reducer and is kept
  // consistent with this set, so the visual answer is always
  // "what's in `selection`".
  const { selection, previewSelection, anchor } = args;
  const hoveredPeerId = hover?.kind === "peer" ? hover.id : null;
  const hoveredEndpointId = hover?.kind === "endpoint" ? hover.id : null;
  const hoveredSessionId = hover?.kind === "session" ? hover.id : null;
  const hoveredMessageId = hover?.kind === "message" ? hover.id : null;

  // Activity from in-flight messages, keyed by stage node id rather than by
  // peer: a message on a session whose far end nobody has attributed names
  // that end's stage id as its from or to. Both node kinds below read out of
  // this one map, and the Inspector's chip folds by the same rule.
  const activityByNode = foldActivityByNode(
    engine.queries.messagesInFlight,
    args.scratchActivity,
  );

  // Per-entity stage-visibility cascades `all → category → entity`
  // — `engine.effectiveRowVisMode(category, id)` owns the resolver.
  // This file used to reimplement the cascade locally (build Sets
  // from `engine.doc.rowHidden?.*`, compute per-category overrides,
  // run a `resolveMode` closure). The local copy was structurally
  // identical to the engine version, so any cascade-bug fix in the
  // engine wouldn't reach the Stage. Delegating keeps a single
  // source of truth. Mode `"body"` keeps the label and drops the
  // mark; sync* clears stroked Graphics so hidden bodies do not
  // retain tessellated GPU buffers.

  // Per-entity z-order falls out of iteration order: the engine's
  // `orderedPeers / orderedSessions / orderedMessages` return
  // entities in canonical draw order (Adobe / Flash convention:
  // top of Timeline gutter = on top of Stage). zIndex is just
  // `last - index`, so the first entity in the ordered list
  // paints last (highest z) and ends up on top. Pixi's
  // `sortableChildren` flag (set on the layers above) makes the
  // sort fire lazily — only when a zIndex actually changes.

  const livePeers = args.scratchPeerIds;
  livePeers.clear();
  const peers = engine.orderedPeers();
  const lastPeerIdx = peers.length - 1;
  for (let i = 0; i < peers.length; i++) {
    const e = peers[i]!;
    const peerMode = engine.effectiveRowVisMode("peers", e.peer.id);
    // `both` mode kills the sprite entirely; the other modes
    // keep the sprite around with per-axis `.visible` toggles
    // applied after `syncPeerSprite`.
    if (peerMode === "both") continue;
    livePeers.add(e.peer.id);
    const peerKey = entityKey({ kind: "peer", id: e.peer.id });
    syncPeerSprite(
      e,
      peerSprites,
      peerLayer,
      peerLabelLayer,
      colors,
      haloTierFor(selection, anchor, peerKey),
      hoveredPeerId === e.peer.id || previewSelection.has(peerKey),
      activityByNode.get(e.peer.id) ?? "idle",
      counterScale,
      scale,
      enterHover,
      leaveHover,
      startNodeDrag,
      peerMode !== "body",
    );
    const sprite = peerSprites.get(e.peer.id);
    if (sprite) {
      const z = lastPeerIdx - i;
      sprite.body.zIndex = z;
      sprite.label.zIndex = z;
      // Per-axis visibility from the cascaded mode resolved
      // above: `body` keeps the label but drops the node body;
      // `label` keeps the body but hides the floating name.
      sprite.body.visible = peerMode !== "body";
      sprite.label.visible = peerMode !== "label";
    }
  }
  for (const [id, sprite] of peerSprites) {
    if (!livePeers.has(id)) {
      sprite.body.destroy({ children: true });
      sprite.label.destroy({ children: true });
      peerSprites.delete(id);
    }
  }

  // Unattributed ends, drawn where a peer would be and into the same
  // layer: they occupy a peer's place, so they answer to the peer layer's
  // visibility and pointer gating. Their timeline row is their SESSION's,
  // because an end has no row of its own to hide.
  const liveEndpoints = args.scratchEndpointIds;
  liveEndpoints.clear();
  // Which ends are claims about somebody on stage, asked the way the layout
  // asked it: the document's own resolution, narrowed to what this moment
  // draws. The drawing has to agree with the placement — an end the layout sat
  // on an edge two thirds of the way to Alice is drawn as the lesser of the
  // two shapes, and one standing on its own is drawn at full weight — and it
  // is one map, because the same answer sizes the body, keys the bundle, and
  // cuts the wire below.
  const claimsToward = args.claimsToward;
  for (const e of engine.queries.endpoints) {
    const endpointMode = engine.effectiveRowVisMode(
      "sessions",
      e.endpoint.sessionId,
    );
    if (endpointMode === "both") continue;
    liveEndpoints.add(e.endpoint.id);
    const endpointKey = entityKey({ kind: "endpoint", id: e.endpoint.id });
    syncEndpointSprite(
      e,
      claimsToward.has(e.endpoint.id),
      endpointSprites,
      peerLayer,
      peerLabelLayer,
      colors,
      haloTierFor(selection, anchor, endpointKey),
      hoveredEndpointId === e.endpoint.id ||
        previewSelection.has(endpointKey),
      activityByNode.get(e.endpoint.id) ?? "idle",
      counterScale,
      scale,
      enterHover,
      leaveHover,
      startNodeDrag,
      endpointMode !== "body",
    );
    const sprite = endpointSprites.get(e.endpoint.id);
    if (sprite) {
      sprite.body.visible = endpointMode !== "body";
      sprite.label.visible = endpointMode !== "label";
    }
  }
  for (const [id, sprite] of endpointSprites) {
    if (!liveEndpoints.has(id)) {
      sprite.body.destroy({ children: true });
      sprite.label.destroy({ children: true });
      endpointSprites.delete(id);
    }
  }

  const liveSessions = args.scratchSessionIds;
  liveSessions.clear();
  // Curves from the frame geometry flight already used — edge
  // rendering and `MessageFlightSystem` share one table so a dot and
  // its wire track.
  const curves = args.sessionCurves;
  const sessions = engine.orderedSessions();
  const lastSessionIdx = sessions.length - 1;
  const strokeOrder: string[] = [];
  for (let i = 0; i < sessions.length; i++) {
    const e = sessions[i]!;
    const sessionMode = engine.effectiveRowVisMode("sessions", e.session.id);
    if (sessionMode === "both") continue;
    const curve = curves.get(e.session.id);
    // A session with no curve has nowhere to be drawn: an end of it names a
    // peer this moment does not hold, which an end that changed hands reaches
    // whenever the occupant it left is gone before the session is. So it is
    // marked live only from here, on the same test that mints its sprite. The
    // sweep below reads this set as "drawn this frame", so a session counted
    // live without a sprite would keep the LAST frame's line: a wire still
    // reaching a node nothing draws any more.
    if (!curve) continue;
    liveSessions.add(e.session.id);
    const sessionKey = entityKey({ kind: "session", id: e.session.id });
    const drawBody = sessionMode !== "body";
    syncEdgeSprite(
      e,
      curve,
      edgeSprites,
      edgeStrokeBatch,
      edgeLayer,
      sessionLabelLayer,
      onSelect,
      colors,
      haloTierFor(selection, anchor, sessionKey),
      hoveredSessionId === e.session.id || previewSelection.has(sessionKey),
      counterScale,
      scale,
      enterHover,
      leaveHover,
      drawBody,
    );
    if (drawBody) strokeOrder.push(e.session.id);
    const sprite = edgeSprites.get(e.session.id);
    if (sprite) {
      const z = lastSessionIdx - i;
      sprite.hitArea.zIndex = z;
      sprite.label.zIndex = z;
      sprite.hitArea.visible = sessionMode !== "body";
      sprite.label.visible = sessionMode !== "label";
    }
  }
  for (const [id, sprite] of edgeSprites) {
    if (!liveSessions.has(id)) {
      edgeStrokeBatch.remove(id);
      sprite.hitArea.destroy({ children: true });
      sprite.label.destroy({ children: true });
      edgeSprites.delete(id);
    }
  }
  // Later strokes paint on top — reverse so high session z (drawn
  // first in `orderedSessions`) wins at crossings, matching hitArea
  // zIndex (`lastSessionIdx - i`).
  strokeOrder.reverse();
  edgeStrokeBatch.setOrder(strokeOrder);
  edgeStrokeBatch.flush();

  const liveMessages = args.scratchMessageIds;
  liveMessages.clear();
  const messages = engine.orderedMessages();
  const lastMessageIdx = messages.length - 1;
  for (let i = 0; i < messages.length; i++) {
    const e = messages[i]!;
    const messageMode = engine.effectiveRowVisMode(
      "messages",
      e.messageInFlight.id,
    );
    if (messageMode === "both") continue;
    liveMessages.add(e.messageInFlight.id);
    const messageKey = entityKey({ kind: "message", id: e.messageInFlight.id });
    syncMessageSprite(
      e,
      messageSprites,
      messageLayer,
      messageLabelLayer,
      onSelect,
      colors,
      haloTierFor(selection, anchor, messageKey),
      hoveredMessageId === e.messageInFlight.id ||
        previewSelection.has(messageKey),
      counterScale,
      scale,
      enterHover,
      leaveHover,
      messageMode !== "body",
    );
    const sprite = messageSprites.get(e.messageInFlight.id);
    if (sprite) {
      const z = lastMessageIdx - i;
      sprite.container.zIndex = z;
      sprite.label.zIndex = z;
      // Per-axis visibility from the cascaded `messageMode` —
      // same semantic as peers / sessions: `body` drops the
      // dot but keeps the label; `label` keeps the dot but
      // hides the floating name.
      sprite.container.visible = messageMode !== "body";
      sprite.label.visible = messageMode !== "label";
    }
  }
  for (const [id, sprite] of messageSprites) {
    if (!liveMessages.has(id)) {
      sprite.container.destroy({ children: true });
      sprite.label.destroy({ children: true });
      messageSprites.delete(id);
    }
  }
}

/**
 * Whether a mark is worth repainting.
 *
 * A mark exists only while its entity is selected or under the pointer, and the
 * repaint gate reads the camera — so on a stage with nothing picked, every one of
 * these sprites cleared an empty `Graphics` on every frame of every zoom, to draw
 * nothing into it. Clearing is not free: it dirties the geometry and the renderer
 * rebuilds it. Asking whether there is a mark, or was one a frame ago, is what
 * makes an unmarked stage cost nothing to zoom.
 *
 * Both halves are needed. Without the second, the frame that clears a mark away
 * would be skipped and the mark would stay on screen.
 */
function marked(
  tier: HaloTier,
  hovered: boolean,
  wasTier: HaloTier,
  wasHovered: boolean,
): boolean {
  return tier !== "none" || hovered || wasTier !== "none" || wasHovered;
}

function syncPeerSprite(
  e: PeerEntity,
  sprites: Map<string, PeerSprite>,
  peerLayer: Container,
  labelLayer: Container,
  colors: ThemedColors,
  tier: HaloTier,
  hovered: boolean,
  activity: PeerActivity,
  counterScale: number,
  scale: number,
  enterHover: (h: StageHover) => void,
  leaveHover: (kind: NonNullable<StageHover>["kind"], id: string) => void,
  startNodeDrag: StartNodeDrag,
  /** When false the node body is hidden (`body` vis mode): keep the
   *  label moving, skip body/halo rebuild, clear Graphics, and
   *  invalidate dirty keys so unhiding forces a redraw. */
  drawBody: boolean,
): void {
  // The caption this peer wears, shortened when it is too long to draw.
  // `peerLabelText` owns that decision because the layout reserves room for
  // the result of it.
  const labelTextValue = peerLabelText(e.peer.label);
  let sprite = sprites.get(e.peer.id);
  if (!sprite) {
    const body = new Container();
    body.eventMode = "static";
    body.cullable = true;
    // Halo as a non-interactive sibling drawn BEHIND the body
    // (added first → child index 0 → painted first in Pixi).
    // `eventMode = "none"` removes it from hit-test entirely;
    // Pixi's per-primitive hit-test on `bodyGfx` then makes the
    // peer body's actual drawn shape the clickable footprint,
    // automatically — no duplicated bounds constant to keep in
    // sync with the body's geometry.
    const haloGfx = new Graphics();
    haloGfx.eventMode = "none";
    body.addChild(haloGfx);
    const bodyGfx = new Graphics();
    body.addChild(bodyGfx);

    const label = new Container();
    label.cullable = true;
    const labelBg = new Graphics();
    const labelText = new Text({
      // The node caption, at the size `NODE_LABEL` reserves room for.
      // Per the typography rule's middle-tier rule, discretion
      // applies; `peer.label` is human-readable display text
      // ("Alice (gifter)"), not a wire identifier (`peer.id`), so
      // sans wins on content-type grounds. Note that the same
      // string also renders in the scrubber peers row, which is a
      // tiny pill (mono by size-tier default) — same content, two
      // size tiers, two families is consistent with the rule.
      text: labelTextValue,
      style: {
        fontFamily: FONT.sans,
        fontSize: NODE_LABEL.fontPx,
        fill: colors.text,
        align: "center",
      },
    });
    labelText.anchor.set(0.5);
    label.addChild(labelBg, labelText);

    // Capture only the peer id — entity objects don't survive
    // resetWorld() (undo/redo/scenario switch), but ids do.
    // Reading `body.position` instead of `e.position` for the same
    // reason: `body` is synced to the live entity each frame, `e`
    // can go stale. `stopPropagation` keeps the viewport's drag
    // plugin from competing for the gesture.
    const peerId = e.peer.id;
    body.on("pointerdown", (ev: FederatedPointerEvent) => {
      ev.stopPropagation();
      startNodeDrag(
        "peer",
        peerId,
        ev.pointerId,
        ev.global.x,
        ev.global.y,
        body.position.x,
        body.position.y,
        selectModeFromModifiers(ev),
      );
    });
    body.on("pointerover", () => enterHover({ kind: "peer", id: peerId }));
    body.on("pointerout", () => leaveHover("peer", peerId));

    peerLayer.addChild(body);
    labelLayer.addChild(label);
    sprite = {
      body,
      bodyGfx,
      haloGfx,
      label,
      labelBg,
      labelText,
      lastHalo: "none",
      lastHovered: false,
      lastActivity: "idle",
      lastColor: -1,
      lastColors: null,
      lastLabelText: "",
      lastScale: Number.NaN,
    };
    sprites.set(e.peer.id, sprite);
  }

  // Position assignment is short-circuited by Pixi's ObservablePoint
  // when unchanged — safe to call every frame.
  sprite.body.position.set(e.position.x, e.position.y);

  const color = colorForProfile(e.peer.profile);
  const colorsDirty = sprite.lastColors !== colors;
  const labelDirty = colorsDirty || sprite.lastLabelText !== labelTextValue;

  if (!drawBody) {
    sprite.bodyGfx.clear();
    sprite.haloGfx.clear();
    // Invalidate so the next visible frame cannot keep a stale
    // early-out from before the hide.
    sprite.lastColor = -1;
    sprite.lastActivity = "idle";
    sprite.lastHalo = "none";
    sprite.lastHovered = false;
    sprite.lastScale = Number.NaN;
  } else {
    // The mark and the body answer to different questions, and the camera is why
    // that now matters: a zoom changes the mark's world geometry and nothing about
    // the body, so one flag for both would re-stroke every body on every frame of
    // a zoom gesture. Tier and hover never reached the body anyway.
    const haloDirty = marked(tier, hovered, sprite.lastHalo, sprite.lastHovered) &&
      (colorsDirty ||
        sprite.lastHalo !== tier ||
        sprite.lastHovered !== hovered ||
        sprite.lastScale !== scale);
    const bodyDirty = colorsDirty ||
      sprite.lastActivity !== activity ||
      sprite.lastColor !== color;

    // Skip the body Graphics rebuild when nothing about it changed —
    // the dominant per-frame cost for static peers.
    if (haloDirty) {
      sprite.lastHalo = tier;
      sprite.lastHovered = hovered;
      sprite.lastScale = scale;
      // Painted into the non-interactive `haloGfx` sibling so the ring
      // doesn't extend the body's clickable region. `drawNodeHalo` owns the
      // geometry; a peer's ring lands ≈43 out, just past its diagonal corners
      // and brushing the activity badge.
      drawNodeHalo(
        sprite.haloGfx,
        NODE_RADIUS,
        tier,
        hovered,
        colors.accent,
        scale,
      );
    }

    if (bodyDirty) {
      sprite.lastActivity = activity;
      sprite.lastColor = color;
      sprite.bodyGfx.clear();
      sprite.bodyGfx
        .roundRect(
          -NODE_RADIUS,
          -NODE_RADIUS,
          NODE_RADIUS * 2,
          NODE_RADIUS * 2,
          5,
        )
        .fill({ color })
        .stroke({ color: colors.peerStroke, width: 2 });
      drawNodeActivity(sprite.bodyGfx, NODE_RADIUS, activity, colors);
    }
  }

  // Label text + pill rebuild only when text or theme changes.
  // `style.fill` write is gated by `colorsDirty` specifically so a
  // text-only change doesn't poke the TextStyle setter with the
  // same primitive value (Pixi v8 short-circuits but we don't
  // rely on it).
  if (labelDirty) {
    sprite.lastLabelText = labelTextValue;
    sprite.lastColors = colors;
    if (sprite.labelText.text !== labelTextValue) {
      sprite.labelText.text = labelTextValue;
    }
    if (colorsDirty) sprite.labelText.style.fill = colors.text;
    layoutPillBackground(sprite.labelBg, sprite.labelText, colors, NODE_LABEL);
  }
  // Counter-scale + position assignments are short-circuited by
  // Pixi's `ObservablePoint.set` when unchanged.
  sprite.label.scale.set(counterScale);
  sprite.label.position.set(
    e.position.x,
    e.position.y + NODE_RADIUS + NODE_LABEL_GAP_PX * counterScale,
  );
}

/** Half the width of the body this end is actually painted at, in world
 *  units. A claim is drawn at half a node's width, so a hit test that assumed
 *  every end was peer-sized would catch claims the user never touched.
 *
 *  `claimsToward` is the frame's `claimTargets` — the one resolution, so the
 *  body a hit test measures is the body the frame drew. */
export function endpointBodyRadius(
  endpointId: string,
  claimsToward: ReadonlyMap<string, string>,
): number {
  return looseEndStyle(claimsToward.has(endpointId)).radius;
}

/** Above every peer's row order, which is what a claim's zIndex has to
 *  clear. A stage with more peers than this has other problems. */
const CLAIM_Z = 1_000_000;

/** Paint one unattributed session end.
 *
 * The reading is "a place a peer will attach": the same rounded square a peer
 * occupies, drawn as a dashed outline over a faint fill. The fill is there
 * because something IS on the other end of the wire; it is transparent
 * because nothing proved what. The dash repeats that at a glance, so the
 * difference survives a zoom that makes the fill hard to judge.
 *
 * The slate fill is the same one a peer of an unrecognized profile takes: no
 * implementation is known here either, and inventing a color would be the
 * picture claiming more than the model holds.
 *
 * `claiming` says this end's claim names a peer the stage draws — the same
 * question the layout asked when it sat the end partway along its session's
 * edge toward that peer (`CLAIM_LEAN`). It decides two things here: which of
 * the two weights the body takes, and that the end draws above every peer.
 * Both exist so the pair reads as a claim about somebody rather than as a
 * second somebody. */
function syncEndpointSprite(
  e: EndpointEntity,
  claiming: boolean,
  sprites: Map<string, EndpointSprite>,
  peerLayer: Container,
  labelLayer: Container,
  colors: ThemedColors,
  tier: HaloTier,
  hovered: boolean,
  activity: PeerActivity,
  counterScale: number,
  scale: number,
  enterHover: (h: StageHover) => void,
  leaveHover: (kind: NonNullable<StageHover>["kind"], id: string) => void,
  startNodeDrag: StartNodeDrag,
  /** When false the end body is hidden (`body` vis mode): keep the
   *  label moving, skip body/halo rebuild, clear Graphics, and
   *  invalidate dirty keys so unhiding forces a redraw. */
  drawBody: boolean,
): void {
  // What the end claims to be, or a plain word for having no claim at all,
  // shortened the way every long identifier is. `endpointLabelText` owns that
  // decision because the layout reserves room for the result of it.
  const labelTextValue = endpointLabelText(e.endpoint.designator);
  let sprite = sprites.get(e.endpoint.id);
  if (!sprite) {
    const body = new Container();
    body.eventMode = "static";
    body.cullable = true;
    const haloGfx = new Graphics();
    haloGfx.eventMode = "none";
    body.addChild(haloGfx);
    const bodyGfx = new Graphics();
    body.addChild(bodyGfx);

    const label = new Container();
    label.cullable = true;
    const labelBg = new Graphics();
    const labelText = new Text({
      // Mono at the peer label's size: a designator is a wire identifier
      // (`tcp://127.0.0.1:9001`), not a display name, so it reads as the
      // identifier it is rather than as somebody's name.
      text: labelTextValue,
      style: {
        fontFamily: FONT.mono,
        fontSize: NODE_LABEL.fontPx,
        fill: colors.textSubtle,
        align: "center",
      },
    });
    labelText.anchor.set(0.5);
    label.addChild(labelBg, labelText);

    const endpointId = e.endpoint.id;
    body.on("pointerdown", (ev: FederatedPointerEvent) => {
      ev.stopPropagation();
      startNodeDrag(
        "endpoint",
        endpointId,
        ev.pointerId,
        ev.global.x,
        ev.global.y,
        body.position.x,
        body.position.y,
        selectModeFromModifiers(ev),
      );
    });
    body.on(
      "pointerover",
      () => enterHover({ kind: "endpoint", id: endpointId }),
    );
    body.on("pointerout", () => leaveHover("endpoint", endpointId));

    peerLayer.addChild(body);
    labelLayer.addChild(label);
    sprite = {
      body,
      bodyGfx,
      haloGfx,
      label,
      labelBg,
      labelText,
      lastHalo: "none",
      lastHovered: false,
      lastActivity: "idle",
      lastClaiming: claiming,
      lastColors: null,
      lastLabelText: "",
      lastScale: Number.NaN,
    };
    sprites.set(e.endpoint.id, sprite);
  }

  sprite.body.position.set(e.position.x, e.position.y);
  // A claim draws above every peer. It stops short of the peer it names, so
  // being on top hides nothing of that peer; what it protects against is the
  // other peers, any of which its edge may pass close to, and a body half a
  // node wide is one a full-sized neighbor can swallow whole. On top it also
  // stays the thing the pointer finds, which is the same answer the eye
  // gives. Peers take zIndex 0 and up from their row order, so `CLAIM_Z` is
  // simply past the end of that range. An end that is nobody's claim takes 0,
  // the bottom of that range: it is a full-size body with no row order of its
  // own to derive a z from, and the solver keeps it a node's width clear of
  // everything, so it has no overlap to win anyway.
  const z = claiming ? CLAIM_Z : 0;
  sprite.body.zIndex = z;
  sprite.label.zIndex = z;

  const style = looseEndStyle(claiming);
  const colorsDirty = sprite.lastColors !== colors;
  const labelDirty = colorsDirty || sprite.lastLabelText !== labelTextValue;

  if (!drawBody) {
    sprite.bodyGfx.clear();
    sprite.haloGfx.clear();
    sprite.lastClaiming = !claiming;
    sprite.lastActivity = "idle";
    sprite.lastHalo = "none";
    sprite.lastHovered = false;
    sprite.lastScale = Number.NaN;
  } else {
    // Split for the reason a peer's is: the camera reaches the ring and not the
    // body. `claiming` reaches both, because it sets this body's half-width and
    // the ring is sized off that.
    const haloDirty = marked(tier, hovered, sprite.lastHalo, sprite.lastHovered) &&
      (colorsDirty || sprite.lastHalo !== tier ||
        sprite.lastHovered !== hovered || sprite.lastClaiming !== claiming ||
        sprite.lastScale !== scale);
    const bodyDirty = colorsDirty || sprite.lastClaiming !== claiming ||
      sprite.lastActivity !== activity;

    if (haloDirty) {
      sprite.lastHalo = tier;
      sprite.lastHovered = hovered;
      sprite.lastScale = scale;
      // The same ring a peer gets, from the same place, so selecting an end and
      // selecting a peer look like one act. It takes this body's own radius, so
      // on a claim it hugs the half-sized square rather than a peer's.
      drawNodeHalo(
        sprite.haloGfx,
        style.radius,
        tier,
        hovered,
        colors.accent,
        scale,
      );
    }

    if (bodyDirty) {
      sprite.lastClaiming = claiming;
      sprite.lastActivity = activity;
      sprite.bodyGfx.clear();
      drawLooseEndBody(
        sprite.bodyGfx,
        style,
        PROFILE_FALLBACK_COLOR,
        colors.textSubtle,
      );
      // Off this body's own half-width, so a claim's mark rides its smaller
      // corner instead of floating out where a peer's would be.
      drawNodeActivity(sprite.bodyGfx, style.radius, activity, colors);
    }
  }

  if (labelDirty) {
    sprite.lastLabelText = labelTextValue;
    sprite.lastColors = colors;
    if (sprite.labelText.text !== labelTextValue) {
      sprite.labelText.text = labelTextValue;
    }
    if (colorsDirty) sprite.labelText.style.fill = colors.textSubtle;
    layoutPillBackground(sprite.labelBg, sprite.labelText, colors, NODE_LABEL);
  }
  sprite.label.scale.set(counterScale);
  // Off the body's own half-width, not a node's: a claim is half the size, so
  // measuring from a peer's edge would float its name a node's width clear of
  // the shape it names.
  sprite.label.position.set(
    e.position.x,
    e.position.y + style.radius + NODE_LABEL_GAP_PX * counterScale,
  );
}

function syncEdgeSprite(
  e: SessionEntity,
  curve: SessionCurve,
  sprites: Map<string, EdgeSprite>,
  strokeBatch: EdgeStrokeBatch,
  edgeLayer: Container,
  labelLayer: Container,
  onSelect:
    | ((selection: StageSelection, opts?: { mode?: SelectMode }) => void)
    | undefined,
  colors: ThemedColors,
  tier: HaloTier,
  hovered: boolean,
  counterScale: number,
  scale: number,
  enterHover: (h: StageHover) => void,
  leaveHover: (kind: NonNullable<StageHover>["kind"], id: string) => void,
  /** When false the wire is hidden (`body` vis mode): keep the label
   *  moving, drop the batch entry, and invalidate the dirty keys so
   *  unhiding forces a redraw. */
  drawBody: boolean,
): void {
  const labelText = `${e.session.codec} · ${captpVersionLabel(e.session.captpVersion)}`;

  let sprite = sprites.get(e.session.id);
  if (!sprite) {
    const hitArea = new Container();
    hitArea.eventMode = "static";
    hitArea.cullable = true;
    // Halo (hover / focus glow) is a separate non-interactive
    // Graphics so its wider stroke doesn't make the edge clickable
    // outside the actual line. The wire itself is painted into the
    // shared stroke batch, not as a child here.
    const haloGfx = new Graphics();
    haloGfx.eventMode = "none";
    hitArea.addChild(haloGfx);

    const label = new Container();
    label.cullable = true;
    const labelBg = new Graphics();
    const labelTextNode = new Text({
      // Tiny edge-label caption, at the size `EDGE_CHIP_LABEL` staggers
      // lanes for. Per the typography rule's
      // size-first default, tiny → mono. The composite shape
      // ("capnp · pancake-next") reads cleanly in mono at
      // this size and matches the surrounding 9px mono vocabulary
      // (tick labels, scrubber pill labels, kv values).
      text: labelText,
      style: {
        fontFamily: FONT.mono,
        fontSize: EDGE_CHIP_LABEL.fontPx,
        fill: colors.textSubtle,
      },
    });
    labelTextNode.anchor.set(0.5);
    label.addChild(labelBg, labelTextNode);

    if (onSelect) {
      hitArea.on("pointertap", (ev: FederatedPointerEvent) => {
        ev.stopPropagation();
        onSelect(
          { kind: "session", id: e.session.id },
          { mode: selectModeFromModifiers(ev) },
        );
      });
    }
    hitArea.on(
      "pointerover",
      () => enterHover({ kind: "session", id: e.session.id }),
    );
    hitArea.on("pointerout", () => leaveHover("session", e.session.id));

    edgeLayer.addChild(hitArea);
    labelLayer.addChild(label);
    sprite = {
      hitArea,
      haloGfx,
      label,
      labelBg,
      labelText: labelTextNode,
      lastAx: NaN,
      lastAy: NaN,
      lastBx: NaN,
      lastBy: NaN,
      // Cx / cy enter the dirty-key now too: the curve moves when
      // the bundle membership changes (new sibling session added)
      // even if endpoint positions are unchanged.
      lastCx: NaN,
      lastCy: NaN,
      lastHalo: "none",
      lastHovered: false,
      lastColor: -1,
      lastWidth: -1,
      lastLineStyle: "solid",
      lastColors: null,
      lastLabelText: "",
      lastScale: Number.NaN,
    };
    sprites.set(e.session.id, sprite);
  }

  const color = CAPTP_VERSION_COLORS[e.session.captpVersion];
  const width = SESSION_STATE_WIDTH[e.session.state];
  const lineStyle = lineStyleForCodec(e.session.codec);

  const colorsDirty = sprite.lastColors !== colors;
  const labelDirty = colorsDirty || sprite.lastLabelText !== labelText;

  if (!drawBody) {
    // Hidden wire: drop the batch entry (one shared clear at flush)
    // and invalidate the curve keys so the next visible frame cannot
    // early-out on a stale stroke.
    strokeBatch.remove(e.session.id);
    sprite.haloGfx.clear();
    sprite.hitArea.hitArea = null;
    // Zero box: the proxy is `visible = false` for body-hidden, so the
    // culler never keeps it alive from this AABB.
    sprite.hitArea.boundsArea = new Rectangle(0, 0, 0, 0);
    sprite.lastAx = NaN;
    sprite.lastAy = NaN;
    sprite.lastBx = NaN;
    sprite.lastBy = NaN;
    sprite.lastCx = NaN;
    sprite.lastCy = NaN;
  } else {
    const curveMoved = sprite.lastAx !== curve.ax ||
      sprite.lastAy !== curve.ay ||
      sprite.lastBx !== curve.bx ||
      sprite.lastBy !== curve.by ||
      sprite.lastCx !== curve.cx ||
      sprite.lastCy !== curve.cy;
    // The wire is world geometry and the mark around it is not, so a zoom
    // repaints the mark and leaves the wire alone — which matters here more
    // than on a node, because a dashed wire is walked over
    // `CURVE_STROKE_SAMPLES` every time it is stroked. The mark reads
    // `width` too: its spread is measured out from the wire's edge.
    const haloDirty = marked(tier, hovered, sprite.lastHalo, sprite.lastHovered) &&
      (colorsDirty || curveMoved ||
        sprite.lastHalo !== tier ||
        sprite.lastHovered !== hovered ||
        sprite.lastWidth !== width ||
        sprite.lastScale !== scale);
    // Theme colors feed the chip and halo, not the CapTP wire ink.
    const lineDirty = curveMoved ||
      sprite.lastColor !== color ||
      sprite.lastWidth !== width ||
      sprite.lastLineStyle !== lineStyle;

    if (haloDirty || lineDirty) {
      // Committed before either pass draws, because the two flags are already
      // decided and both read the same curve.
      sprite.lastAx = curve.ax;
      sprite.lastAy = curve.ay;
      sprite.lastBx = curve.bx;
      sprite.lastBy = curve.by;
      sprite.lastCx = curve.cx;
      sprite.lastCy = curve.cy;
      sprite.lastHalo = tier;
      sprite.lastHovered = hovered;
      sprite.lastColor = color;
      sprite.lastWidth = width;
      sprite.lastLineStyle = lineStyle;
      sprite.lastScale = scale;
    }

    if (haloDirty) {
      sprite.haloGfx.clear();
      // Halo above the shared wire batch — wider, semi-transparent
      // accent that follows the same Bezier so the glow reads as the
      // same edge. Painted into the non-interactive `haloGfx` so the
      // wider stroke doesn't enlarge the edge's clickable region.
      // Anchor adds a thin solid second pass on top of the halo (see
      // `HaloTier`) so the edge the Inspector follows reads brighter
      // under multi-select.
      if (tier !== "none") {
        strokeCurve(sprite.haloGfx, curve, {
          color: colors.accent,
          width: width + EDGE_HALO_SPREAD_PX / scale,
          alpha: 0.28,
        });
        if (tier === "anchor") {
          strokeCurve(sprite.haloGfx, curve, {
            color: colors.accent,
            width: width + EDGE_HALO_INNER_SPREAD_PX / scale,
            alpha: 0.55,
          });
        }
      } else if (hovered) {
        strokeCurve(sprite.haloGfx, curve, {
          color: colors.accent,
          width: width + EDGE_HOVER_SPREAD_PX / scale,
          alpha: 0.18,
        });
      }
    }

    if (lineDirty) {
      strokeBatch.upsert(e.session.id, { curve, color, width, lineStyle });
      // Picking footprint + cull AABB without a per-edge Graphics.
      const half = width / 2;
      sprite.hitArea.hitArea = curveHitArea(curve, half);
      sprite.hitArea.boundsArea = curveBoundsArea(curve, half);
    }
  }

  if (labelDirty) {
    sprite.lastLabelText = labelText;
    sprite.lastColors = colors;
    if (sprite.labelText.text !== labelText) {
      sprite.labelText.text = labelText;
    }
    if (colorsDirty) sprite.labelText.style.fill = colors.textSubtle;
    layoutPillBackground(
      sprite.labelBg,
      sprite.labelText,
      colors,
      EDGE_CHIP_LABEL,
    );
  }
  sprite.label.scale.set(counterScale);
  positionEdgeLabel(sprite.label, curve);
}

function syncMessageSprite(
  e: MessageEntity,
  sprites: Map<string, MessageSprite>,
  messageLayer: Container,
  labelLayer: Container,
  onSelect:
    | ((selection: StageSelection, opts?: { mode?: SelectMode }) => void)
    | undefined,
  colors: ThemedColors,
  tier: HaloTier,
  hovered: boolean,
  counterScale: number,
  scale: number,
  enterHover: (h: StageHover) => void,
  leaveHover: (kind: NonNullable<StageHover>["kind"], id: string) => void,
  /** When false the dot is hidden (`body` vis mode): keep the label
   *  moving, skip body/halo rebuild, clear Graphics, and invalidate
   *  dirty keys so unhiding forces a redraw. */
  drawBody: boolean,
): void {
  // Label text source: `messageInFlight.label` (human-friendly
  // payload preview) when present, falling back to the message id
  // so something always renders. Computed once so the sprite
  // creation and the dirty-check below can share.
  const labelTextValue = e.messageInFlight.label ?? e.messageInFlight.id;
  let sprite = sprites.get(e.messageInFlight.id);
  if (!sprite) {
    const container = new Container();
    container.eventMode = "static";
    container.cullable = true;
    // Halo as a non-interactive sibling (added first → behind).
    // Per-primitive hit-test on the body Graphics then makes the
    // dot itself the clickable footprint without an explicit
    // hitArea — body shape is the hit shape automatically.
    const haloGfx = new Graphics();
    haloGfx.eventMode = "none";
    container.addChild(haloGfx);
    const body = new Graphics();
    container.addChild(body);
    if (onSelect) {
      container.on("pointertap", (ev: FederatedPointerEvent) => {
        ev.stopPropagation();
        onSelect(
          { kind: "message", id: e.messageInFlight.id },
          { mode: selectModeFromModifiers(ev) },
        );
      });
    }
    container.on(
      "pointerover",
      () => enterHover({ kind: "message", id: e.messageInFlight.id }),
    );
    container.on(
      "pointerout",
      () => leaveHover("message", e.messageInFlight.id),
    );
    messageLayer.addChild(container);

    // Label as a sibling on `labelLayer` — same pattern as peers
    // / sessions so counter-scale + z-index logic stays uniform
    // and labels always paint above body graphics.
    const label = new Container();
    label.cullable = true;
    const labelBg = new Graphics();
    const labelText = new Text({
      text: labelTextValue,
      style: {
        // Smaller than a node's caption because messages cluster
        // and tile across the stage; a smaller label keeps the
        // name from dominating its host dot. Sans for
        // content-type consistency with the peer label (both are
        // display text, not wire identifiers).
        fontFamily: FONT.sans,
        fontSize: MESSAGE_LABEL.fontPx,
        fill: colors.text,
        align: "center",
      },
    });
    labelText.anchor.set(0.5);
    label.addChild(labelBg, labelText);
    labelLayer.addChild(label);

    sprite = {
      container,
      body,
      haloGfx,
      label,
      labelBg,
      labelText,
      lastHalo: "none",
      lastHovered: false,
      lastColors: null,
      lastLabelText: "",
      lastScale: Number.NaN,
      lastBodyCleared: false,
    };
    sprites.set(e.messageInFlight.id, sprite);
  }

  const colorsDirty = sprite.lastColors !== colors;
  const labelDirty = colorsDirty || sprite.lastLabelText !== labelTextValue;

  if (!drawBody) {
    sprite.body.clear();
    sprite.haloGfx.clear();
    sprite.lastHalo = "none";
    sprite.lastHovered = false;
    sprite.lastScale = Number.NaN;
    sprite.lastBodyCleared = true;
  } else {
    // Split for the reason a peer's is: the camera reaches the ring and not the
    // dot. `MESSAGE_RADIUS` is world units and nothing the dot draws reads the
    // scale, so one flag for both re-stroked every message in flight on every
    // frame of a zoom — and messages are the things that are moving.
    const haloDirty = marked(tier, hovered, sprite.lastHalo, sprite.lastHovered) &&
      (sprite.lastHalo !== tier ||
        sprite.lastHovered !== hovered ||
        sprite.lastScale !== scale ||
        colorsDirty);
    if (haloDirty) {
      sprite.lastHalo = tier;
      sprite.lastHovered = hovered;
      sprite.lastScale = scale;
      // Halo lives in the non-interactive sibling — hit-test only
      // sees the dot. Body draws on top of the halo (drawn after,
      // higher child index). Anchor adds an inner ring inside the
      // halo (see `HaloTier`) so the message the Inspector
      // follows reads distinct from sibling-selected messages
      // under multi-select.
      sprite.haloGfx.clear();
      if (tier !== "none") {
        const ring = MESSAGE_RADIUS + MESSAGE_HALO_GAP_PX / scale;
        sprite.haloGfx
          .circle(0, 0, ring)
          .stroke({
            color: colors.accent,
            width: MESSAGE_HALO_WIDTH_PX / scale,
            alpha: 0.95,
          });
        if (tier === "anchor") {
          sprite.haloGfx
            .circle(0, 0, ring - MESSAGE_HALO_INNER_GAP_PX / scale)
            .stroke({
              color: colors.accent,
              width: MESSAGE_HALO_INNER_WIDTH_PX / scale,
              alpha: 0.85,
            });
        }
      } else if (hovered) {
        sprite.haloGfx
          .circle(0, 0, MESSAGE_RADIUS + MESSAGE_HOVER_GAP_PX / scale)
          .stroke({
            color: colors.accent,
            width: MESSAGE_HOVER_WIDTH_PX / scale,
            alpha: 0.5,
          });
      }
    }
    if (colorsDirty || sprite.lastBodyCleared) {
      sprite.body.clear();
      sprite.body
        .circle(0, 0, MESSAGE_RADIUS)
        .fill({ color: colors.messageInFlight })
        .stroke({ color: colors.peerStroke, width: 1.5 });
      sprite.lastBodyCleared = false;
    }
    sprite.lastColors = colors;
  }

  if (labelDirty) {
    sprite.lastLabelText = labelTextValue;
    if (sprite.labelText.text !== labelTextValue) {
      sprite.labelText.text = labelTextValue;
    }
    if (colorsDirty) sprite.labelText.style.fill = colors.text;
    layoutPillBackground(
      sprite.labelBg,
      sprite.labelText,
      colors,
      MESSAGE_LABEL,
    );
    // Theme tracked for the label even while the body is cleared, so a
    // body-hidden message does not re-layout its pill every frame.
    sprite.lastColors = colors;
  }

  sprite.container.position.set(e.position.x, e.position.y);
  // Counter-scale + position so the label sits below the dot in
  // screen pixels regardless of stage zoom. Same idiom as peer
  // labels (`NODE_LABEL_GAP_PX * counterScale`).
  sprite.label.scale.set(counterScale);
  sprite.label.position.set(
    e.position.x,
    e.position.y + MESSAGE_RADIUS + MESSAGE_LABEL_GAP_PX * counterScale,
  );
}
