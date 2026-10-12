/**
 * What a layout node occupies on the canvas.
 *
 * Half-width and vertical reach are the box the force solver separates, and
 * `nodeFootprint` is how a label grows that box. This module also gathers
 * those boxes from the document (`nodeFootprints`), `force-layout.ts` anneals
 * them.
 */

import { endpointStageId, SESSION_SIDES } from "../../schema/session-end.ts";
import {
	endpointLabelText,
	NODE_LABEL,
	NODE_LABEL_GAP_PX,
	peerLabelText,
	pillSize,
} from "../../render/stage-labels.ts";
import { endpointClaims } from "../claims.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { observationsOf } from "../temporal/recording-access.ts";

/**
 * Half a node's body, in world units. It mirrors `NODE_RADIUS` in
 * `src/render/draw-helpers.ts`, which is the authority for what is drawn,
 * `keyframe-layout-test/separation.test.ts` reads that one and asserts the two agree,
 * so the mirror cannot drift silently. It is a mirror rather than an import
 * because layout is engine and the drawn radius is render. The label sizes
 * have no such problem and are imported from the leaf `render/stage-labels.ts`.
 */
export const NODE_HALF_WIDTH = 30;

/**
 * What one node covers on the canvas, as an axis-aligned box around its
 * position: half the width of the widest thing drawn there, and how far the
 * drawing reaches above and below the point itself.
 *
 * Asymmetric because the label hangs below the body, which is the whole
 * reason a circle was the wrong model. Two nodes side by side must clear each
 * other's labels. Two nodes stacked need only the body-to-label gap, and a
 * circle wide enough for the first spends that width on the second as well.
 *
 * World units at 100% zoom, which is where it matches the drawing. A label
 * holds a fixed screen size as the stage zooms while this box does not, so
 * zooming out grows every label against a graph that stays the size it was
 * solved at. One solve cannot answer every zoom, `render/stage-labels.ts`
 * carries that tension and bounds how wide the worst label gets.
 */
export type NodeFootprint = {
	halfWidth: number;
	above: number;
	below: number;
};

/**
 * The box a node with this label covers. `mono` picks the family the label is
 * drawn in: a designator is a wire identifier and renders monospaced, a peer's
 * display name renders proportionally.
 */
export function nodeFootprint(label: string, mono: boolean): NodeFootprint {
	const pill = pillSize(label.length, NODE_LABEL, mono);
	return {
		halfWidth: Math.max(NODE_HALF_WIDTH, pill.width / 2),
		above: NODE_HALF_WIDTH,
		below: NODE_HALF_WIDTH + NODE_LABEL_GAP_PX + pill.height,
	};
}

/** The footprint of a node the document says nothing about, which is a bare
 *  body. Used for a node that reaches the solver without a label of its own. */
export const BARE_FOOTPRINT: NodeFootprint = {
	halfWidth: NODE_HALF_WIDTH,
	above: NODE_HALF_WIDTH,
	below: NODE_HALF_WIDTH,
};

/**
 * The box every node the document mentions covers, keyed by node id.
 *
 * Derived once per recompute and shared by every era, because a node's
 * footprint is a fact about the document rather than about one moment. A peer
 * measured by the WIDEST name the document ever gives it, rather than by the
 * name it wears at this keyframe's `t`, so that renaming a peer mid-timeline
 * moves nothing: a footprint that grew and shrank with the playhead would
 * shuffle the graph at a moment when no topology changed.
 *
 * A node the document says nothing about, one the solver reaches through a
 * link alone, takes the bare body, which is the smallest safe guess.
 *
 * Every caption is measured as the renderer will DRAW it, through the same
 * `peerLabelText` / `endpointLabelText` the renderer sets its text from. A
 * box reserved for the whole string while a shortened one is drawn is
 * daylight nobody can see, and the widest-name search has to run on the drawn
 * forms too: two names that both elide come out the same width, so the longer
 * raw string is not the wider label.
 */
export function nodeFootprints(
	doc: TimelineDocument,
): Map<string, NodeFootprint> {
	const boxes = new Map<string, NodeFootprint>();
	for (const [peerId, def] of Object.entries(doc.entities?.peers ?? {})) {
		let widest = peerLabelText(def.label ?? peerId);
		for (const kf of def.keyframes?.label ?? []) {
			const drawn = peerLabelText(kf.value);
			if (drawn.length > widest.length) widest = drawn;
		}
		boxes.set(peerId, nodeFootprint(widest, false));
	}
	for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
		if (ev.kind !== "peer-joined") continue;
		if (boxes.has(ev.peerId)) continue; // entities entry won
		boxes.set(
			ev.peerId,
			nodeFootprint(peerLabelText(ev.label ?? ev.peerId), false),
		);
	}
	// An end that nothing has attributed wears its claim, or the plain word the
	// renderer shows for having no claim at all. Both ends of every session are
	// listed; the attributed ones never hold a stage id, so their entries are
	// never looked up.
	const claims = endpointClaims(doc);
	for (const sessionId of Object.keys(doc.entities?.sessions ?? {})) {
		for (const side of SESSION_SIDES) {
			const stageId = endpointStageId(sessionId, side);
			boxes.set(
				stageId,
				nodeFootprint(endpointLabelText(claims.get(stageId)), true),
			);
		}
	}
	for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
		if (ev.kind !== "session-opened") continue;
		for (const side of SESSION_SIDES) {
			const stageId = endpointStageId(ev.sessionId, side);
			if (boxes.has(stageId)) continue;
			boxes.set(
				stageId,
				nodeFootprint(endpointLabelText(claims.get(stageId)), true),
			);
		}
	}
	return boxes;
}
