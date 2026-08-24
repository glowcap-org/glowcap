/**
 * Unattributed session-end sprites — create, update, and the radius
 * a hit test must use so it measures the body this module painted.
 *
 * `renderFrame` owns which ends are live; this module owns the Pixi
 * objects and the claim-vs-loose weight.
 */

import { Container, type FederatedPointerEvent, Graphics, Text } from "pixi.js";
import type { EndpointEntity } from "../../engine/world.ts";
import {
	drawLooseEndBody,
	drawNodeActivity,
	drawNodeHalo,
	layoutPillBackground,
	looseEndStyle,
} from "../draw-helpers.ts";
import { PROFILE_FALLBACK_COLOR, type ThemedColors } from "../palette.ts";
import { FONT } from "../../ui/tokens.ts";
import { endpointLabelText, NODE_LABEL, NODE_LABEL_GAP_PX } from "../stage-labels.ts";
import { type HaloTier, type PeerActivity, selectModeFromModifiers, type StageHover } from "../types.ts";
import { marked } from "./mark.ts";
import type { EndpointSprite, StartNodeDrag } from "./types.ts";

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
export function syncEndpointSprite(
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
				sprite.lastHovered !== hovered ||
				sprite.lastClaiming !== claiming ||
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
		layoutPillBackground(
			sprite.labelBg,
			sprite.labelText,
			colors,
			NODE_LABEL,
		);
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
