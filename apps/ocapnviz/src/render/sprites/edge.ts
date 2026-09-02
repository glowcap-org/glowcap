/**
 * Session-edge sprites — create, update, halo, hit area, and the
 * chip that rides the curve. Wire pixels live on `edgeStrokeBatch`;
 * this module owns the per-edge Pixi objects around that batch.
 *
 * `renderFrame` owns which sessions are live, their z-order, and
 * the flush; this module owns one edge's dirty-gated rebuild.
 */

import { Container, type FederatedPointerEvent, Graphics, Rectangle, Text } from "pixi.js";
import { captpVersionLabel } from "../../schema/topology.ts";
import type { SessionEntity } from "../../engine/world.ts";
import { type SessionCurve } from "../../engine/session-geometry.ts";
import { layoutPillBackground } from "../draw-helpers.ts";
import { positionEdgeLabel, strokeCurve } from "../edge-stroke.ts";
import { curveBoundsArea, curveHitArea } from "../curve-hit-area.ts";
import type { EdgeStrokeBatch } from "../edge-stroke-batch.ts";
import { CAPTP_VERSION_COLORS, lineStyleForCodec, SESSION_STATE_WIDTH, type ThemedColors } from "../palette.ts";
import { FONT } from "../../ui/tokens.ts";
import { EDGE_CHIP_LABEL } from "../stage-labels.ts";
import {
	type HaloTier,
	type SelectMode,
	selectModeFromModifiers,
	type StageHover,
	type StageSelection,
} from "../types.ts";
import { marked } from "./mark.ts";
import type { EdgeSprite } from "./types.ts";

/** How much wider than the wire itself each tier of edge halo strokes. Screen
 *  pixels, so a selected edge stays findable when the wire is a hairline. */
const EDGE_HALO_SPREAD_PX = 6;
const EDGE_HALO_INNER_SPREAD_PX = 2;
const EDGE_HOVER_SPREAD_PX = 3;

export function syncEdgeSprite(
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
			// ("capnp · glowcap-next") reads cleanly in mono at
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
			strokeBatch.upsert(e.session.id, {
				curve,
				color,
				width,
				lineStyle,
			});
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
