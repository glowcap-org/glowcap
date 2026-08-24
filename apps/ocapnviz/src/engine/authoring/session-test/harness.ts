/**
 * Fixtures for session-authoring tests: a two-peer session, a session
 * with one loose end, and the Deno sanitizer wrapper d3-force needs.
 */

import { assert } from "@std/assert";
import { TimelineDocument } from "../../timeline.ts";
import { Engine } from "../../engine.ts";
import type { TimelineEvent } from "../../timeline.ts";
import { observationsOf } from "../../temporal/recording-access.ts";

export function engineTest(name: string, fn: () => void | Promise<void>): void {
	Deno.test({
		name,
		sanitizeOps: false,
		sanitizeResources: false,
		fn,
	});
}

export function buildDoc(): TimelineDocument {
	return TimelineDocument.parse({
		id: "test-traj",
		duration: 10000,
		events: [
			{
				id: "p1",
				t: 0,
				kind: "peer-joined",
				peerId: "a",
				profile: "pancake",
			},
			{
				id: "p2",
				t: 0,
				kind: "peer-joined",
				peerId: "b",
				profile: "goblins",
			},
			{
				id: "so",
				t: 0,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "a" },
				b: { peer: "b" },
				codec: "syrup",
				captpVersion: "v1_0",
				initialState: "negotiating",
			},
		],
	});
}

/** A session with one end attached and one loose — the shape a live
 *  feed reports before anything has backed the far end's claim, and
 *  the shape these tests attach, detach, and edit. */
export function looseDoc(): TimelineDocument {
	return TimelineDocument.parse({
		id: "test-loose",
		duration: 10000,
		events: [
			{
				id: "p1",
				t: 0,
				kind: "peer-joined",
				peerId: "a",
				profile: "pancake",
			},
			{
				id: "p2",
				t: 0,
				kind: "peer-joined",
				peerId: "b",
				profile: "goblins",
			},
			{
				id: "so",
				t: 0,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "a", attributedBy: "self-reported" },
				b: { designator: "127.0.0.1:9000" },
				codec: "syrup",
				captpVersion: "v1_0",
				initialState: "open",
			},
		],
	});
}

export function sessionOf(e: Engine, id = "s1") {
	const def = e.doc.entities!.sessions![id];
	assert(def !== undefined, `session ${id} is declared`);
	return def;
}

export function observations(e: Engine): readonly TimelineEvent[] {
	return observationsOf(e.doc) as readonly TimelineEvent[];
}
