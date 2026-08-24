/**
 * Session-curve strokes — how a session Bezier is inked and where
 * its chip sits. Pixi has no curved-dash primitive, so dashes are
 * sampled into a polyline.
 *
 * The GPU batch that owns those strokes is `edge-stroke-batch.ts`.
 * Node marks and two-click overlays stay in `draw-helpers.ts`.
 */

import type { StrokeStyle } from "pixi.js";
import { bezierAt, bezierTangent, SESSION_BUNDLE_SPACING, type SessionCurve } from "../engine/session-geometry.ts";

const EDGE_LABEL_OFFSET = 14;

/**
 * How far apart two neighbouring lanes' chips sit ALONG the corridor they
 * share, in world units.
 *
 * How big a chip is comes from `EDGE_CHIP_LABEL` in `stage-labels.ts`, which
 * is also what the renderer sets the type at: a `codec · captp` chip runs a
 * little over a hundred units wide and under twenty tall. The lanes it rides
 * are `SESSION_BUNDLE_SPACING` apart ACROSS the corridor. Thirty of separation
 * clears the height but not the width, so a bundle running roughly up the
 * screen — where across the corridor means across the page — stacked its chips
 * on top of one another. Walking each chip along the corridor puts the
 * separation on the axis that has room for it.
 *
 * More than a chip's own width, because the two separations are at right
 * angles and partly cancel on the page: at a shallow corridor angle the thirty
 * across and the walk along resolve into one nearly horizontal offset, and the
 * vertical part of it can fall under a chip's height. The pair is clear at
 * every angle once the resolved offset passes a chip's diagonal, and a hundred
 * and fifty is comfortably past it. The number is tuned rather than derived;
 * what holds it is `draw-helpers-test/chips.test.ts`, which measures a real pair of chips
 * built from `EDGE_CHIP_LABEL` at every corridor angle, so growing the type
 * turns that test red rather than quietly overlapping.
 *
 * At 100% zoom. A chip is counter-scaled and a stride is not, so zooming out
 * grows the chip against a fixed stagger; `stage-labels.ts` says why one solve
 * cannot answer that.
 *
 * Two lanes clear at every angle on any corridor with room for two chips.
 * Three usually do. More than three cannot: four chips that wide want more of
 * a typical edge than it has, and no arrangement along one line fits them.
 * They still land in four places rather than on one, which is what the creep
 * below is for.
 */
const EDGE_LABEL_LANE_STRIDE = 150;
/** How far out of the middle of its own edge a chip will walk before the
 *  walk starts creeping instead of striding, as a share of the edge. */
const EDGE_LABEL_REACH_FRACTION = 0.4;
/** What is left of the stride past that point. Not zero: a chip that simply
 *  stopped would land on the one that stopped before it, and two chips on one
 *  point read as one chip, which is the thing being fixed. */
const EDGE_LABEL_REACH_CREEP = 0.15;

/**
 * A session line's tip is round.
 *
 * Where a line meets a peer, the node body covers its end and the tip is not
 * visible either way. Where it meets a session end nobody has attributed, the
 * body is see-through, so the tip shows through it — and a flat one reads as a
 * line that was cut rather than one that arrives.
 *
 * The halo behind a selected line is stroked by the same helper, which is why
 * this belongs to the helper rather than to the line's own call: a wide flat
 * halo tip behind a round line tip would show as a square shadow around it.
 */
const ROUND_TIP = "round" as const;

/** The part of a `Graphics` the two session-line helpers use.
 *
 * Same reason as {@link MarchCanvas}: naming the four methods lets a recorder
 * stand in for a `Graphics` this suite cannot construct, so which pieces of a
 * dashed line are stroked round is ordinary testable bookkeeping. */
export interface CurveCanvas {
	moveTo(x: number, y: number): unknown;
	lineTo(x: number, y: number): unknown;
	quadraticCurveTo(cx: number, cy: number, x: number, y: number): unknown;
	stroke(style: StrokeStyle): unknown;
}

/** Stroke a Bezier curve as one continuous path. Degenerate curves
 * (control = midpoint, e.g. singleton bundles) fall back to a
 * straight line — Pixi's quadratic primitive handles that fine but
 * a moveTo+lineTo is one less segment to process. */
export function strokeCurve(
	g: CurveCanvas,
	curve: SessionCurve,
	style: { color: number; width: number; alpha: number },
): void {
	g.moveTo(curve.ax, curve.ay);
	g.quadraticCurveTo(curve.cx, curve.cy, curve.bx, curve.by);
	g.stroke({
		color: style.color,
		width: style.width,
		alpha: style.alpha,
		cap: ROUND_TIP,
	});
}

/** Sample count for Bezier → polyline walks (dashes and hit tests). */
export const CURVE_STROKE_SAMPLES = 24;

/** Dashed stroke along a Bezier — Pixi has no curved-dash primitive,
 * so we sample the curve into a polyline and walk dashes across the
 * segments. Sample count is {@link CURVE_STROKE_SAMPLES} (gives ~5 dashes
 * for our dash period at typical edge lengths).
 *
 * Each dash is ONE sub-path, however many sample boundaries it crosses. A dash
 * has to follow the curve, so a long one is several segments, and opening a
 * sub-path per segment put a line cap at every internal joint — invisible while
 * the caps were flat, and a row of beads the moment a tip is round.
 *
 * Only the line's own two tips are round. Dashed against solid is what the legend
 * reads as the codec, and rounding every dash would round the line into a bead
 * chain, so the first and last dash are stroked in a second pass.
 */
export function strokeDashedCurve(
	g: CurveCanvas,
	curve: SessionCurve,
	pattern: readonly [number, number],
	style: { color: number; width: number; alpha: number },
): void {
	const samples = CURVE_STROKE_SAMPLES;
	// Walk in cumulative arc length so the dash phase is uniform
	// (uniform-t sampling would bunch dashes near the apex on
	// strongly curved arcs).
	/** Each dash as a flat run of points, `[x, y, x, y, …]`. */
	const dashes: number[][] = [];
	let dash: number[] | null = null;
	let dashLen = 0;
	let lastX = curve.ax;
	let lastY = curve.ay;
	let on = true;
	let remaining = pattern[0];
	const closeDash = () => {
		if (dash !== null && dash.length >= 4) dashes.push(dash);
		dash = null;
		dashLen = 0;
	};
	for (let i = 1; i <= samples; i++) {
		const t = i / samples;
		const p = bezierAt(curve, t);
		const segDx = p.x - lastX;
		const segDy = p.y - lastY;
		let segLen = Math.hypot(segDx, segDy);
		if (segLen === 0) continue;
		const sx = segDx / segLen;
		const sy = segDy / segLen;
		while (segLen > 0) {
			const take = Math.min(segLen, remaining);
			const nextX = lastX + sx * take;
			const nextY = lastY + sy * take;
			if (on) {
				if (dash === null) dash = [lastX, lastY];
				dash.push(nextX, nextY);
				dashLen += take;
			}
			lastX = nextX;
			lastY = nextY;
			segLen -= take;
			remaining -= take;
			if (remaining <= 0) {
				if (on) closeDash();
				on = !on;
				remaining = on ? pattern[0] : pattern[1];
			}
		}
	}
	// A dash the curve cut short. Shorter than the line is wide, a round tip on it
	// is a dot rather than the end of a line, so the line ends at the dash before
	// it — which is where a reader would say it ends anyway.
	if (dash !== null && dashLen < style.width && dashes.length > 0) {
		dash = null;
	}
	closeDash();
	if (dashes.length === 0) return;
	const trace = (points: number[]) => {
		g.moveTo(points[0]!, points[1]!);
		for (let i = 2; i < points.length; i += 2) {
			g.lineTo(points[i]!, points[i + 1]!);
		}
	};
	// The middle, flat. Nothing to stroke when the line is one or two dashes, which
	// are both tips.
	if (dashes.length > 2) {
		for (let i = 1; i < dashes.length - 1; i++) trace(dashes[i]!);
		g.stroke({
			color: style.color,
			width: style.width,
			alpha: style.alpha,
		});
	}
	// The tips, round.
	trace(dashes[0]!);
	if (dashes.length > 1) trace(dashes[dashes.length - 1]!);
	g.stroke({
		color: style.color,
		width: style.width,
		alpha: style.alpha,
		cap: ROUND_TIP,
	});
}

/** The part of a `Container` the edge label uses.
 *
 * Same reason as {@link MarchCanvas}: naming the one method lets the geometry
 * be tested without a Pixi scene, and a real `Container` still satisfies it
 * structurally. */
export interface Positionable {
	position: { set(x: number, y: number): unknown };
}

/**
 * Edge-label position — the apex of the Bezier, offset outward along the local
 * perpendicular so the label sits clear of the stroke, and walked along the
 * corridor by however far out of the middle of its bundle this lane rides.
 * Never rotates; tilted labels are harder to read than tilted lines.
 *
 * Which lane this is comes from the curve's own bow rather than from a bundle
 * index handed in, because the bow already carries it: `curveBetween` displaces
 * the control point by twice `bundleOffset`, so the distance from the chord's
 * midpoint to the control point IS the lane's offset, doubled, and the
 * direction of that displacement is which side of the chord the lane rides.
 * Turning that direction a quarter turn gives an along-the-corridor direction
 * that does not depend on which end of the session was listed first, so two
 * lanes of one bundle walk opposite ways and separate rather than colliding.
 *
 * A trimmed edge — the prefix of a lane, drawn to a claim — bows a little less
 * than the lane it was cut from, so the lane it reads back is an estimate. It
 * is still ordered and signed the same way, which is all the stagger needs: the
 * chips have to end up in different places, not in exactly computed ones.
 *
 * A lone session is a straight curve whose control point sits on the chord
 * midpoint, so it reads back no lane and keeps the plain apex it always had.
 */
export function positionEdgeLabel(
	label: Positionable,
	curve: SessionCurve,
): void {
	const apex = bezierAt(curve, 0.5);
	const tan = bezierTangent(curve, 0.5);
	// Perpendicular to tangent; flip so y points up. The label sits
	// outside the curve's bulge so it doesn't crowd the stroke.
	let px = -tan.dy;
	let py = tan.dx;
	if (py > 0) {
		px = -px;
		py = -py;
	}
	const bowX = curve.cx - (curve.ax + curve.bx) / 2;
	const bowY = curve.cy - (curve.ay + curve.by) / 2;
	const bow = Math.hypot(bowX, bowY);
	let alongX = 0;
	let alongY = 0;
	if (bow > 0) {
		const lane = bow / (2 * SESSION_BUNDLE_SPACING);
		const chord = Math.hypot(curve.bx - curve.ax, curve.by - curve.ay);
		const want = lane * EDGE_LABEL_LANE_STRIDE;
		const reach = chord * EDGE_LABEL_REACH_FRACTION;
		const walk = want <= reach ? want : reach + (want - reach) * EDGE_LABEL_REACH_CREEP;
		alongX = (-bowY / bow) * walk;
		alongY = (bowX / bow) * walk;
	}
	label.position.set(
		apex.x + px * EDGE_LABEL_OFFSET + alongX,
		apex.y + py * EDGE_LABEL_OFFSET + alongY,
	);
}
