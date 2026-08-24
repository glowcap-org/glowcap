/**
 * Who stands at a moment, without going through the force solver.
 *
 * `era-reuse.test.ts` proves the same membership through Engine keyframes;
 * these ask the membership functions themselves, so a closed session's loose
 * end failing to leave would fail here even if the anneal happened to hide it.
 */

import { assertEquals } from "@std/assert";
import { attachedEndpoint, endpointStageId, unattributedEndpoint } from "../../schema/session-end.ts";
import { sessionEnds } from "../claims.ts";
import { projectFromObservations } from "../temporal/project-from-observations.ts";
import { TimelineDocument } from "../timeline.ts";
import { linksStandingAt, nodesStandingAt, topologyChanges } from "./stage-topology.ts";

function reconnectDoc(): TimelineDocument {
	return projectFromObservations(TimelineDocument.parse({
		id: "membership",
		duration: 20_000,
		recording: {
			sources: [{
				id: "feed",
				meta: { kind: "fixture" },
				observations: [
					{
						id: "p1",
						t: 0,
						kind: "peer-joined",
						peerId: "rooms",
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
						id: "s0",
						t: 0,
						kind: "session-opened",
						sessionId: "base",
						a: attachedEndpoint("rooms"),
						b: attachedEndpoint("alice"),
						codec: "syrup",
						captpVersion: "v1_0",
						initialState: "open",
					},
					{
						id: "o1",
						t: 1000,
						kind: "session-opened",
						sessionId: "live-s0",
						a: attachedEndpoint("rooms"),
						b: unattributedEndpoint("goblins-carol"),
						codec: "syrup",
						captpVersion: "v1_0",
						initialState: "open",
					},
					{
						id: "c1",
						t: 1100,
						kind: "session-closed",
						sessionId: "live-s0",
					},
				],
			}],
		},
	}));
}

Deno.test("a closed session's loose end is not standing later", () => {
	const doc = reconnectDoc();
	const changes = topologyChanges(doc);
	const allSessions = sessionEnds(doc);
	const loose = endpointStageId("live-s0", "b");

	const during = nodesStandingAt(
		doc,
		changes,
		linksStandingAt(doc, changes, allSessions, 1050),
		1050,
	);
	assertEquals(during.includes(loose), true);
	assertEquals(during.includes("rooms"), true);

	const after = nodesStandingAt(
		doc,
		changes,
		linksStandingAt(doc, changes, allSessions, 2000),
		2000,
	);
	assertEquals(after.includes(loose), false);
	assertEquals(after.includes("rooms"), true);
	assertEquals(after.includes("alice"), true);
});

Deno.test("one moment is one stop in the change stream", () => {
	const doc = reconnectDoc();
	const times = topologyChanges(doc).map((change) => change.t);
	assertEquals(times, [0, 0, 0, 1000, 1100]);
});

Deno.test("a document-declared peer arrives and leaves on its own timing", () => {
	// The other half of the change stream: an entity Build authored, with no
	// observation to announce it. Its declared window is both arrival and
	// departure, or it never reaches an era and lands at the origin.
	const doc = {
		id: "declared",
		duration: 2000,
		entities: {
			peers: {
				authored: {
					profile: "pancake",
					timing: {
						start: { value: 100, explicit: true },
						duration: { value: 400, explicit: true },
					},
				},
			},
		},
	} as unknown as TimelineDocument;
	assertEquals(topologyChanges(doc), [
		{ t: 100, kind: "peer-in", peerId: "authored" },
		{ t: 500, kind: "peer-out", peerId: "authored" },
	]);
});

Deno.test("a session the walk has not reached does not stand at t=0", () => {
	// Unprojected: the session's range starts at implicit zero, so ranges alone
	// would put it on stage before its observation. Reached is the other half.
	const doc = TimelineDocument.parse({
		id: "unreached",
		duration: 20_000,
		recording: {
			sources: [{
				id: "feed",
				meta: { kind: "fixture" },
				observations: [
					{
						id: "p1",
						t: 0,
						kind: "peer-joined",
						peerId: "rooms",
						profile: "pancake",
					},
					{
						id: "s1",
						t: 1000,
						kind: "session-opened",
						sessionId: "later",
						a: attachedEndpoint("rooms"),
						b: unattributedEndpoint("carol"),
						codec: "syrup",
						captpVersion: "v1_0",
						initialState: "open",
					},
				],
			}],
		},
	});
	const changes = topologyChanges(doc);
	const links = linksStandingAt(doc, changes, sessionEnds(doc), 0);
	assertEquals(links.map((link) => link.id), []);
	const later = linksStandingAt(doc, changes, sessionEnds(doc), 1000);
	assertEquals(later.map((link) => link.id), ["later"]);
});
