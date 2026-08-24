/**
 * Read-only resolvers used by the Connections sub-panels and the
 * Sidebar's section-title heuristic. Each one prefers the live ECS
 * (so in-flight edits to labels / profiles / state are reflected
 * immediately) and falls back to `doc.entities.*` when the playhead
 * is outside the entity's effective window. Returning `null` for a
 * truly unknown id is intentional — the Connections panel renders
 * an "Unknown peer id" / "Unknown session id" row so orphan
 * references stay visible instead of silently disappearing.
 */

import { SESSION_SIDES } from "../../schema/session-end.ts";
import type { Engine } from "../../engine/engine.ts";
import { findPeer, findSession } from "../../engine/world.ts";
import { findMessageInDoc } from "../../engine/event-helpers.ts";
import {
	peerLabelAt,
	peerProfileAt,
	sessionEndpointOccupants,
	sessionEndpointPlaceAt,
	sessionStateAt,
} from "../../engine/temporal/doc-resolver.ts";
import type { CaptpVersion, Codec, PeerProfile, SessionState } from "../../schema/topology.ts";
import type { EntityKind, EntityRefKey } from "../../interactions/types.ts";
import type { LifecycleStatus } from "../EntityChips.tsx";

/** "Is this entity also in the multi-select set?" — the cross-
 *  reference check the per-kind Connections rows use to light up
 *  "in selection" badges. Set undefined collapses to false so
 *  call sites pass `entitySelection` directly without the
 *  ternary. */
export function isInSelection(
	set: ReadonlySet<EntityRefKey> | undefined,
	ref: { kind: EntityKind; id: string },
): boolean {
	return set?.has(`${ref.kind}:${ref.id}` as EntityRefKey) ?? false;
}

export type PeerInfo = {
	label: string;
	profile: PeerProfile;
	lifecycle: LifecycleStatus;
};

export type SessionInfo = {
	a: string;
	b: string;
	codec: Codec;
	captpVersion: CaptpVersion;
	state: SessionState;
	lifecycle: LifecycleStatus;
};

export function peerInfo(engine: Engine, peerId: string): PeerInfo | null {
	const live = findPeer(engine.world, peerId);
	if (live) {
		return {
			label: live.peer.label,
			profile: live.peer.profile,
			lifecycle: "active",
		};
	}
	const def = engine.doc.entities?.peers?.[peerId];
	if (!def) return null;
	const start = engine.effectiveStart("peers", peerId);
	const end = engine.effectiveEnd("peers", peerId);
	const t = engine.clock.t;
	const lifecycle: LifecycleStatus = t < start ? "before" : t >= end ? "after" : "off-stage";
	return {
		label: peerLabelAt(engine.doc, peerId, t),
		profile: peerProfileAt(engine.doc, peerId, t),
		lifecycle,
	};
}

export function sessionInfo(
	engine: Engine,
	sessionId: string,
): SessionInfo | null {
	const live = findSession(engine.world, sessionId);
	if (live) {
		return {
			a: live.endpoints.a,
			b: live.endpoints.b,
			codec: live.session.codec,
			captpVersion: live.session.captpVersion,
			state: live.session.state,
			lifecycle: "active",
		};
	}
	const def = engine.doc.entities?.sessions?.[sessionId];
	if (!def) return null;
	const start = engine.effectiveStart("sessions", sessionId);
	const end = engine.effectiveEnd("sessions", sessionId);
	const t = engine.clock.t;
	const lifecycle: LifecycleStatus = t < start ? "before" : t >= end ? "after" : "off-stage";
	return {
		// Where each end sits AT the playhead, not where it sat at genesis:
		// the same rule the state below follows, and the one the stage
		// applies while the session is on it. An end that attached partway
		// through reports the peer after that moment and its own place
		// before it.
		a: sessionEndpointPlaceAt(engine.doc, sessionId, "a", t).node,
		b: sessionEndpointPlaceAt(engine.doc, sessionId, "b", t).node,
		codec: def.codec,
		captpVersion: def.captpVersion,
		state: sessionStateAt(engine.doc, sessionId, t),
		lifecycle,
	};
}

export type MessageInfo = {
	fromId: string;
	toId: string;
	sessionId: string;
	/** Sender / arrival timestamps. Drawn from the live in-flight
	 *  entity when the message is on stage; falls back to the
	 *  `message-sent` event in the doc otherwise so the panel
	 *  resolves consistently across the whole timeline. */
	sentT: number;
	arrivalT: number;
};

export function messageInfo(
	engine: Engine,
	messageId: string,
): MessageInfo | null {
	const live = (() => {
		for (const e of engine.world.with("messageInFlight", "position")) {
			if (e.messageInFlight.id === messageId) return e.messageInFlight;
		}
		return null;
	})();
	const sentEv = findMessageInDoc(engine.doc, messageId);
	if (live) {
		return {
			fromId: live.from,
			toId: live.to,
			sessionId: live.sessionId,
			sentT: sentEv?.t ?? 0,
			arrivalT: live.arrivalT,
		};
	}
	if (sentEv) {
		return {
			fromId: sentEv.from,
			toId: sentEv.to,
			sessionId: sentEv.sessionId,
			sentT: sentEv.t,
			arrivalT: sentEv.arrivalT,
		};
	}
	return null;
}

/** Every session this peer has ever been on one end of, sorted by effective
 * start. Eternal-start sessions (no `session-opened` event) interleave
 * naturally because the cascade resolves their start to
 * `max(endpoint.effectiveStart)`.
 *
 * Ever, not now: an end can change hands while the session runs, and a peer
 * that took an end only after something attributed it is still a peer this
 * session belongs to. Each row's lifecycle chip says where the playhead
 * sits, so the list stays stable across a scrub instead of emptying and
 * refilling under the reader.
 *
 * That is why membership goes through `sessionEndpointOccupants` rather than
 * through the endpoint itself: an endpoint is a structure, and comparing one
 * to a peer id is a comparison TypeScript accepts and no run answers true. */
export function sessionsTouchingPeer(
	engine: Engine,
	peerId: string,
): readonly string[] {
	const all = engine.doc.entities?.sessions ?? {};
	const order: { id: string; t: number }[] = [];
	for (const [id, def] of Object.entries(all)) {
		const onEnd = SESSION_SIDES.some((side) => sessionEndpointOccupants(def, side).includes(peerId));
		if (!onEnd) continue;
		order.push({ id, t: engine.effectiveStart("sessions", id) });
	}
	order.sort((x, y) => x.t - y.t);
	return order.map((o) => o.id);
}
