/**
 * Shared fixtures for the builder-helper tests: one document with a
 * loose end, the Deno sanitizer wrapper d3-force needs, and the pin
 * readers several families assert against.
 */

import { TimelineDocument } from "../../engine/timeline.ts";
import { Engine } from "../../engine/engine.ts";
import { authoredPeerPosition } from "../../engine/event-helpers.ts";

/** Carol holds one end of a session whose far end is a claim nobody has
 *  backed. Alice is on stage and shares no session with either. */
export function looseDoc(): TimelineDocument {
	return TimelineDocument.parse({
		id: "two-click",
		duration: 10000,
		events: [
			{
				id: "p1",
				t: 0,
				kind: "peer-joined",
				peerId: "carol",
				profile: "pancake",
			},
			{
				id: "p2",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "pancake",
			},
			{
				id: "so",
				t: 0,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "carol", attributedBy: "self-reported" },
				b: { designator: "127.0.0.1:9002" },
				codec: "syrup",
				captpVersion: "v1_0",
				initialState: "open",
			},
		],
	});
}

export const LOOSE_END = "s1::b";

export function engineTest(name: string, fn: () => void): void {
	Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

export const PIN_A = { x: 111, y: 222 };
export const PIN_B = { x: 333, y: 444 };

export function peerPin(e: Engine, peerId: string) {
	return authoredPeerPosition(e.doc, peerId);
}

export function endPin(e: Engine) {
	return e.doc.entities?.sessions?.s1?.endpointPosition?.b ?? null;
}
