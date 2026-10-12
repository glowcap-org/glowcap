import { endpointNodeId, endpointStageId, SESSION_SIDES } from "../schema/session-end.ts";
import type { TimelineDocument, TimelineEvent } from "./timeline.ts";
import { observationsOf } from "./temporal/recording-access.ts";

/**
 * What each session end claims, and who it names. The one answer two
 * surfaces read.
 *
 * A session end whose `peer` field is absent is LOOSE: nothing proved who is
 * on it, so it holds a node of its own keyed by `sessionId::side`, its stage
 * id. A loose end whose `designator` names a peer the document declares is a
 * CLAIM about that peer. Throughout ocapnviz "claim" means that end, never the
 * designator string it carries.
 *
 * Whether an end is a claim decides two things that must agree: where the
 * layout puts it (`claim-placement.ts`, which sits it on its session's
 * edge toward the peer it names) and how the renderer draws it
 * (`sprites/endpoint.ts`, which paints a claim at half a peer's width and
 * stops its wire short). A stage that sat an end two thirds of the way to
 * Alice and then drew it at a peer's own weight would be worse than either
 * answer alone, so the question is asked here and nowhere else.
 *
 * This module reads the document and nothing else. It is a leaf: the layout
 * and the geometry both depend on it, and neither depends on the other.
 */

/**
 * Peers indexed by the durable name each answers to. A peer is matched on its
 * designator rather than its id because the id is the viewer's handle for it
 * and the designator is the name the wire uses, and a claim is a wire name.
 *
 * A designator two peers answer to names neither of them in particular, so it
 * indexes to null and no claim resolves to either. An ambiguous claim is
 * exactly the case where drawing the relationship would assert more than is
 * known.
 */
function indexPeersByDesignator(
	peers: Iterable<{ id: string; designator?: string | undefined }>,
): Map<string, string | null> {
	const into = new Map<string, string | null>();
	for (const peer of peers) {
		const name = peer.designator;
		if (name === undefined || name === "") continue;
		const held = into.get(name);
		if (held === undefined) into.set(name, peer.id);
		else if (held !== peer.id) into.set(name, null);
	}
	return into;
}

/** The peer a designator names, or undefined when it names nobody the
 *  document declares, or more than one. */
function claimedPeer(
	designator: string | undefined,
	byDesignator: ReadonlyMap<string, string | null>,
): string | undefined {
	if (designator === undefined) return undefined;
	return byDesignator.get(designator) ?? undefined;
}

/**
 * The peer each claiming end names, stage id → peer id. THE resolution, for
 * every reader.
 *
 * Asked of the document rather than of one moment, so the answer does not
 * change as the playhead moves: whether a claim names a drawn peer changes
 * only when the document does. That makes the ambiguity rule document-wide
 * too, including peers in eras this claim never coexists with, the
 * conservative reading, and the one that refuses to draw a relationship the
 * document does not settle. A designator two peers answer to in eras that
 * never overlap still names neither of them, because the document never says
 * which one the wire reached.
 *
 * Two ends resolve to nobody, and both are here rather than in one caller,
 * because a caller that skipped either would key a session's lane differently
 * from the caller that did not:
 *
 *   - an end whose claim two peers answer to, per `indexPeersByDesignator`;
 *   - an end naming the peer its own session already ends at, or the peer its
 *     other end claims. Such a claim has no direction to lean in and its
 *     session has no pair to bundle with. It is an ordinary loose end. (An end
 *     naming a peer an author spelled like a stage id is the same case.)
 *
 * Whether the named peer is on stage in a given era is a separate question,
 * asked by `claimsOnStage` where the era's node set is known.
 */
export function claimedPeerByEnd(doc: TimelineDocument): Map<string, string> {
	const byDesignator = indexPeersByDesignator(
		Array.from(peerDesignators(doc), ([id, designator]) => ({
			id,
			designator,
		})),
	);
	const named = new Map<string, string>();
	for (const [stageId, claim] of endpointClaims(doc)) {
		const peerId = claimedPeer(claim, byDesignator);
		if (peerId !== undefined && peerId !== stageId) {
			named.set(stageId, peerId);
		}
	}
	if (named.size === 0) return named;
	// A stage id belongs to exactly one session, so one entry per end is enough
	// to find a claim's other end. Every candidate is collected before any is
	// dropped, so the two ends of one session decide together rather than in
	// listed order, and so the lookup is one step deep and never follows a
	// chain: a claim at the far end contributes the peer IT names.
	const otherEnd = new Map<string, string>();
	for (const ends of sessionEnds(doc).values()) {
		if (ends.a === ends.b) continue;
		otherEnd.set(ends.a, ends.b);
		otherEnd.set(ends.b, ends.a);
	}
	const claimed = new Map<string, string>();
	for (const [stageId, peerId] of named) {
		const other = otherEnd.get(stageId);
		if (other === undefined) continue;
		if ((named.get(other) ?? other) === peerId) continue;
		claimed.set(stageId, peerId);
	}
	return claimed;
}

/**
 * The claims a moment can act on: those whose end and whose named peer are
 * both standing in it. Every era asks this, and so does every frame, the
 * layout with the node set it is about to solve, the renderer with the world
 * at the playhead, so the two agree on which ends are claims about somebody
 * present and which are ordinary bodies.
 */
export function claimsOnStage(
	claimed: ReadonlyMap<string, string>,
	present: ReadonlySet<string>,
): Map<string, string> {
	const out = new Map<string, string>();
	for (const [stageId, peerId] of claimed) {
		if (present.has(stageId) && present.has(peerId)) {
			out.set(stageId, peerId);
		}
	}
	return out;
}

/**
 * What each session end claims to be, keyed by the stage id that end
 * occupies. An attributed end is listed too and costs nothing: it holds no
 * stage id in any era's node set, so nothing ever looks its claim up.
 */
export function endpointClaims(doc: TimelineDocument): Map<string, string> {
	const claims = new Map<string, string>();
	for (
		const [sessionId, def] of Object.entries(doc.entities?.sessions ?? {})
	) {
		for (const side of SESSION_SIDES) {
			const claim = def[side].designator;
			if (claim !== undefined) {
				claims.set(endpointStageId(sessionId, side), claim);
			}
		}
	}
	for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
		if (ev.kind !== "session-opened") continue;
		for (const side of SESSION_SIDES) {
			const stageId = endpointStageId(ev.sessionId, side);
			if (claims.has(stageId)) continue; // entities entry won
			const claim = ev[side].designator;
			if (claim !== undefined) claims.set(stageId, claim);
		}
	}
	return claims;
}

/**
 * Both ends of every session the document states, session id → the pair of
 * node ids those ends occupy. The same identity-side-first cascade every
 * other reader here follows: an `entities.sessions` entry is the source of
 * truth, and an observation fills in for a session that has no entry.
 *
 * These are the ends a session was opened with, not `sessionEndpointAt(doc,
 * id, side, t)`: attribution does not re-key the layout. For a claim that is
 * exactly right, because the session was already solved to the peer, so the
 * stale end and the live one give the same picture. For a loose end that was
 * solved standing alone it means the edge snaps to the peer when attribution
 * lands, with no re-solve behind it.
 */
export function sessionEnds(
	doc: TimelineDocument,
): Map<string, { a: string; b: string }> {
	const ends = new Map<string, { a: string; b: string }>();
	for (
		const [sessionId, def] of Object.entries(doc.entities?.sessions ?? {})
	) {
		ends.set(sessionId, {
			a: endpointNodeId(sessionId, "a", def.a),
			b: endpointNodeId(sessionId, "b", def.b),
		});
	}
	for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
		if (ev.kind !== "session-opened") continue;
		if (ends.has(ev.sessionId)) continue; // entities entry won
		ends.set(ev.sessionId, {
			a: endpointNodeId(ev.sessionId, "a", ev.a),
			b: endpointNodeId(ev.sessionId, "b", ev.b),
		});
	}
	return ends;
}

/**
 * The durable name each peer answers to, peer id → designator. Identity side
 * first, the same cascade `authoredPins` follows: a peer's definition is the
 * source of truth, and the join fills in for a peer that has no definition
 * entry. The join is the only observation that states a designator, because a
 * peer only ever arrives under a name somebody stated.
 */
function peerDesignators(doc: TimelineDocument): Map<string, string> {
	const designators = new Map<string, string>();
	for (const [peerId, def] of Object.entries(doc.entities?.peers ?? {})) {
		if (def.designator !== undefined) {
			designators.set(peerId, def.designator);
		}
	}
	for (const ev of observationsOf(doc) as readonly TimelineEvent[]) {
		if (ev.kind !== "peer-joined") continue;
		if (ev.designator === undefined) continue;
		if (designators.has(ev.peerId)) continue; // entities entry won
		designators.set(ev.peerId, ev.designator);
	}
	return designators;
}
