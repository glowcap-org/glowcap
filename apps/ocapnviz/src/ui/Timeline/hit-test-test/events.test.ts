/**
 * `hitTestEvents` — plot-area picks: spans, edges, glyphs, stacked
 * rows. Geometry and fixtures live in `harness.ts`.
 */

import { assertEquals, assertNotEquals } from "@std/assert";
import { attachedEndpoint } from "../../../schema/session-end.ts";
import { hitTestEvents } from "../event-hit.ts";
import { buildEventHitIndex } from "../event-hit-index.ts";
import { iterateRows } from "../row-layout.ts";
import type { TimelineDocument, TimelineEvent } from "../../../engine/timeline.ts";
import { type LaneKind, type TimelineView } from "../state.ts";
import { docFor, eventIdOf, HEIGHT, LANE_HEIGHT, makePeer, rowsFor, VIEW, WIDTH } from "./harness.ts";

Deno.test("hitTestEvents: a reusable index keeps observations off the hover path", () => {
	const events = makePeer("alice", 0, 1000);
	const doc = docFor(events);
	const index = buildEventHitIndex(doc, events);
	const noScan = new Proxy(events, {
		get(target, property, receiver) {
			if (property === Symbol.iterator || property === "find") {
				throw new Error(
					"hover rescanned observations after the index was built",
				);
			}
			return Reflect.get(target, property, receiver);
		},
	});
	const hit = hitTestEvents(
		152,
		10,
		WIDTH,
		HEIGHT,
		VIEW,
		noScan,
		rowsFor(events),
		doc,
		0,
		index,
	);
	assertEquals(hit?.entity, { kind: "peer", id: "alice" });
	assertEquals(eventIdOf(hit?.drag ?? null), "alice-joined");
});

Deno.test("hitTestEvents: click on peer span returns peer selection + joined event", () => {
	const events = makePeer("alice", 0, 1000);
	// px=152 → t=400; well inside Alice's [0..1000] span. py=10 →
	// peers lane.
	const hit = hitTestEvents(
		152,
		10,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.entity, { kind: "peer", id: "alice" });
	assertEquals(hit!.drag?.kind, "span-body");
	assertEquals(eventIdOf(hit!.drag), "alice-joined");
});

Deno.test("hitTestEvents: click on peer right edge returns peer-left event with rightEdge=true", () => {
	const events = makePeer("alice", 0, 1000);
	// Right edge is at px(1000)=224; click at px=222 (within 6 px).
	const hit = hitTestEvents(
		222,
		10,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.drag?.kind, "span-edge");
	assertEquals(eventIdOf(hit!.drag), "alice-left");
	assertEquals(
		hit!.drag?.kind === "span-edge" ? hit!.drag.edge : null,
		"right",
	);
});

Deno.test("hitTestEvents: peer without peer-left has no right-edge handle", () => {
	// Alice never leaves → no peer-left to retime. A click at the
	// window edge still picks her up but eventId stays at joined.
	const events = makePeer("alice", 0);
	const hit = hitTestEvents(
		222,
		10,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	// No peer-left = no right-edge handle; the click falls through to
	// body translate against the peer-joined event.
	assertEquals(hit!.drag?.kind, "span-body");
	assertEquals(eventIdOf(hit!.drag), "alice-joined");
});

Deno.test("hitTestEvents: authored peer with no observations gets an entity-addressed drag plan", () => {
	// `add-peer` seeds entity.timing but emits no peer-joined
	// observation. The renderer paints the peer via peerEffective(doc);
	// the hit-test MUST agree — and the gesture must be retimeable
	// exactly like a loaded peer's, addressed by entity instead of by
	// an observation event (`move-entity-span` is the write path).
	const doc: TimelineDocument = {
		id: "scrubber-test",
		duration: 1000,
		entities: {
			peers: {
				alice: {
					profile: "pancake",
					label: "alice",
					timing: {
						start: { value: 0, explicit: true },
						duration: { value: 1000, explicit: true },
					},
				},
			},
		},
		recording: {
			sources: [{
				id: "fixture",
				meta: { kind: "fixture" },
				observations: [],
			}],
		},
		rowOrder: {},
		rowHidden: {},
		rowLabelHidden: {},
		rowBodyHidden: {},
	};
	const hit = hitTestEvents(
		152,
		10,
		WIDTH,
		HEIGHT,
		VIEW,
		[],
		rowsFor([{
			kind: "peer-joined",
			id: "alice-joined",
			peerId: "alice",
			profile: "pancake",
			t: 0,
		}]),
		doc,
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.entity, { kind: "peer", id: "alice" });
	assertEquals(hit!.drag, {
		kind: "entity-span-body",
		ref: { kind: "peer", id: "alice" },
		originalT: 0,
	});
});

Deno.test("hitTestEvents: click in gutter returns null", () => {
	const events = makePeer("alice", 0, 1000);
	// px=30 is left of LANE_LABEL_WIDTH=104.
	const hit = hitTestEvents(
		30,
		10,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertEquals(hit, null);
});

Deno.test("hitTestEvents: click in ruler area returns null", () => {
	const events = makePeer("alice", 0, 1000);
	// py=100 → ruler band [96, 118).
	const hit = hitTestEvents(
		152,
		100,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertEquals(hit, null);
});

Deno.test("hitTestEvents: click on collapsed lane returns null", () => {
	// Only the peers lane is expanded → sessions/messages don't
	// contribute a hit zone even though their events exist.
	const view: TimelineView = {
		...VIEW,
		expandedLanes: new Set<LaneKind>(["peers"]),
	};
	const heightCollapsed = 22 + 1 * (LANE_HEIGHT + 2); // 54
	const events: TimelineEvent[] = [
		...makePeer("alice", 0, 1000),
		{
			id: "s1-open",
			kind: "session-opened",
			t: 100,
			sessionId: "s1",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			codec: "capnp",
			captpVersion: "v1_0",
		},
	];
	// py=10 → peers lane (only expanded lane).
	const rowsForView = [...iterateRows(
		view.expandedLanes,
		view.expandedCategories,
		{ peers: ["alice"], sessions: ["s1"], messages: [] },
		undefined,
		LANE_HEIGHT,
	)];
	const hitPeer = hitTestEvents(
		128,
		10,
		WIDTH,
		heightCollapsed,
		view,
		events,
		rowsForView,
		docFor(events),
	);
	assertEquals(hitPeer?.entity.kind, "peer");
});

Deno.test("hitTestEvents: session-state-changed glyph wins over span at same t", () => {
	// Within EDGE_HANDLE_PX (6) of t=500 (px=164) the glyph at
	// t=500 should be picked instead of the underlying session span.
	const events: TimelineEvent[] = [
		{
			id: "s1-open",
			kind: "session-opened",
			t: 0,
			sessionId: "s1",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			codec: "capnp",
			captpVersion: "v1_0",
		},
		{
			id: "s1-state",
			kind: "session-state-changed",
			t: 500,
			sessionId: "s1",
			state: "open",
		},
		{
			id: "s1-close",
			kind: "session-closed",
			t: 1000,
			sessionId: "s1",
		},
	];
	// py=40 → sessions lane.
	const hit = hitTestEvents(
		164,
		40,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.entity, { kind: "session", id: "s1" });
	assertEquals(hit!.drag?.kind, "moment");
	assertEquals(eventIdOf(hit!.drag), "s1-state");
});

Deno.test("hitTestEvents: peer rename glyph wins over the peer's span", () => {
	// A rename is a moment on the peer's row, pickable like a
	// session's state diamond: clicking it grabs the rename, so it
	// can be retimed instead of translating the whole peer.
	const events: TimelineEvent[] = [
		...makePeer("127.0.0.1:0", 0, 1000),
		{
			id: "rename-1",
			kind: "peer-updated",
			t: 500,
			peerId: "127.0.0.1:0",
			label: "carol",
		},
	];
	// px=164 → t=500; py=10 → peers lane.
	const hit = hitTestEvents(
		164,
		10,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.entity, { kind: "peer", id: "127.0.0.1:0" });
	assertEquals(hit!.drag?.kind, "moment");
	assertEquals(eventIdOf(hit!.drag), "rename-1");
});

Deno.test("hitTestEvents: peer edge wins over a rename at the same t", () => {
	// Same priority the session lane holds: edges beat diamonds, so
	// dragging the peer's end never grabs a rename sitting on it.
	const events: TimelineEvent[] = [
		...makePeer("127.0.0.1:0", 0, 1000),
		{
			id: "rename-1",
			kind: "peer-updated",
			t: 1000,
			peerId: "127.0.0.1:0",
			label: "carol",
		},
	];
	// px=222 is within EDGE_HANDLE_PX of both the rename and the
	// peer's right edge at px=224.
	const hit = hitTestEvents(
		222,
		10,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.drag?.kind, "span-edge");
	assertEquals(eventIdOf(hit!.drag), "127.0.0.1:0-left");
});

Deno.test("hitTestEvents: session edge wins over diamond at same t (priority: edges > diamonds > body)", () => {
	// session-closed at t=1000 (px=224) and a state-change diamond
	// also at t=1000. Clicking near the right edge MUST land on the
	// close event so dragging retimes the pill, not the diamond.
	const events: TimelineEvent[] = [
		{
			id: "s1-open",
			kind: "session-opened",
			t: 0,
			sessionId: "s1",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			codec: "capnp",
			captpVersion: "v1_0",
		},
		{
			id: "s1-state-final",
			kind: "session-state-changed",
			t: 1000,
			sessionId: "s1",
			state: "closed",
		},
		{
			id: "s1-close",
			kind: "session-closed",
			t: 1000,
			sessionId: "s1",
		},
	];
	// py=40 → sessions lane; px=222 is within EDGE_HANDLE_PX of both
	// the diamond at px=224 and the close edge at px=224.
	const hit = hitTestEvents(
		222,
		40,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.drag?.kind, "span-edge");
	assertEquals(eventIdOf(hit!.drag), "s1-close");
	assertEquals(
		hit!.drag?.kind === "span-edge" ? hit!.drag.edge : null,
		"right",
	);
});

Deno.test("hitTestEvents: session-opened edge wins over diamond at same t", () => {
	// Mirror of the closed-edge test for the LEFT edge.
	const events: TimelineEvent[] = [
		{
			id: "s1-open",
			kind: "session-opened",
			t: 0,
			sessionId: "s1",
			a: attachedEndpoint("alice"),
			b: attachedEndpoint("bob"),
			codec: "capnp",
			captpVersion: "v1_0",
		},
		{
			id: "s1-state-initial",
			kind: "session-state-changed",
			t: 0,
			sessionId: "s1",
			state: "negotiating",
		},
	];
	// px=106 → t≈16, within EDGE_HANDLE_PX of t=0 (px=104).
	const hit = hitTestEvents(
		106,
		40,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.drag?.kind, "span-edge");
	assertEquals(eventIdOf(hit!.drag), "s1-open");
	assertEquals(
		hit!.drag?.kind === "span-edge" ? hit!.drag.edge : null,
		"left",
	);
});

Deno.test("hitTestEvents: message body click returns message-sent event without rightEdge", () => {
	const events: TimelineEvent[] = [
		{
			id: "m1-sent",
			kind: "message-sent",
			t: 200,
			messageId: "m1",
			sessionId: "s1",
			from: "alice",
			to: "bob",
			arrivalT: 800,
		},
	];
	// px(500) = 164 — middle of [200..800] span; py=70 → messages lane.
	const hit = hitTestEvents(
		164,
		70,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.drag?.kind, "message-body");
	assertEquals(eventIdOf(hit!.drag), "m1-sent");
	assertEquals(
		hit!.drag?.kind === "message-body" ? hit!.drag.start : null,
		200,
	);
	assertEquals(
		hit!.drag?.kind === "message-body" ? hit!.drag.end : null,
		800,
	);
});

Deno.test("hitTestEvents: message right edge returns rightEdge=true for arrivalT drag", () => {
	const events: TimelineEvent[] = [
		{
			id: "m1-sent",
			kind: "message-sent",
			t: 200,
			messageId: "m1",
			sessionId: "s1",
			from: "alice",
			to: "bob",
			arrivalT: 800,
		},
	];
	// px(800) = 104 + 0.8*120 = 200; click at 198 (within 6 px).
	const hit = hitTestEvents(
		198,
		70,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.drag?.kind, "message-edge");
	assertEquals(
		hit!.drag?.kind === "message-edge" ? hit!.drag.edge : null,
		"right",
	);
});

Deno.test("hitTestEvents: expanded peers category — per-entity row narrows the hit", () => {
	// With peers expanded, the row layout is: header at y≈1
	// (h=30), then alice at y≈33, bob at y≈65. Clicking bob's row
	// must pick bob's events specifically, NOT "latest started".
	const events = [
		...makePeer("alice", 0, 1000),
		...makePeer("bob", 300, 900),
	];
	const expandedView: TimelineView = {
		...VIEW,
		expandedCategories: new Set<Exclude<LaneKind, "ruler">>(["peers"]),
	};
	const rows = [...iterateRows(
		expandedView.expandedLanes,
		expandedView.expandedCategories,
		{ peers: ["alice", "bob"], sessions: [], messages: [] },
		undefined,
		LANE_HEIGHT,
	)];
	// y=33..63 → alice row. Picking middle of alice's span at t=500.
	const aliceHit = hitTestEvents(
		164,
		45,
		WIDTH,
		HEIGHT,
		expandedView,
		events,
		rows,
		docFor(events),
	);
	assertNotEquals(aliceHit, null);
	assertEquals(aliceHit!.entity, { kind: "peer", id: "alice" });
	// y=65..95 → bob row. Same t=500 — bob is alive, alice is too,
	// but the row constraint locks the answer to bob.
	const bobHit = hitTestEvents(
		164,
		78,
		WIDTH,
		HEIGHT,
		expandedView,
		events,
		rows,
		docFor(events),
	);
	assertNotEquals(bobHit, null);
	assertEquals(bobHit!.entity, { kind: "peer", id: "bob" });
});

Deno.test("hitTestEvents: stacked peers — latest start wins", () => {
	// Alice (0..1000) and Bob (300..900) both alive at t=500. The
	// paint order puts later-started spans on top, so Bob wins.
	const events = [
		...makePeer("alice", 0, 1000),
		...makePeer("bob", 300, 900),
	];
	const hit = hitTestEvents(
		164,
		10,
		WIDTH,
		HEIGHT,
		VIEW,
		events,
		rowsFor(events),
		docFor(events),
	);
	assertNotEquals(hit, null);
	assertEquals(hit!.entity.id, "bob");
});
