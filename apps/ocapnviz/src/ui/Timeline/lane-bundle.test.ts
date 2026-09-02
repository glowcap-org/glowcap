/**
 * Lane bundle — the paint side of the timeline. These tests cover
 * the moment glyphs a peer's row carries, because a rename that
 * lands in the document but never on the row is a change the user
 * cannot see or reach.
 */

import { assert, assertEquals } from "@std/assert";
import { buildLaneBundle, laneBundleColorsFromTheme, laneRowLabel } from "./lane-bundle.ts";
import type { TimelineDocument, TimelineEvent } from "../../engine/timeline.ts";
import { projectFromObservations } from "../../engine/temporal/project-from-observations.ts";
import { attachedEndpoint, sessionEndpoint } from "../../schema/session-end.ts";

const COLORS = laneBundleColorsFromTheme("dark");

function docFor(events: readonly TimelineEvent[]): TimelineDocument {
	return projectFromObservations({
		id: "lane-bundle-test",
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

/** A fresh theme key per call, so the bundle cache never answers a
 *  later case with an earlier case's bundle. */
let themeSeq = 0;
function bundleFor(events: readonly TimelineEvent[]) {
	const doc = docFor(events);
	return buildLaneBundle(doc, events, 1000, COLORS, `test-${++themeSeq}`);
}

const joined: TimelineEvent = {
	id: "p1",
	kind: "peer-joined",
	t: 100,
	peerId: "127.0.0.1:0",
	profile: "glowcap",
	label: "127.0.0.1:0",
};

Deno.test("a rename puts a diamond on the peer's row", () => {
	const bundle = bundleFor([
		joined,
		{
			id: "p2",
			kind: "peer-updated",
			t: 400,
			peerId: "127.0.0.1:0",
			label: "carol",
		},
	]);
	assertEquals(bundle.peers.glyphs.length, 1);
	const glyph = bundle.peers.glyphs[0]!;
	assertEquals(glyph.t, 400);
	assertEquals(glyph.shape, "diamond");
	assertEquals(glyph.eventId, "p2");
	assertEquals(bundle.peers.byEntity.get("127.0.0.1:0")?.glyphs.length, 1);
});

Deno.test("a rename before the peer arrives paints at the peer's start", () => {
	// The same saturating clamp the spans use: the glyph stays inside
	// the pill it belongs to, so it can be seen and clicked.
	const bundle = bundleFor([
		{
			id: "p0",
			kind: "peer-updated",
			t: 10,
			peerId: "127.0.0.1:0",
			label: "carol",
		},
		joined,
	]);
	assertEquals(bundle.peers.glyphs[0]?.t, 100);
});

Deno.test("a rename's diamond contrasts with the pill it sits on", () => {
	// The reported defect: a muted grey diamond vanished into
	// glowcap's amber pill. The tone is chosen against the fill, so
	// the two profiles get opposite tones.
	const rename = (peerId: string): TimelineEvent => ({
		id: `${peerId}-rename`,
		kind: "peer-updated",
		t: 400,
		peerId,
		label: "carol",
	});
	const amber = bundleFor([joined, rename("127.0.0.1:0")]);
	assertEquals(amber.peers.glyphs[0]?.color, "#101828");

	const goblins = bundleFor([
		{
			id: "g1",
			kind: "peer-joined",
			t: 100,
			peerId: "vat-1",
			profile: "goblins",
		},
		rename("vat-1"),
	]);
	assertEquals(goblins.peers.glyphs[0]?.color, "#ffffff");
});

Deno.test("a peer that changes flavor bands its pill at that moment", () => {
	// The same treatment a session's state changes get: the row shows
	// what the peer was known as when, not only what it ended up as.
	const bundle = bundleFor([
		joined,
		{
			id: "p2",
			kind: "peer-updated",
			t: 400,
			peerId: "127.0.0.1:0",
			profile: "goblins",
		},
	]);
	const span = bundle.peers.spans[0]!;
	assertEquals(span.segments?.length, 2);
	assertEquals(span.segments?.[0]?.t0, 100);
	assertEquals(span.segments?.[0]?.t1, 400);
	assertEquals(span.segments?.[1]?.t0, 400);
	// The two bands carry the two profiles' colors, in that order.
	assertEquals(span.segments?.[0]?.color, "#f59e0b");
	assertEquals(span.segments?.[1]?.color, "#8b5cf6");
});

Deno.test("a peer that never changes flavor paints one unbanded pill", () => {
	const bundle = bundleFor([joined]);
	assertEquals(bundle.peers.spans[0]?.segments, undefined);
});

Deno.test("a peer-updated stating nothing paints no glyph", () => {
	const bundle = bundleFor([
		joined,
		{ id: "p2", kind: "peer-updated", t: 400, peerId: "127.0.0.1:0" },
	]);
	assertEquals(bundle.peers.glyphs.length, 0);
});

Deno.test("an end attaching is a diamond on the session's row", () => {
	// The moment has to be reachable, not just recorded: it is where a
	// reader clicks to drag or edit the attribution.
	const bundle = bundleFor([
		{
			id: "p-bob",
			kind: "peer-joined",
			t: 0,
			peerId: "bob",
			profile: "glowcap",
		},
		{
			id: "p-alice",
			kind: "peer-joined",
			t: 0,
			peerId: "alice",
			profile: "glowcap",
		},
		{
			id: "s-open",
			kind: "session-opened",
			t: 100,
			sessionId: "w1",
			a: attachedEndpoint("bob"),
			b: sessionEndpoint({ designator: "alice" }),
			codec: "syrup",
			captpVersion: "v1_0",
		},
		{
			id: "s-learn",
			kind: "session-endpoint-attributed",
			t: 200,
			sessionId: "w1",
			side: "b",
			peerId: "alice",
		},
	]);

	const onSession = bundle.sessions.glyphs.filter((g) => g.eventId === "s-learn");
	assertEquals(onSession.length, 1);
	// Not "end b": the glyph sits on this session's own row, and nothing the
	// viewer draws labels an end "a" or "b" for a reader to match against.
	assertEquals(onSession[0]?.label, "this end is alice");
	// A diamond, not a tick. An end attaching to a peer is a change to the
	// session, the same weight as its state changing, and it is dragged and
	// edited with the same grip. Drawing it lighter would be saying the viewer
	// merely learned something, which is the distinction this model removed.
	assertEquals(onSession[0]?.shape, "diamond");

	// And it reaches the session's own row, not just the flat collapsed view.
	assertEquals(
		bundle.sessions.byEntity.get("w1")?.glyphs.some((g) => g.eventId === "s-learn"),
		true,
	);
});

Deno.test("the feed going quiet stays a tick, not a change to the session", () => {
	// The session-lane glyphs are built by one pass now, and the filter it
	// uses matters: `session-unobserved` is not a moment (`momentOf` answers
	// null for it), so a pass that guarded on `momentOf` would drop this
	// silently. It is painted because the row should show where the feed
	// stopped, and it is a tick because nothing about the session changed.
	const bundle = bundleFor([
		{
			id: "p-bob",
			kind: "peer-joined",
			t: 0,
			peerId: "bob",
			profile: "glowcap",
		},
		{
			id: "s-open",
			kind: "session-opened",
			t: 100,
			sessionId: "w1",
			a: attachedEndpoint("bob"),
			b: sessionEndpoint({}),
			codec: "syrup",
			captpVersion: "v1_0",
		},
		{ id: "s-gone", kind: "session-unobserved", t: 400, sessionId: "w1" },
	]);
	const quiet = bundle.sessions.glyphs.filter((g) => g.eventId === "s-gone");
	assertEquals(quiet.length, 1);
	assertEquals(quiet[0]?.shape, "tick");
	assertEquals(
		bundle.sessions.byEntity.get("w1")?.glyphs.some((g) => g.eventId === "s-gone"),
		true,
	);
});

Deno.test("a lane stack is built once for a document nobody is touching", () => {
	// The whole reason the bundle is cached. Playback repaints every frame,
	// and the document under it is not moving — so the second frame has to get
	// the first frame's stack back rather than rebuild the same one.
	const doc = docFor([joined]);
	const events = [joined];
	const build = () => buildLaneBundle(doc, events, 1000, COLORS, "stable");
	assert(build() === build(), "a still document rebuilt its lane stack");
});

Deno.test("the lane-bundle cache does not grow with the recording", () => {
	// A live capture appends a record at a time, so each one asks for a stack
	// under a key the cache has never seen. Kept forever, that is one whole
	// lane stack retained per record received, for as long as the capture
	// runs. Past the ceiling the oldest goes, and asking for it again is a
	// rebuild — which is what a fresh object here proves.
	const doc = docFor([joined]);
	const events = [joined];
	const first = buildLaneBundle(doc, events, 1000, COLORS, "bounded-0");
	assertEquals(
		buildLaneBundle(doc, events, 1000, COLORS, "bounded-0"),
		first,
		"the newest key should still be cached",
	);
	// Enough distinct keys to push the first one out, whatever the ceiling is
	// set to — a capture makes thousands of these.
	for (let i = 1; i <= 32; i++) {
		buildLaneBundle(doc, events, 1000, COLORS, `bounded-${i}`);
	}
	assert(
		buildLaneBundle(doc, events, 1000, COLORS, "bounded-0") !== first,
		"the cache held every key it was ever asked for",
	);
});

Deno.test("a row is called what its own span is called", () => {
	// The gutter down the left of the timeline and the pill beside it ask
	// one question — what is this called — so the gutter reads the pill's
	// answer instead of deriving a second one. A session pill is named by
	// the pair it joins, and an end with a claim on it and nobody attached
	// is named by that claim, which is what the Inspector and the stage
	// both say about the same end.
	const bundle = bundleFor([
		joined,
		{
			id: "s-open",
			kind: "session-opened",
			t: 100,
			sessionId: "3c".repeat(32),
			a: attachedEndpoint("127.0.0.1:0"),
			b: sessionEndpoint({ designator: "192.168.0.9:5000" }),
			codec: "syrup",
			captpVersion: "v1_0",
		},
	]);
	const sessionId = "3c".repeat(32);
	const span = bundle.sessions.byEntity.get(sessionId)?.spans[0];
	assertEquals(span?.label, "127.0.0.1:0 · 192.168.0.9:5000");
	assertEquals(
		laneRowLabel(bundle.sessions.byEntity.get(sessionId), sessionId),
		span?.label,
	);
	// And a peer's row wears the peer's caption, not the id that names the
	// row in the document.
	assertEquals(
		laneRowLabel(bundle.peers.byEntity.get("127.0.0.1:0"), "127.0.0.1:0"),
		"127.0.0.1:0",
	);
	// An id no row was built for still reads as this app reads any bare
	// identifier: shortened, never whole.
	assertEquals(laneRowLabel(undefined, "3c".repeat(32)), "3c3c3c3c…3c3c3c3c");
});
