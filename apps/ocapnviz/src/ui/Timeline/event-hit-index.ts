/**
 * Stable identity and observation-anchor index for Timeline hit testing.
 *
 * Viewport geometry and effective times remain live reads elsewhere. This
 * module owns only the document shape that is expensive and unnecessary to
 * rediscover on every pointermove.
 */

import { momentOf } from "../../engine/event-helpers.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import type { MomentLane } from "../../engine/trajectory.ts";

export type MomentHit = {
	event: TimelineEvent;
	ownerId: string;
};

export type EventHitIndex = {
	peerIds: readonly string[];
	sessionIds: readonly string[];
	messageIds: readonly string[];
	peerJoined: ReadonlyMap<string, TimelineEvent>;
	peerLeft: ReadonlyMap<string, TimelineEvent>;
	sessionOpened: ReadonlyMap<string, TimelineEvent>;
	sessionClosed: ReadonlyMap<string, TimelineEvent>;
	messageSent: ReadonlyMap<string, TimelineEvent>;
	moments: Record<MomentLane, readonly MomentHit[]>;
	momentsByOwner: Record<
		MomentLane,
		ReadonlyMap<string, readonly MomentHit[]>
	>;
};

export function buildEventHitIndex(
	doc: TimelineDocument,
	events: readonly TimelineEvent[],
): EventHitIndex {
	const peerJoined = new Map<string, TimelineEvent>();
	const peerLeft = new Map<string, TimelineEvent>();
	const sessionOpened = new Map<string, TimelineEvent>();
	const sessionClosed = new Map<string, TimelineEvent>();
	const messageSent = new Map<string, TimelineEvent>();
	const moments: Record<MomentLane, MomentHit[]> = {
		peers: [],
		sessions: [],
	};
	const momentsByOwner: Record<MomentLane, Map<string, MomentHit[]>> = {
		peers: new Map(),
		sessions: new Map(),
	};
	for (const event of events) {
		switch (event.kind) {
			case "peer-joined":
				peerJoined.set(event.peerId, event);
				break;
			case "peer-left":
				peerLeft.set(event.peerId, event);
				break;
			case "session-opened":
				sessionOpened.set(event.sessionId, event);
				break;
			case "session-closed":
				sessionClosed.set(event.sessionId, event);
				break;
			case "message-sent":
				messageSent.set(event.messageId, event);
				break;
		}
		const moment = momentOf(event);
		if (moment === null) continue;
		const entry = { event, ownerId: moment.owner };
		moments[moment.lane].push(entry);
		const byOwner = momentsByOwner[moment.lane];
		const ownerMoments = byOwner.get(moment.owner);
		if (ownerMoments === undefined) byOwner.set(moment.owner, [entry]);
		else ownerMoments.push(entry);
	}
	return {
		peerIds: Object.keys(doc.entities?.peers ?? {}),
		sessionIds: Object.keys(doc.entities?.sessions ?? {}),
		messageIds: Object.keys(doc.entities?.messages ?? {}),
		peerJoined,
		peerLeft,
		sessionOpened,
		sessionClosed,
		messageSent,
		moments,
		momentsByOwner,
	};
}
