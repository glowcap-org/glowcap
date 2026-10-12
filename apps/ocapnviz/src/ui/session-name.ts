/**
 * What to call a session, and what to call one of its ends.
 *
 * A session has no name of its own. Nothing in the document names one, and
 * its id is an OCapN Session ID, sixty-four characters the network chose,
 * so the two ends it joins are its name, and "alice · carol" is what a
 * reader recognizes it by.
 *
 * One home, because three surfaces ask this question and a reader moves
 * between them in one glance: the Inspector's session heading and its
 * pickers, the timeline's session pills, and the row labels down the
 * timeline's gutter. Two of those calling one session two things is the
 * defect this module exists to prevent.
 *
 * It takes a document and a moment rather than an engine, because the
 * moment differs by surface and the rule does not. A panel reads at the
 * playhead, so it asks what the session is called now. A timeline row
 * covers a whole life, so it asks what it ended up called.
 *
 * A leaf above the document: it reads the temporal resolvers and nothing
 * else, no React and no renderer, so any surface may read it.
 */

import type { TimelineDocument } from "../engine/timeline.ts";
import { peerLabelAt, sessionEndpointPlaceAt } from "../engine/temporal/doc-resolver.ts";
import { type SessionSide, UNNAMED_END_LABEL } from "../schema/session-end.ts";
import { elideIdentifier } from "./elide.ts";

/** What one end of a session is called, and which kind of name that is.
 *
 *  `opaque` is true when the text is a string the network chose rather
 *  than one a person did, which is what tells a caller to shorten it in
 *  the middle (see `./identifier.tsx`) instead of clipping its end. */
export type EndName = {
	readonly text: string;
	readonly opaque: boolean;
};

/** What stands between the two ends in a session's one-line name.
 *
 *  A middle dot, and stated here so every surface joins a pair the same
 *  way. It is also the one separator the timeline can draw: the gutter and
 *  the pills are set in Departure Mono, a pixel-grid face that carries `·`
 *  at its own advance and would have to borrow another typeface mid-word
 *  for an arrow. */
export const SESSION_PAIR_SEPARATOR = " · ";

/**
 * What to call one end of a session at `t`.
 *
 * An end with a peer on it is called what that peer is called, which is
 * the name the panels and the stage both use. An end with nobody on it
 * has only the claim it makes, and a claim is a string the network chose.
 * An end that claims nothing says so in words.
 *
 * The peer is read at `t` rather than at the session's birth, so an end
 * that changed hands answers with whoever holds it at that moment.
 *
 * A peer with no name of its own wears its id (`PEER_TRAJECTORY.label`
 * falls back to it), and in a live recording that id is the peer's
 * designator, sixty-four characters of key for a keyed netlayer. So the
 * peer arm reports `opaque` too when the name it found is the id, and a
 * caller that renders one end as its own element shortens it the way it
 * shortens a claim.
 */
export function sessionEndName(
	doc: TimelineDocument,
	sessionId: string,
	side: SessionSide,
	t: number,
): EndName {
	const place = sessionEndpointPlaceAt(doc, sessionId, side, t);
	if (place.peer !== undefined) {
		const label = peerLabelAt(doc, place.peer, t);
		return { text: label, opaque: label === place.peer };
	}
	const claim = doc.entities?.sessions?.[sessionId]?.[side].designator;
	return claim === undefined ? { text: UNNAMED_END_LABEL, opaque: false } : { text: claim, opaque: true };
}

/**
 * What to call a session in one line of text: the pair it joins, at `t`.
 *
 * Every part is shortened, whichever kind of name it turned out to be.
 * This is a phrase that has to fit somewhere, a sentence, an option in a
 * dropdown, a pill on a timeline row, and a sixty-four character word
 * inside one has nowhere to break. `elideIdentifier` leaves anything short
 * alone, so a pair of real names is untouched.
 *
 * A caller that can render each end as its own element should use
 * `sessionEndName` and let `Identifier` do the shortening.
 */
export function sessionPairName(
	doc: TimelineDocument,
	sessionId: string,
	t: number,
): string {
	const read = (side: SessionSide) => elideIdentifier(sessionEndName(doc, sessionId, side, t).text);
	return `${read("a")}${SESSION_PAIR_SEPARATOR}${read("b")}`;
}
