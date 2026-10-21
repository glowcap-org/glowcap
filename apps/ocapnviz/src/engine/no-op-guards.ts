/**
 * `isNoOpIntent(doc, world, t, intent)`, would this builder intent
 * change observable state? `engine.dispatch` short-circuits on
 * `true` so the undo history doesn't accumulate empty steps and
 * the post-mutation seek/notify cycle is skipped.
 *
 * Authority discipline: guards compare against the AUTHORED doc
 * state their mutation writes (`doc.entities`, `entity.timing`
 * through the effective resolvers), never against the live world,
 * an entity outside the playhead window is absent from the world
 * but its definition is still editable. The two world-read
 * exceptions, `open-session` and `send-message`, gate gestures the
 * builder only offers for live peers and say so inline.
 *
 * Saying a thing again is not the same as saying nothing. A write
 * changes nothing exactly when the document it produces is the
 * document that is already there, never when the VALUE it produces is
 * the value already showing. The two come apart wherever the document
 * can say a thing at a time, and every such write here takes the same
 * reading:
 *
 *   - A keyframe is a declaration AT a time. Stating `open` at t=5
 *     on a session that is already open at t=5 pins it there, so
 *     later edits to the genesis state, or to an earlier keyframe, status-allow: event or source ordering
 *     stop reaching past t=5. That is a real change, and only an
 *     identical declaration at the same instant is not
 *     (`keyframeExactlyAt`). `set-session-keyframe`, `set-peer-update`,
 *     and `update-session`'s `state` share one predicate below,
 *     because they are one write.
 *   - A pin is the same shape in space and in time, and the guards
 *     for `reposition-peer`, `reposition-endpoint`, and the `set-*`
 *     timing intents already read it that way: pinning a peer where
 *     the layout was already drawing it, or authoring the span
 *     projection was already deriving, moves authority even though
 *     nothing on screen moves.
 *   - A plain field carries no time, so there is nothing to pin and
 *     the value IS the document: `update-peer`, `update-session`'s
 *     `codec` / `captpVersion` / `transport`, `update-session-endpoint`, and
 *     `set-session-initial-state` compare stored value to stored
 *     value, and that is the same rule and not an exception to it.
 *
 * The consequence a reader should expect: the trajectory insert
 * control, which offers what the entity carries at the playhead so
 * the new row arrives saying something true, inserts that row.
 * Pressing it again at the same playhead does nothing, because the
 * second press would produce the document the first one already
 * produced.
 *
 * Pure: reads `doc`, the ECS `world`, the playhead `t`, and the
 * intent payload. No side effects, no engine internals.
 */

import type { TimelineDocument, TimelineEvent } from "./timeline.ts";
import { messageEffective, peerEffective, sessionEffective } from "./temporal/doc-resolver.ts";
import { keyframeExactlyAt, type KeyframeTrack } from "./temporal/keyframes.ts";
import { observationsOf } from "./temporal/recording-access.ts";
import { isDerived, type TimeSpan } from "./temporal/time-span.ts";
import { authoredPeerPosition } from "./event-helpers.ts";
import { findNode, type GameWorld } from "./world.ts";
import { parseEndpointStageId } from "../schema/session-end.ts";
import { allVisModeOnDoc, categoryVisModeOnDoc, rowVisModeOnDoc } from "./visibility.ts";
import type { BuilderIntent } from "./intents.ts";
import { PEER_TRAJECTORY, SESSION_TRAJECTORY } from "./trajectory.ts";

/** The span, only when the USER authored it. A `set-*` timing
 *  intent is never a no-op against a projection-derived span: even
 *  re-stating the derived value changes the span's authority
 *  (projection stops re-deriving it as observations grow), the
 *  same rule as pinning a peer at its current layout position. */
function authoredTiming(
	span: TimeSpan | undefined,
): TimeSpan | undefined {
	return span !== undefined && !isDerived(span) ? span : undefined;
}

/** Does the track already declare `value` at exactly `t`?
 *
 *  The one rule behind every trajectory write, stated once so the two
 *  lanes and the two spellings of the session write cannot disagree
 *  about it. It reads the declaration at `t` and not the value in
 *  effect there, for the reason the module header gives: a keyframe
 *  restating what the property already carries still pins it.
 *
 *  `same` says what "already" means, because a track's value is not always
 *  a word: an end's is a pair, and a write that keeps the peer and drops
 *  what backed it produces a different document. Identity is the default
 *  and the whole of it for a track of words. */
function declaresValueAt<T>(
	track: KeyframeTrack<T> | undefined,
	t: number,
	value: T,
	same: (a: T, b: T) => boolean = (a, b) => a === b,
): boolean {
	const declared = keyframeExactlyAt(track, t);
	return declared !== undefined && same(declared.value, value);
}

/** Does the track declare anything at exactly `t`? A removal takes
 *  the declaration standing there, so an instant with none is an
 *  instant with nothing to take. The same question `declaresValueAt`
 *  asks, without the value. */
function declaresAnythingAt<T>(
	track: KeyframeTrack<T> | undefined,
	t: number,
): boolean {
	return keyframeExactlyAt(track, t) !== undefined;
}

export function isNoOpIntent(
	doc: TimelineDocument,
	world: GameWorld,
	t: number,
	intent: BuilderIntent,
): boolean {
	switch (intent.kind) {
		case "add-peer":
			return false;
		case "clear-peer-position":
			// Unpinning an unpinned peer changes nothing.
			return authoredPeerPosition(doc, intent.peerId) === null;
		case "reposition-peer": {
			// Compare against the AUTHORED position, not the live world:
			// the layout always fills the world position, so pinning an
			// unpinned peer at its current spot is a real doc change
			// ("Pin here"), never a no-op. Unknown peers are, and known
			// means defined in the doc, not present in the world, so the
			// Inspector can pin a peer outside the playhead window.
			if (doc.entities?.peers?.[intent.peerId] === undefined) return true;
			const pinned = authoredPeerPosition(doc, intent.peerId);
			return pinned !== null &&
				pinned.x === intent.position.x &&
				pinned.y === intent.position.y;
		}
		case "clear-endpoint-position": {
			// Unpinning an end nobody placed changes nothing.
			const at = parseEndpointStageId(intent.endpointId);
			if (!at) return true;
			return doc.entities?.sessions?.[at.sessionId]
				?.endpointPosition?.[at.side] === undefined;
		}
		case "reposition-endpoint": {
			// Same rule as `reposition-peer`: compare against the AUTHORED pin,
			// because the layout always fills the world position and pinning an
			// unpinned end where it already sits is a real document change.
			const at = parseEndpointStageId(intent.endpointId);
			if (!at) return true;
			const def = doc.entities?.sessions?.[at.sessionId];
			if (def === undefined) return true;
			const pinned = def.endpointPosition?.[at.side];
			return pinned !== undefined &&
				pinned.x === intent.position.x &&
				pinned.y === intent.position.y;
		}
		case "update-peer": {
			// The mutation patches `doc.entities.peers`, compare against
			// that definition, not the world entity materialized from it.
			const def = doc.entities?.peers?.[intent.peerId];
			if (!def) return true;
			const p = intent.patch;
			if (p.label !== undefined && p.label !== def.label) return false;
			if (p.profile !== undefined && p.profile !== def.profile) {
				return false;
			}
			// An empty patch value drops the field, so "" ≡ absent.
			if (
				p.designator !== undefined &&
				p.designator !== (def.designator ?? "")
			) return false;
			return true;
		}
		case "open-session": {
			// An end attached to a peer can only be drawn against a peer
			// that is live (yes, peer-joined could land later in the
			// timeline, but the builder only ever offers open-session for
			// live peers). An end attached to NOBODY has no such
			// precondition: nothing has to exist for a claim to be made,
			// which is the whole point of a loose end.
			//
			// A session with one peer on both ends is not refused here. It is
			// a shape the recording holds, a host that dials itself reports
			// exactly that, `updateSessionEndpoint` writes it after the fact,
			// and the layout already drops the self-link its edge would make.
			// Build mode's claim is that every shape a recording can hold can
			// be authored, so refusing it here made the creation door the one
			// place the answer was different, and it refused in silence.
			//
			// The question here is only whether the STAGE NODE is there, which is
			// the same distinction the paragraph above draws: a click on nothing
			// changes nothing, and that is a no-op. A click on an end nothing has
			// attributed is a different matter, the node IS there, and what is
			// wrong is what is being asked of it, so it must reach the intent and
			// be refused with a reason. Asking for a peer here made that refusal
			// silent, which is the failure the paragraph above already names.
			const a = intent.a.peer;
			const b = intent.b.peer;
			if (a !== undefined && !findNode(world, a)) return true;
			if (b !== undefined && !findNode(world, b)) return true;
			return false;
		}
		case "send-message":
			// Either end may be a peer or an end nothing has attributed, so the
			// question is whether the STAGE NODE is there, not whether a peer is.
			// Asking for a peer made a message to a loose end look like a request
			// to change nothing, and it was dropped in silence. The worst shape a
			// refusal can take, because the gesture and the document both look
			// fine afterwards.
			return !findNode(world, intent.from) || !findNode(world, intent.to);
		case "delete-peer": {
			// Eternal-start entities live only in `doc.entities` (no
			// creation event). The guard must check BOTH or the delete
			// silently no-ops for them. The cascade in `deletePeer`
			// itself handles eternal peers correctly, so this guard must not
			// short-circuit on events alone.
			const obs = observationsOf(doc) as readonly TimelineEvent[];
			const hasEvent = obs.some(
				(ev) => ev.kind === "peer-joined" && ev.peerId === intent.peerId,
			);
			const hasEternal = doc.entities?.peers?.[intent.peerId] !== undefined &&
				!hasEvent;
			return !hasEvent && !hasEternal;
		}
		case "delete-session": {
			const obs = observationsOf(doc) as readonly TimelineEvent[];
			const hasEvent = obs.some(
				(ev) =>
					ev.kind === "session-opened" &&
					ev.sessionId === intent.sessionId,
			);
			const hasEternal = doc.entities?.sessions?.[intent.sessionId] !== undefined &&
				!hasEvent;
			return !hasEvent && !hasEternal;
		}
		case "delete-message": {
			const obs = observationsOf(doc) as readonly TimelineEvent[];
			const hasEvent = obs.some(
				(ev) =>
					ev.kind === "message-sent" &&
					ev.messageId === intent.messageId,
			);
			const hasEternal = doc.entities?.messages?.[intent.messageId] !== undefined &&
				!hasEvent;
			return !hasEvent && !hasEternal;
		}
		case "update-session": {
			// Same doc-definition authority as update-peer for the three
			// fields that carry no time.
			const def = doc.entities?.sessions?.[intent.sessionId];
			if (!def) return true;
			const p = intent.patch;
			if (p.codec !== undefined && p.codec !== def.codec) {
				return false;
			}
			if (
				p.captpVersion !== undefined &&
				p.captpVersion !== def.captpVersion
			) return false;
			// `null` stops stating a transport, so it changes something
			// exactly when there is one to stop stating. The same reading
			// `update-session-endpoint` takes of a cleared field.
			if (
				p.transport !== undefined &&
				(p.transport ?? undefined) !== def.transport
			) return false;
			// The `state` patch is a keyframe at the playhead, the write
			// `set-session-keyframe` makes, reached by a second name, so
			// it asks the keyframe question, through the same predicate.
			// Comparing against the state RESOLVED at `t` instead refuses
			// to pin a value the session already carries, which is a
			// document change the author cannot then make from here while
			// the trajectory row makes it happily.
			const state = SESSION_TRAJECTORY.state;
			if (
				p.state !== undefined &&
				!declaresValueAt(
					state.track(def),
					t,
					state.parse(p.state),
					state.same,
				)
			) {
				return false;
			}
			return true;
		}
		case "update-message": {
			// Read the entity definition (authoring source of truth) rather
			// than the message-sent observation event. cascadeRewrite re-keys
			// entities but leaves observation events alone, so
			// a renamed message's only valid lookup is via `doc.entities`.
			const def = doc.entities?.messages?.[intent.messageId];
			if (!def) return true;
			const p = intent.patch;
			if (p.label !== undefined && p.label !== (def.label ?? "")) {
				return false;
			}
			if (p.sessionId !== undefined && p.sessionId !== def.sessionId) {
				return false;
			}
			if (p.swapDirection === true) return false;
			return true;
		}
		case "move-entity-span": {
			const move = intent.move;
			const eff = move.ref.kind === "peer" ? peerEffective(doc, move.ref.id) : sessionEffective(doc, move.ref.id);
			// The gesture drives one edge; unmoved is a no-op. A translate
			// anchors on the start.
			const current = move.kind === "resize-end" ? eff.end : eff.start;
			return current === move.newT;
		}
		case "move-event": {
			const move = intent.move;
			const ev: TimelineEvent | undefined = (
				observationsOf(doc) as readonly TimelineEvent[]
			).find((e) => e.id === move.eventId);
			if (!ev) return true;
			// A committed move writes BOTH authorities, the observation
			// anchor and the painted (effective) span, so a no-op needs
			// both to already agree with the gesture. Comparing the
			// observation alone drops a real drag whenever a
			// storage-shaped Inspector edit (set-message-duration,
			// set-peer-duration, …) has retimed the painted span without
			// moving the observation.
			if (move.kind === "resize-end") {
				return ev.kind === "message-sent" &&
					ev.arrivalT === move.newArrivalT &&
					messageEffective(doc, ev.messageId).end ===
						move.newArrivalT;
			}
			if (ev.t !== move.newT) return false;
			// Close events ARE the right edge: their move pins the
			// painted end at `newT`.
			if (ev.kind === "peer-left") {
				return peerEffective(doc, ev.peerId).end === move.newT;
			}
			if (ev.kind === "session-closed") {
				return sessionEffective(doc, ev.sessionId).end === move.newT;
			}
			// A left-edge resize pins the painted start at `newT`; a
			// translate with dt = 0 leaves the painted span in place.
			if (move.kind === "resize-start") {
				if (ev.kind === "peer-joined") {
					return peerEffective(doc, ev.peerId).start === move.newT;
				}
				if (ev.kind === "session-opened") {
					return sessionEffective(doc, ev.sessionId).start ===
						move.newT;
				}
				if (ev.kind === "message-sent") {
					return messageEffective(doc, ev.messageId).start ===
						move.newT;
				}
			}
			return true;
		}
		case "reorder-row": {
			const current = doc.rowOrder?.[intent.category];
			// No change ⇒ no-op (skip history). Compare element-wise.
			if (
				(current === undefined && intent.order.length === 0) ||
				(current !== undefined &&
					current.length === intent.order.length &&
					current.every((id, i) => id === intent.order[i]))
			) return true;
			return false;
		}
		case "set-row-vis-mode": {
			const current = rowVisModeOnDoc(doc, intent.category, intent.id);
			return current === intent.mode;
		}
		case "set-category-vis-mode":
			return categoryVisModeOnDoc(doc, intent.category) === intent.mode;
		case "set-all-vis-mode":
			return allVisModeOnDoc(doc) === intent.mode;
		case "set-peer-end": {
			// The mutation derives duration from the EFFECTIVE start (the
			// painted anchor), so the guard must too. An implicit start
			// retains its last stored value, which the resolvers ignore.
			const dur = authoredTiming(
				doc.entities?.peers?.[intent.peerId]?.timing,
			)
				?.duration;
			return dur?.explicit === true &&
				peerEffective(doc, intent.peerId).start + dur.value ===
					intent.t;
		}
		case "set-peer-duration": {
			const def = doc.entities?.peers?.[intent.peerId];
			const dur = authoredTiming(def?.timing)?.duration;
			return dur?.explicit === true && dur.value === intent.duration;
		}
		case "clear-peer-end": {
			const def = doc.entities?.peers?.[intent.peerId];
			return def === undefined || def.timing?.duration.explicit !== true;
		}
		case "set-peer-start": {
			const def = doc.entities?.peers?.[intent.peerId];
			const s = authoredTiming(def?.timing)?.start;
			return s?.explicit === true && s.value === intent.t;
		}
		case "clear-peer-start": {
			const def = doc.entities?.peers?.[intent.peerId];
			return def === undefined || def.timing?.start.explicit !== true;
		}
		case "set-session-start": {
			const def = doc.entities?.sessions?.[intent.sessionId];
			const s = authoredTiming(def?.timing)?.start;
			return s?.explicit === true && s.value === intent.t;
		}
		case "clear-session-start": {
			const def = doc.entities?.sessions?.[intent.sessionId];
			return def === undefined || def.timing?.start.explicit !== true;
		}
		case "set-message-start": {
			const def = doc.entities?.messages?.[intent.messageId];
			const s = authoredTiming(def?.timing)?.start;
			return s?.explicit === true && s.value === intent.t;
		}
		case "clear-message-start": {
			const def = doc.entities?.messages?.[intent.messageId];
			return def === undefined || def.timing?.start.explicit !== true;
		}
		case "set-message-end": {
			// Effective-start anchor, same rationale as set-peer-end.
			const dur = authoredTiming(
				doc.entities?.messages?.[intent.messageId]?.timing,
			)?.duration;
			return dur?.explicit === true &&
				messageEffective(doc, intent.messageId).start + dur.value ===
					intent.t;
		}
		case "set-message-duration": {
			const def = doc.entities?.messages?.[intent.messageId];
			const dur = authoredTiming(def?.timing)?.duration;
			return dur?.explicit === true && dur.value === intent.duration;
		}
		case "set-session-end": {
			// Effective-start anchor, same rationale as set-peer-end.
			const dur = authoredTiming(
				doc.entities?.sessions?.[intent.sessionId]?.timing,
			)?.duration;
			return dur?.explicit === true &&
				sessionEffective(doc, intent.sessionId).start + dur.value ===
					intent.t;
		}
		case "set-session-duration": {
			const def = doc.entities?.sessions?.[intent.sessionId];
			const dur = authoredTiming(def?.timing)?.duration;
			return dur?.explicit === true && dur.value === intent.duration;
		}
		case "clear-session-end": {
			const def = doc.entities?.sessions?.[intent.sessionId];
			return def === undefined || def.timing?.duration.explicit !== true;
		}
		case "set-session-keyframe": {
			// Reads the property's track, which is where both storage
			// halves land, the authored state track, and the endpoint
			// tracks the projection derives, so one question covers every
			// session property. The comparison is against the value this
			// write would PRODUCE, not against the row's string: attaching an
			// end that a signed handoff had attributed produces a pair with
			// nothing backing it, which is a change even though the same peer
			// stays there.
			const def = doc.entities?.sessions?.[intent.sessionId];
			if (!def) return true;
			const spec = SESSION_TRAJECTORY[intent.property];
			return declaresValueAt(
				spec.track(def),
				intent.t,
				spec.parse(intent.value),
				spec.same,
			);
		}
		case "remove-session-keyframe": {
			const def = doc.entities?.sessions?.[intent.sessionId];
			if (!def) return true;
			return !declaresAnythingAt(
				SESSION_TRAJECTORY[intent.property].track(def),
				intent.t,
			);
		}
		case "update-session-endpoint": {
			// Compare against the stored endpoint, field by field. `null`
			// clears, so it changes something exactly when the field is
			// there to clear; an empty designator reads as absent for the
			// same reason a peer's emptied identifier does.
			//
			// This is the genesis end, the value the session is BORN with,
			// which carries no time, so restating it writes the field it
			// already holds and there is nothing pinned by having said it
			// again. Attaching an end AT a time is `set-session-keyframe`,
			// and that one is a declaration and reads as one.
			const end = doc.entities?.sessions?.[intent.sessionId]
				?.[intent.side];
			if (!end) return true;
			const p = intent.patch;
			if (p.peer !== undefined && (p.peer ?? undefined) !== end.peer) {
				return false;
			}
			if (p.designator !== undefined) {
				const next = p.designator === null || p.designator === "" ? undefined : p.designator;
				if (next !== end.designator) return false;
			}
			if (
				p.attributedBy !== undefined &&
				(p.attributedBy ?? undefined) !== end.attributedBy
			) return false;
			return true;
		}
		case "set-peer-update": {
			// The peer lane's moments are the same shape as the session's,
			// so they take the same reading. The projection puts these
			// observations on the property's track, and the track is what
			// the document says.
			const def = doc.entities?.peers?.[intent.peerId];
			if (!def) return true;
			return declaresValueAt(
				PEER_TRAJECTORY[intent.property].track(def),
				intent.t,
				intent.value,
			);
		}
		case "remove-peer-update": {
			const def = doc.entities?.peers?.[intent.peerId];
			if (!def) return true;
			return !declaresAnythingAt(
				PEER_TRAJECTORY[intent.property].track(def),
				intent.t,
			);
		}
		case "set-session-initial-state": {
			const def = doc.entities?.sessions?.[intent.sessionId];
			return def === undefined || def.initialState === intent.state;
		}
		case "rename-peer":
		case "rename-session":
		case "rename-message":
			// No-op when same-id rename. Collisions are NOT a no-op (we
			// want the dispatch path to run so the error channel fires);
			// the `validate` pre-flight gives UI an inline path that
			// skips dispatch entirely.
			return intent.oldId === intent.newId;
	}
}
