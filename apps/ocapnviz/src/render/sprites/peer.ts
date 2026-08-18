/**
 * Peer node sprites — create, update, and the dirty-gated
 * body/halo/label rebuild for one peer per tick. `renderFrame` owns
 * which peers are live and their z-order; this module owns the Pixi
 * objects.
 */

import { Container, type FederatedPointerEvent, Graphics, Text } from "pixi.js";
import type { PeerEntity } from "../../engine/world.ts";
import { drawNodeActivity, drawNodeHalo, layoutPillBackground, NODE_RADIUS } from "../draw-helpers.ts";
import { colorForProfile, type ThemedColors } from "../palette.ts";
import { FONT } from "../../ui/tokens.ts";
import { NODE_LABEL, NODE_LABEL_GAP_PX, peerLabelText } from "../stage-labels.ts";
import { type HaloTier, type PeerActivity, selectModeFromModifiers, type StageHover } from "../types.ts";
import { marked } from "./mark.ts";
import type { PeerSprite, StartNodeDrag } from "./types.ts";

export function syncPeerSprite(
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
