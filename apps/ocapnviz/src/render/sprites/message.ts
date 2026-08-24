/**
 * In-flight message sprites — create, update, and the radius a hit
 * test must use so it measures the dot this module painted.
 *
 * `renderFrame` owns which messages are live and their z-order; this
 * module owns the Pixi objects.
 */

import { Container, type FederatedPointerEvent, Graphics, Text } from "pixi.js";
import type { MessageEntity } from "../../engine/world.ts";
import { layoutPillBackground } from "../draw-helpers.ts";
import type { ThemedColors } from "../palette.ts";
import { FONT } from "../../ui/tokens.ts";
import { MESSAGE_LABEL, MESSAGE_LABEL_GAP_PX } from "../stage-labels.ts";
import {
	type HaloTier,
	type SelectMode,
	selectModeFromModifiers,
	type StageHover,
	type StageSelection,
} from "../types.ts";
import { marked } from "./mark.ts";
import type { MessageSprite } from "./types.ts";

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

export function syncMessageSprite(
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
