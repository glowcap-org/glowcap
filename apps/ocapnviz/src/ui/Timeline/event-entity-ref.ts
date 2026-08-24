// Map a TimelineEvent to the EntityRef of the entity it
// observes. Both ends of a pair (peer-joined/-left, session-
// opened/-closed, message-sent/-delivered) resolve to the same
// ref — that's the point of the unified entity selection: one
// click on either end selects the underlying entity, and the
// Scrubber highlights both ends together.

import type { TimelineEvent } from "../../engine/timeline.ts";
import type { EntityRef } from "../../interactions/types.ts";

export function eventEntityRef(ev: TimelineEvent): EntityRef {
	switch (ev.kind) {
		case "peer-joined":
		case "peer-updated":
		// The viewer lost sight of it; the row it ends is still the peer's.
		case "peer-unobserved":
		case "peer-left":
			return { kind: "peer", id: ev.peerId };
		case "session-opened":
		case "session-closed":
		case "session-state-changed":
		case "session-endpoint-attributed":
		case "session-unobserved":
			return { kind: "session", id: ev.sessionId };
		case "message-sent":
		case "message-delivered":
			return { kind: "message", id: ev.messageId };
	}
}
