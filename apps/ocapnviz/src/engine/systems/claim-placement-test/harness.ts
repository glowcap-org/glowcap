/**
 * Fixtures for claim-placement: a document of observations, the layout
 * picture it produces, and the distances the lean is judged by.
 *
 * `layoutTest` and `dist` are the keyframe suite's, so a Deno sanitizer
 * workaround and a distance live in one place.
 */

import { createWorld, type GameWorld, type Vec2 } from "../../world.ts";
import { TimelineDocument, type TimelineEvent } from "../../timeline.ts";
import { materializeWorldAt } from "../world-materializer.ts";
import { DEFAULT_LAYOUT_CONFIG, KeyframeLayoutSystem, type LayoutConfig } from "../keyframe-layout-system.ts";
import { LOOSE_END_CLAIMING, NODE_RADIUS } from "../../../render/draw-helpers.ts";
import { dist, layoutTest } from "../keyframe-layout-test/harness.ts";

export { dist, layoutTest };

export const ALICE_DESIGNATOR = "tcp://10.0.0.1:9001";
export const BOB_DESIGNATOR = "tcp://10.0.0.2:9001";

/** How far from a peer a placed claim reads as being *about* that peer;
 *  anything past this is a node the layout placed on its own account. Both
 *  populations are asserted below, so a retune that moved either goes red
 *  rather than quietly passing, and the last test measures the recordings'
 *  own edges against it. */
export const NEAR_PEER = 200;

/** Centre distance at which a claim's body touches a peer's: the sum of the
 *  two half-widths, read off the styles that draw them. Retuning either one
 *  moves this assertion instead of invalidating it. */
export const BODIES_TOUCH = NODE_RADIUS + LOOSE_END_CLAIMING.radius;

/** The daylight `CLAIM_LEAN` is chosen to leave: between the claim's body and
 *  the peer's, about a node's width of empty space. It is what makes the claim
 *  read as short of the peer rather than against it, and it is the reason the
 *  fraction is two thirds. */
export const CLAIM_DAYLIGHT = NODE_RADIUS;

/** The same daylight measured between the two focus RINGS, which stand
 *  further out than the bodies they circle and so have less room to play
 *  with. A claim's own body is the unit here: rings that stay that far apart
 *  read as two rings, and rings closer than that read as one shape. */
export const RING_DAYLIGHT = LOOSE_END_CLAIMING.radius;

/** A document with these observations and nothing else. Parsing derives the
 *  identity entries, so the layout reads the same doc a loaded file gives it. */
export function docOf(events: TimelineEvent[]): TimelineDocument {
	return TimelineDocument.parse({
		id: "claim-placement",
		duration: 1000,
		events,
	});
}

export function joined(peerId: string, designator?: string): TimelineEvent {
	return joinedAt(0, peerId, designator);
}

/** The same join at a stated moment, for the documents whose point is that two
 *  peers were never on the stage at once. */
export function joinedAt(
	t: number,
	peerId: string,
	designator?: string,
): TimelineEvent {
	return {
		id: `join-${peerId}`,
		t,
		kind: "peer-joined",
		peerId,
		profile: "pancake",
		...(designator !== undefined ? { designator } : {}),
	} as TimelineEvent;
}

type End = { peer?: string; designator?: string; attributedBy?: string };

/** One session whose near end is `carol` — a reporting producer's own end is
 *  always attributed — and whose far end is whatever is handed in. */
export function opened(sessionId: string, b: End): TimelineEvent {
	return between(
		sessionId,
		{ peer: "carol", attributedBy: "self-reported" },
		b,
	);
}

/** One session between two ends stated outright, for the cases where both
 *  matter. */
export function between(sessionId: string, a: End, b: End): TimelineEvent {
	return {
		id: `open-${sessionId}`,
		t: 0,
		kind: "session-opened",
		sessionId,
		a,
		b,
		codec: "syrup",
		captpVersion: "v1_0",
	} as TimelineEvent;
}

/** Every node's position after materializing and running the layout — what
 *  the stage would draw, peers and loose ends alike. */
export function placed(
	doc: TimelineDocument,
	config: LayoutConfig = DEFAULT_LAYOUT_CONFIG,
): Map<string, Vec2> {
	const world: GameWorld = createWorld();
	materializeWorldAt(world, doc, 50);
	new KeyframeLayoutSystem(doc, config).update(world, 50);
	const at = new Map<string, Vec2>();
	for (const e of world.with("peer", "position")) {
		at.set(e.peer.id, e.position);
	}
	for (const e of world.with("endpoint", "position")) {
		at.set(e.endpoint.id, e.position);
	}
	return at;
}

/** Where `p` sits on the line through `from` and `toward`: how far along as a
 *  fraction of that segment, and how far off it. A claim on its session's
 *  edge is `{ along: CLAIM_LEAN, off: 0 }`. */
export function onSegment(
	p: Vec2,
	from: Vec2,
	toward: Vec2,
): { along: number; off: number } {
	const dx = toward.x - from.x;
	const dy = toward.y - from.y;
	const len = Math.hypot(dx, dy);
	return {
		along: ((p.x - from.x) * dx + (p.y - from.y) * dy) / (len * len),
		off: Math.abs((p.x - from.x) * dy - (p.y - from.y) * dx) / len,
	};
}
