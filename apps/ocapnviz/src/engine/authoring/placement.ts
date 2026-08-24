/**
 * Stage pin writes — how a drag or unpin lands on the document.
 *
 * `repositionPeer` stays on the Engine: it is a hot-path special case
 * that refreshes layout and in-flight messages on the same paused
 * frame (`peer.ts` records why). This module owns only the document
 * mutation those gestures commit: a peer's `position`, an
 * unattributed end's `endpointPosition`, and the matching
 * `peer-joined` payload so fixture readers and the layout solver
 * see one pin.
 */

import { parseEndpointStageId } from "../../schema/session-end.ts";
import { patchPeerDefinition } from "../entities.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";

export function writePeerPosition(
	doc: TimelineDocument,
	peerId: string,
	position: { x: number; y: number },
): void {
	// Identity-side write first (source of truth). Mirror to the
	// event payload for fixture / wire-format consistency. Both
	// paths must stay synced — readers prefer entities, but the
	// keyframe-layout system still reads event.position.
	patchPeerDefinition(doc, peerId, {
		position: { x: position.x, y: position.y },
	});
	for (const ev of observationsOf(doc) as TimelineEvent[]) {
		if (ev.kind === "peer-joined" && ev.peerId === peerId) {
			ev.position = { x: position.x, y: position.y };
			break;
		}
	}
}

export function writeEndpointPosition(
	doc: TimelineDocument,
	endpointId: string,
	position: { x: number; y: number },
): void {
	const at = parseEndpointStageId(endpointId);
	const def = at && doc.entities?.sessions?.[at.sessionId];
	if (!at || !def) return;
	def.endpointPosition = {
		...def.endpointPosition,
		[at.side]: { x: position.x, y: position.y },
	};
}

/** Unpin a peer on the document. The engine still chooses whether
 *  that is a cold recompute or a deferred transaction write. */
export function clearPeerPositionOnDoc(
	doc: TimelineDocument,
	peerId: string,
): void {
	const def = doc.entities?.peers?.[peerId];
	if (def) delete def.position;
	for (const ev of observationsOf(doc) as TimelineEvent[]) {
		if (ev.kind === "peer-joined" && ev.peerId === peerId) {
			delete ev.position;
			break;
		}
	}
}

/** Unpin an unattributed end on the document. No-op when the id
 *  does not name an end that currently holds a pin. */
export function clearEndpointPositionOnDoc(
	doc: TimelineDocument,
	endpointId: string,
): boolean {
	const at = parseEndpointStageId(endpointId);
	const def = at && doc.entities?.sessions?.[at.sessionId];
	if (!at || !def?.endpointPosition) return false;
	delete def.endpointPosition[at.side];
	return true;
}
