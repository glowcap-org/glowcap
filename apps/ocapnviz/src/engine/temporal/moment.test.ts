/**
 * Where a single-moment observation may sit.
 *
 * `momentEffective` is the clamp behind two behaviors that must
 * agree: the lane painter draws a diamond at the clamped t, and a
 * drag dispatches the clamped t. When they disagreed — the drag
 * clamping only session state changes — dragging a rename past its
 * peer's arrival asked the engine for a move it refuses, once per
 * pointer move, and the gesture answered with a burst of errors.
 */

import { assertEquals } from "@std/assert";
import { momentEffective } from "./doc-resolver.ts";
import { projectFromObservations } from "./project-from-observations.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { momentOf } from "../event-helpers.ts";
import { attachedEndpoint } from "../../schema/session-end.ts";

function docFor(events: readonly TimelineEvent[]): TimelineDocument {
	return projectFromObservations({
		id: "moment-test",
		duration: 1000,
		recording: {
			sources: [{
				id: "fixture",
				meta: { kind: "fixture" },
				observations: [...events],
			}],
		},
	});
}

/** A peer alive from t=100 to t=900, renamed at t=400. */
const peerEvents: TimelineEvent[] = [
	{
		id: "p1",
		kind: "peer-joined",
		t: 100,
		peerId: "127.0.0.1:0",
		profile: "glowcap",
		label: "127.0.0.1:0",
	},
	{
		id: "p2",
		kind: "peer-updated",
		t: 400,
		peerId: "127.0.0.1:0",
		label: "carol",
	},
	{ id: "p3", kind: "peer-left", t: 900, peerId: "127.0.0.1:0" },
];

Deno.test("a rename dragged before its peer arrives lands at the arrival", () => {
	const doc = docFor(peerEvents);
	assertEquals(momentEffective(doc, "peers", "127.0.0.1:0", 10), 100);
});

Deno.test("a rename dragged past its peer's departure lands at the departure", () => {
	const doc = docFor(peerEvents);
	assertEquals(momentEffective(doc, "peers", "127.0.0.1:0", 5000), 900);
});

Deno.test("a rename inside the peer's life lands where it was dropped", () => {
	const doc = docFor(peerEvents);
	assertEquals(momentEffective(doc, "peers", "127.0.0.1:0", 500), 500);
});

Deno.test("an eternal peer's rename is clamped at the start alone", () => {
	const doc = docFor([peerEvents[0]!, peerEvents[1]!]);
	assertEquals(momentEffective(doc, "peers", "127.0.0.1:0", 10), 100);
	assertEquals(momentEffective(doc, "peers", "127.0.0.1:0", 99_000), 99_000);
});

Deno.test("a session's state change clamps into its session, the same way", () => {
	const doc = docFor([
		{
			id: "s1",
			kind: "session-opened",
			t: 200,
			sessionId: "s1",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			codec: "syrup",
			captpVersion: "v1_0",
		},
		{
			id: "s2",
			kind: "session-state-changed",
			t: 500,
			sessionId: "s1",
			state: "open",
		},
		{ id: "s3", kind: "session-closed", t: 800, sessionId: "s1" },
	]);
	// The session's span is clamped by its peers, which are undeclared
	// here and therefore eternal — so the session's own edges bound it.
	assertEquals(momentEffective(doc, "sessions", "s1", 10), 200);
	assertEquals(momentEffective(doc, "sessions", "s1", 5000), 800);
});

Deno.test("a moment on an undeclared entity passes through unclamped", () => {
	const doc = docFor(peerEvents);
	assertEquals(momentEffective(doc, "peers", "ghost", 10), 10);
});

Deno.test("momentOf names the lane and owner of each moment", () => {
	assertEquals(momentOf(peerEvents[1]!), {
		lane: "peers",
		owner: "127.0.0.1:0",
	});
	assertEquals(
		momentOf({
			id: "s2",
			kind: "session-state-changed",
			t: 500,
			sessionId: "s1",
			state: "open",
		}),
		{ lane: "sessions", owner: "s1" },
	);
	// A join is a span edge, not a moment; a rename with no name
	// renames nothing.
	assertEquals(momentOf(peerEvents[0]!), null);
	assertEquals(
		momentOf({ id: "x", kind: "peer-updated", t: 5, peerId: "p" }),
		null,
	);
});
