/**
 * Materialize the ECS world to match the doc's view of time t.
 *
 * Replaces the event-application replay model with a state-
 * reconciler. At any t, the world should contain exactly the
 * entities whose `effective` range contains t, with their
 * per-property values (notably `session.state`) resolved from
 * keyframe tracks.
 *
 * Pure consequence of `doc.entities` + their `timing` + their
 * `keyframes` at the requested t. No event walks.
 *
 * Called by the engine on every seek. Positions are NOT set here,
 * KeyframeLayoutSystem owns positions and runs after.
 */

import type { SessionState } from "../../schema/topology.ts";
import { endpointStageId, SESSION_SIDES } from "../../schema/session-end.ts";
import { containsTime } from "../temporal/range.ts";
import {
	messageEffective,
	peerEffective,
	peerLabelAt,
	peerProfileAt,
	sessionEffective,
	sessionEndpointPlaceAt,
	sessionStateAt,
} from "../temporal/doc-resolver.ts";
import type { TimelineDocument } from "../timeline.ts";
import { findEndpoint, findPeer, findSession, type GameWorld } from "../world.ts";

/**
 * Whether two component records carry the same values.
 *
 * Every component here is a flat record of scalars, so a shallow walk is the
 * whole comparison. It compares the RECORD rather than a list of named
 * fields, and that is the point: each branch below builds the component the
 * entity should carry and writes it when it differs, so one line creates the
 * value and the same line reconciles it. A field named in the create and
 * forgotten in the reconcile is right on a fresh seek and stale on the live
 * path, and it is the live path that never rebuilds.
 */
function sameFields(
	a: Record<string, unknown>,
	b: Record<string, unknown>,
): boolean {
	const keys = Object.keys(a);
	if (keys.length !== Object.keys(b).length) return false;
	for (const key of keys) if (a[key] !== b[key]) return false;
	return true;
}

export function materializeWorldAt(
	world: GameWorld,
	doc: TimelineDocument,
	t: number,
): boolean {
	// What the world already holds, by id, read once.
	//
	// This runs on every frame of playback and asks after every entity the
	// document declares, so a scan per question is a scan per entity per frame:
	// quadratic in the document, and the largest term is sessions, which outnumber
	// peers. On a corpus of 2,768 entities that was millions of comparisons a frame
	// and the shape a stutter takes as a document grows.
	//
	// Built here rather than kept on the world because the pass mutates as it goes
	// and a durable index would need every add and remove in the codebase to
	// maintain it. One pass over the world costs what one of these questions used
	// to, and the adds below keep it true for the rest of the pass.
	//
	// Returns whether peer / endpoint / session membership (or a session's
	// endpoint ids) changed. Claim/bundle tables are a function of that set,
	// not of positions or message flights, so the engine can keep them across
	// playing frames that only move nodes.
	let pairTopologyChanged = false;
	const heldPeers = new Map<string, ReturnType<typeof findPeer>>();
	for (const e of world.with("peer")) heldPeers.set(e.peer.id, e);
	const heldSessions = new Map<string, ReturnType<typeof findSession>>();
	// Same query `findSession` uses: a session entity always carries its ends.
	for (const e of world.with("session", "endpoints")) {
		heldSessions.set(e.session.id, e);
	}
	const heldEndpoints = new Map<string, ReturnType<typeof findEndpoint>>();
	for (const e of world.with("endpoint")) heldEndpoints.set(e.endpoint.id, e);
	const heldMessages = new Map<string, ReturnType<typeof findMessage>>();
	for (const e of world.with("messageInFlight")) {
		heldMessages.set(e.messageInFlight.id, e);
	}

	// --- Peers (with label keyframe lookup) ---
	const peers = doc.entities?.peers ?? {};
	for (const [peerId, def] of Object.entries(peers)) {
		const alive = containsTime(peerEffective(doc, peerId), t);
		const existing = heldPeers.get(peerId);
		if (alive) {
			// Every temporal property of a peer resolves at `t`, and each
			// reconciles onto an entity the world already holds: nothing
			// resets the world on the live path, so this is the only place
			// a change lands.
			//
			// The designator is among them, and it has to be: an author editing the
			// durable name a peer answers to (`authoring/peer.ts`) writes the
			// definition, and a peer whose world entity kept the old name is a peer status-allow: replacement state identity
			// no session end's claim can match. It is read off the definition
			// rather than at `t` because it does not change while the peer lives,
			// a peer that turns out to be someone else is that other peer, not a
			// rename.
			const next = {
				id: peerId,
				label: peerLabelAt(doc, peerId, t),
				profile: peerProfileAt(doc, peerId, t),
				...(def.designator !== undefined ? { designator: def.designator } : {}),
			};
			if (!existing) {
				// Clone position so KeyframeLayoutSystem's in-place mutation
				// of the world-entity position doesn't poison the
				// identity-side `def.position` record.
				const startPos = def.position ? { x: def.position.x, y: def.position.y } : { x: 0, y: 0 };
				heldPeers.set(
					peerId,
					world.add({ peer: next, position: startPos }),
				);
				pairTopologyChanged = true;
			} else if (!sameFields(existing.peer, next)) {
				existing.peer = next;
			}
		} else if (existing) {
			world.remove(existing);
			heldPeers.delete(peerId);
			pairTopologyChanged = true;
		}
	}

	// --- Sessions (with state keyframe lookup) ---
	const sessions = doc.entities?.sessions ?? {};
	for (const [sessionId, def] of Object.entries(sessions)) {
		const alive = containsTime(sessionEffective(doc, sessionId), t);
		const existing = heldSessions.get(sessionId);
		// Who is on each end is as temporal as the session's state: a
		// viewer draws a wire before it can name the peer that dialed
		// it, and learning that moves the edge rather than replacing
		// the session. Where each end sits, and whether anything attributed
		// it, are one question asked in one place, and it has an answer at
		// every t whether or not the session is drawn there.
		const place = {
			a: sessionEndpointPlaceAt(doc, sessionId, "a", t),
			b: sessionEndpointPlaceAt(doc, sessionId, "b", t),
		};
		// An end nothing has attributed is a node in its own right: the edge
		// needs something to reach at both ends, and a reader needs something
		// to select in order to ask what this end claims. Its id names the end
		// rather than the claim it carries, and it exists exactly while the
		// session is drawn and that end is loose. So it reconciles the way
		// everything else here does, add and remove from the same test:
		// attribution takes it off the stage, and so does the session ending.
		// An end belongs to its session, and a session that is no longer drawn status-allow: lifecycle transition
		// has no ends to draw.
		for (const side of SESSION_SIDES) {
			const nodeId = endpointStageId(sessionId, side);
			const loose = alive && place[side].peer === undefined;
			const drawn = heldEndpoints.get(nodeId);
			// What the end claims is stated once, when the session opens, so it
			// comes off the genesis end at every moment. An author editing it has
			// to reach the end already drawn, because the claim is the whole of
			// what a reader selects that end to read.
			const next = {
				id: nodeId,
				sessionId,
				side,
				...(def[side].designator !== undefined ? { designator: def[side].designator } : {}),
			};
			if (!loose) {
				if (drawn !== undefined) {
					world.remove(drawn);
					heldEndpoints.delete(nodeId);
					pairTopologyChanged = true;
				}
			} else if (drawn === undefined) {
				heldEndpoints.set(
					nodeId,
					world.add({ endpoint: next, position: { x: 0, y: 0 } }),
				);
				pairTopologyChanged = true;
			} else if (!sameFields(drawn.endpoint, next)) {
				drawn.endpoint = next;
			}
		}
		if (alive) {
			const state: SessionState = sessionStateAt(doc, sessionId, t);
			const a = place.a.node;
			const b = place.b.node;
			// The codec and the CapTP profile reconcile beside the state. They do
			// not change over a session's life, but the DOCUMENT's account of them
			// does: an author corrects one, and a producer can report a session
			// before the handshake has settled what it negotiated.
			const next = {
				id: sessionId,
				codec: def.codec,
				captpVersion: def.captpVersion,
				state,
			};
			if (!existing) {
				heldSessions.set(
					sessionId,
					world.add({ session: next, endpoints: { a, b } }),
				);
				pairTopologyChanged = true;
			} else {
				if (!sameFields(existing.session, next)) {
					existing.session = next;
				}
				if (existing.endpoints.a !== a || existing.endpoints.b !== b) {
					existing.endpoints = { a, b };
					pairTopologyChanged = true;
				}
			}
		} else if (existing) {
			world.remove(existing);
			heldSessions.delete(sessionId);
			pairTopologyChanged = true;
		}
	}

	// --- Messages (in-flight at t) ---
	const messages = doc.entities?.messages ?? {};
	for (const [messageId, def] of Object.entries(messages)) {
		const eff = messageEffective(doc, messageId);
		const alive = containsTime(eff, t);
		const existing = heldMessages.get(messageId);
		// Every field of a flight is editable while it is in the air: the label
		// it carries, the wire it is on, its direction along that wire, and the
		// moments it departs and lands.
		const next = {
			id: messageId,
			sessionId: def.sessionId,
			from: def.from,
			to: def.to,
			sentT: eff.start,
			arrivalT: eff.end,
			...(def.label !== undefined ? { label: def.label } : {}),
		};
		if (!alive) {
			if (existing) {
				world.remove(existing);
				heldMessages.delete(messageId);
			}
		} else if (!existing) {
			heldMessages.set(
				messageId,
				world.add({ messageInFlight: next, position: { x: 0, y: 0 } }),
			);
		} else if (!sameFields(existing.messageInFlight, next)) {
			existing.messageInFlight = next;
		}
	}
	return pairTopologyChanged;
}

function findMessage(world: GameWorld, id: string) {
	for (const e of world.with("messageInFlight")) {
		if (e.messageInFlight.id === id) return e;
	}
	return undefined;
}
