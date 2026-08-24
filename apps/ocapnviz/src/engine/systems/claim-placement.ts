/**
 * Where a claim sits on the session edge it rides.
 *
 * `engine/claims.ts` decides which ends are claims. This module decides
 * the point: `CLAIM_LEAN` of the way along the curve toward the peer
 * the claim names. The layout solver treats a claim as not a body and
 * leans it afterwards, so a pull strong enough to look like this one
 * cannot distort the peers it is about.
 *
 * `claim-placement-test/` is the evidence for the fraction.
 */

import { parseEndpointStageId } from "../../schema/session-end.ts";
import { bezierAt, curveBetween, type SessionBundleEntry } from "../session-geometry.ts";
import type { Vec2 } from "../world.ts";

/**
 * How far along its own session's edge a claim sits, measured from the far end
 * of that session toward the peer the claim names.
 *
 * The drawn edge ends AT the claim, because the claim is the node that end of
 * the session sits on. So what a reader sees is a wire stopping in open space
 * beside somebody rather than a wire reaching them, which is what an unbacked
 * claim amounts to. When attribution lands the end is gone and the edge
 * terminates on the peer, with nothing else in the picture moving, because the
 * session was solved to that peer all along.
 *
 * Two thirds rather than half or three quarters, and the bundled recordings
 * say why. On every session edge they settle, two thirds leaves at least a
 * node's width of daylight between the claim's body and the peer's, and still
 * lands the claim near enough to read as being about that peer rather than as
 * a node standing on its own. Half puts the claim mid-edge, where it reads as
 * a waypoint between two peers rather than as something about one of them.
 * Three quarters brings the claim's own selection ring within a third of a
 * node of the peer's on the shortest of those edges, so picking one of the two
 * would draw a ring all but touching the other. `claim-placement-test/`
 * measures those readings over the shipped recordings, so a fixture that moved
 * its peers, or a layout that settled them differently, would take the
 * argument with it.
 *
 * Several claims about one peer need no arrangement, up to a point: each rides
 * its own session's edge, so claims arriving from different peers separate
 * without anything counting them. Claims riding parallel sessions between the
 * SAME pair describe one segment and land on one point; `claim-placement-test/`
 * pins that boundary rather than working around it.
 *
 * Exported because the placement tests read it: where a claim sits is asserted
 * as this fraction, so retuning it moves one number, and the daylight that
 * fraction buys is measured against the recordings rather than restated here.
 */
export const CLAIM_LEAN = 2 / 3;

/** The segment one claim sits on: the node its session runs from, and the
 *  peer the claim names, which is where that session is solved to end. */
export type ClaimSegment = { from: string; toward: string };

/**
 * Where a claim sits: on the curve its session would take if it reached the
 * peer it names, `CLAIM_LEAN` of the way along.
 *
 * On the curve, not on the chord between them. Sessions sharing a pair fan
 * out into arcs, and a claim rides that fan (`bundleIndices`), so a claim
 * placed on the straight line sat off its own arc — and the edge drawn to it
 * then curved somewhere else again, because a different endpoint is a
 * different chord. Placing it here and drawing the same curve's prefix makes
 * the two agree by construction: the truncated arc ENDS where the claim is.
 */
function claimLeanTo(
	fromId: string,
	from: Vec2,
	towardId: string,
	toward: Vec2,
	bundle: SessionBundleEntry,
): Vec2 {
	return bezierAt(
		curveBetween(fromId, from, towardId, toward, bundle),
		CLAIM_LEAN,
	);
}

/**
 * Which of an era's claims ride an edge, and which edge each one rides. Every
 * layout mode asks here, so a claim is placed the same way whether its era was
 * solved or authored. The answer is a segment rather than a point because the
 * solve happens in between: this runs before the forces, `placeClaims` reads
 * the solved endpoints after.
 *
 * A claim earns a segment when two things hold, and is left to the ordinary
 * standalone placement when either fails:
 *
 *   - this era draws the claim and the peer it names, which is what
 *     `onStage` has already settled — an era that does not draw the peer has
 *     nothing to aim at;
 *   - the far end of its session has a place in this era to lean FROM,
 *     because a segment needs two ends.
 *
 * Whether the claim names anybody at all is not asked here. `engine/claims.ts`
 * settles that once for the whole document, including the two ends that
 * resolve to nobody — an ambiguous name, and a name its own session already
 * reaches — so the renderer draws exactly the ends this places.
 *
 * An authored pin is deliberately not one of them. Where the author put the
 * dot and what the session is solved against are separate questions, and
 * answering the second with the first would mean a nudge of a claim moved the
 * peers: the session's link would come off the peer and back onto the claim,
 * and everything that link was holding would drift. A pinned claim is planned
 * like any other, and `placeClaims` hands it the pin instead of the lean.
 */
export function planClaimPlacements(
	nodes: ReadonlySet<string>,
	sessions: Iterable<{ a: string; b: string }>,
	onStage: ReadonlyMap<string, string>,
): Map<string, ClaimSegment> {
	const placements = new Map<string, ClaimSegment>();
	if (onStage.size === 0) return placements;

	// A stage id belongs to exactly one session, so one entry per end is
	// enough to find a claim's other end. Peers overwrite each other here and
	// that is fine: nothing ever looks a peer up.
	const otherEnd = new Map<string, string>();
	for (const s of sessions) {
		if (s.a === s.b) continue;
		otherEnd.set(s.a, s.b);
		otherEnd.set(s.b, s.a);
	}
	for (const [stageId, peerId] of onStage) {
		const other = otherEnd.get(stageId);
		if (other === undefined) continue;
		// A claim at the far end contributes the peer IT names, never its own
		// unsolved position, so the lookup is one step deep and never chases a
		// chain.
		const from = onStage.get(other) ?? other;
		if (from === peerId || !nodes.has(from)) continue;
		placements.set(stageId, { from, toward: peerId });
	}
	return placements;
}

/**
 * Give every planned claim its position: the author's, if the author placed
 * it, and otherwise the point `CLAIM_LEAN` of the way along its session's edge
 * from the far end toward the peer it names.
 *
 * After the solver rather than as a force, because the claim is not a body the
 * solve balances — a pull strong enough to look like this one is a pull strong
 * enough to distort what it is attached to.
 */
export function placeClaims(
	layout: Map<string, Vec2>,
	placements: ReadonlyMap<string, ClaimSegment>,
	pins: Map<string, Vec2>,
	bundles: ReadonlyMap<string, SessionBundleEntry>,
): void {
	for (const [stageId, segment] of placements) {
		const pin = pins.get(stageId);
		if (pin) {
			layout.set(stageId, { x: pin.x, y: pin.y });
			continue;
		}
		const from = layout.get(segment.from);
		const toward = layout.get(segment.toward);
		// No edge to sit on, because this era placed neither end of the segment.
		// Only authored mode gets here: a solved era holds a position for every
		// node it did not lean. The claim keeps what it has, which in authored
		// mode is the same nothing any node the author skipped gets.
		if (!from || !toward) continue;
		// The claim's stage id names its own session, which is how its lane in
		// the fan is found; an era that somehow lost the row falls back to the
		// lone straight lane, which is what a singleton bundle already is.
		const at = parseEndpointStageId(stageId);
		const bundle = (at && bundles.get(at.sessionId)) ??
			{ index: 0, size: 1 };
		layout.set(
			stageId,
			claimLeanTo(segment.from, from, segment.toward, toward, bundle),
		);
	}
}
