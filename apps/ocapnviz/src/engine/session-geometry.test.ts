import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import { createWorld } from "./world.ts";
import type { TimelineEvent } from "./timeline.ts";
import {
	bezierAt,
	bezierTangent,
	bundleOffset,
	claimTargets,
	computeMessageTimeBundles,
	computeSessionBundles,
	MAX_TEMPORAL_ARC,
	SESSION_BUNDLE_SPACING,
	sessionCurve,
	temporalArcAmount,
} from "./session-geometry.ts";

/** Which peer each claiming end names is the DOCUMENT's answer
 * (`engine/claims.ts`), handed to the geometry rather than re-derived from the
 * world. These worlds are built by hand, so the resolution is stated the same
 * way: nothing claims anybody unless the test says so. */
const NO_CLAIMS: ReadonlyMap<string, string> = new Map();

// Helper: build a `message-sent` event (the only kind these
// time-bundle tests care about). Default arrivalT is 1000ms
// after sentT.
function msg(
	messageId: string,
	sessionId: string,
	sentT: number,
	arrivalT = sentT + 1000,
): TimelineEvent {
	return {
		id: `auth-${messageId}`,
		t: sentT,
		kind: "message-sent",
		messageId,
		sessionId,
		from: "a",
		to: "b",
		arrivalT,
	};
}

// Helper: minimal world with peers + sessions for geometry tests.
function makeWorld(
	peers: Array<{ id: string; x: number; y: number }>,
	sessions: Array<{ id: string; a: string; b: string }>,
) {
	const world = createWorld();
	for (const p of peers) {
		world.add({
			peer: {
				id: p.id,
				label: p.id,
				profile: "glowcap",
			},
			position: { x: p.x, y: p.y },
		});
	}
	for (const s of sessions) {
		world.add({
			session: {
				id: s.id,
				codec: "capnp",
				captpVersion: "v1_0",
				state: "open",
			},
			endpoints: { a: s.a, b: s.b },
		});
	}
	return world;
}

Deno.test("bundleOffset: singleton bundle is always centered", () => {
	assertEquals(bundleOffset(0, 1), 0);
});

Deno.test("bundleOffset: pair splays symmetrically", () => {
	const s = SESSION_BUNDLE_SPACING;
	assertEquals(bundleOffset(0, 2), -s / 2);
	assertEquals(bundleOffset(1, 2), s / 2);
});

Deno.test("bundleOffset: triple has a centered middle", () => {
	const s = SESSION_BUNDLE_SPACING;
	assertEquals(bundleOffset(0, 3), -s);
	assertEquals(bundleOffset(1, 3), 0);
	assertEquals(bundleOffset(2, 3), s);
});

Deno.test("computeSessionBundles: stable index per session", () => {
	const world = makeWorld(
		[{ id: "a", x: 0, y: 0 }, { id: "b", x: 100, y: 0 }],
		[
			{ id: "s-z", a: "a", b: "b" },
			{ id: "s-a", a: "a", b: "b" },
			{ id: "s-m", a: "a", b: "b" },
		],
	);
	const bundles = computeSessionBundles(world, NO_CLAIMS);
	// Stable string-sort: s-a, s-m, s-z → indices 0, 1, 2.
	assertEquals(bundles.get("s-a")?.index, 0);
	assertEquals(bundles.get("s-m")?.index, 1);
	assertEquals(bundles.get("s-z")?.index, 2);
	assertEquals(bundles.get("s-a")?.size, 3);
});

Deno.test("computeSessionBundles: pair key is endpoint-order-insensitive", () => {
	const world = makeWorld(
		[{ id: "a", x: 0, y: 0 }, { id: "b", x: 100, y: 0 }],
		[
			{ id: "s-1", a: "a", b: "b" },
			// Endpoints reversed — must land in the same bundle.
			{ id: "s-2", a: "b", b: "a" },
		],
	);
	const bundles = computeSessionBundles(world, NO_CLAIMS);
	assertEquals(bundles.get("s-1")?.size, 2);
	assertEquals(bundles.get("s-2")?.size, 2);
});

Deno.test("computeSessionBundles: different pairs are independent bundles", () => {
	const world = makeWorld(
		[
			{ id: "a", x: 0, y: 0 },
			{ id: "b", x: 100, y: 0 },
			{ id: "c", x: 0, y: 100 },
		],
		[
			{ id: "s-ab", a: "a", b: "b" },
			{ id: "s-ac", a: "a", b: "c" },
		],
	);
	const bundles = computeSessionBundles(world, NO_CLAIMS);
	assertEquals(bundles.get("s-ab")?.size, 1);
	assertEquals(bundles.get("s-ac")?.size, 1);
});

Deno.test("sessionCurve: singleton renders as straight chord (control at midpoint)", () => {
	const world = makeWorld(
		[{ id: "a", x: 0, y: 0 }, { id: "b", x: 100, y: 0 }],
		[{ id: "s", a: "a", b: "b" }],
	);
	const bundles = computeSessionBundles(world, NO_CLAIMS);
	const curve = sessionCurve(world, "a", "b", bundles.get("s")!);
	assertEquals(curve?.cx, 50);
	assertEquals(curve?.cy, 0);
});

Deno.test("sessionCurve: pair offsets symmetrically perpendicular", () => {
	const world = makeWorld(
		[{ id: "a", x: 0, y: 0 }, { id: "b", x: 100, y: 0 }],
		[{ id: "s-1", a: "a", b: "b" }, { id: "s-2", a: "a", b: "b" }],
	);
	const bundles = computeSessionBundles(world, NO_CLAIMS);
	const c1 = sessionCurve(world, "a", "b", bundles.get("s-1")!)!;
	const c2 = sessionCurve(world, "a", "b", bundles.get("s-2")!)!;
	// Both control points sit on x=50; their y values are opposite-signed.
	assertEquals(c1.cx, 50);
	assertEquals(c2.cx, 50);
	assertAlmostEquals(c1.cy + c2.cy, 0, 1e-9);
});

Deno.test("sessionCurve: perpendicular direction is endpoint-order-independent", () => {
	// Same pair, two sessions, but one event lists them reversed.
	// The bundle index is shared (stable sort by session id), so
	// both curves should land on the SAME perpendicular side.
	const w1 = makeWorld(
		[{ id: "a", x: 0, y: 0 }, { id: "b", x: 100, y: 0 }],
		[{ id: "s-1", a: "a", b: "b" }, { id: "s-2", a: "a", b: "b" }],
	);
	const w2 = makeWorld(
		[{ id: "a", x: 0, y: 0 }, { id: "b", x: 100, y: 0 }],
		[{ id: "s-1", a: "b", b: "a" }, { id: "s-2", a: "b", b: "a" }],
	);
	const b1 = computeSessionBundles(w1, NO_CLAIMS);
	const b2 = computeSessionBundles(w2, NO_CLAIMS);
	const c1 = sessionCurve(w1, "a", "b", b1.get("s-1")!)!;
	const c2 = sessionCurve(w2, "b", "a", b2.get("s-1")!)!;
	// Same canonical direction = same control y for the same index.
	assertEquals(c1.cy, c2.cy);
});

Deno.test("bezierAt: endpoints recover at t=0 and t=1", () => {
	const curve = { ax: 0, ay: 0, bx: 100, by: 0, cx: 50, cy: 30 };
	const p0 = bezierAt(curve, 0);
	const p1 = bezierAt(curve, 1);
	assertEquals(p0, { x: 0, y: 0 });
	assertEquals(p1, { x: 100, y: 0 });
});

Deno.test("bezierAt: apex at t=0.5 sits halfway to the control point", () => {
	// For a quadratic, B(0.5) = 0.5 M + 0.5 C where M is the
	// chord midpoint. So apex y = (0 + 30) / 2 = 15.
	const curve = { ax: 0, ay: 0, bx: 100, by: 0, cx: 50, cy: 30 };
	const apex = bezierAt(curve, 0.5);
	assertEquals(apex.x, 50);
	assertEquals(apex.y, 15);
});

Deno.test("bezierTangent: degenerate curve returns zero tangent", () => {
	const curve = { ax: 0, ay: 0, bx: 0, by: 0, cx: 0, cy: 0 };
	const t = bezierTangent(curve, 0.5);
	assertEquals(t, { dx: 0, dy: 0 });
});

Deno.test("bezierTangent: at apex of symmetric curve, tangent is along chord", () => {
	const curve = { ax: 0, ay: 0, bx: 100, by: 0, cx: 50, cy: 30 };
	const t = bezierTangent(curve, 0.5);
	assertAlmostEquals(t.dx, 1, 1e-9);
	assertAlmostEquals(t.dy, 0, 1e-9);
});

// ───────────── temporal-arc bundles (per-message animation) ─────────────

Deno.test("temporalArcAmount: singleton bundle has no arc", () => {
	assertEquals(temporalArcAmount(0, 1), 0);
});

Deno.test("temporalArcAmount: pair splays to ±MAX", () => {
	assertEquals(temporalArcAmount(0, 2), -MAX_TEMPORAL_ARC);
	assertEquals(temporalArcAmount(1, 2), MAX_TEMPORAL_ARC);
});

Deno.test("temporalArcAmount: triple has middle at zero", () => {
	assertEquals(temporalArcAmount(0, 3), -MAX_TEMPORAL_ARC);
	assertEquals(temporalArcAmount(1, 3), 0);
	assertEquals(temporalArcAmount(2, 3), MAX_TEMPORAL_ARC);
});

Deno.test("temporalArcAmount: adaptive — 10-member bundle still fills [-MAX, +MAX]", () => {
	assertAlmostEquals(temporalArcAmount(0, 10), -MAX_TEMPORAL_ARC, 1e-9);
	assertAlmostEquals(temporalArcAmount(9, 10), MAX_TEMPORAL_ARC, 1e-9);
});

Deno.test("computeMessageTimeBundles: singleton message", () => {
	const bundles = computeMessageTimeBundles([
		msg("m-1", "s-1", 0, 500),
	]);
	assertEquals(bundles.get("m-1"), { index: 0, size: 1 });
});

Deno.test("computeMessageTimeBundles: two truly-simultaneous messages bundle together", () => {
	// Same sessionId, sentT, arrivalT → arcs apply.
	const bundles = computeMessageTimeBundles([
		msg("m-a", "s-1", 0, 1000),
		msg("m-b", "s-1", 0, 1000),
	]);
	assertEquals(bundles.get("m-a")?.size, 2);
	assertEquals(bundles.get("m-b")?.size, 2);
});

Deno.test("computeMessageTimeBundles: time-overlap WITHOUT exact match → singletons", () => {
	// m-a: [0, 1000], m-b: [500, 1500] overlap, but the natural
	// sentT stagger already separates them. No arc.
	const bundles = computeMessageTimeBundles([
		msg("m-a", "s-1", 0, 1000),
		msg("m-b", "s-1", 500, 1500),
	]);
	assertEquals(bundles.get("m-a"), { index: 0, size: 1 });
	assertEquals(bundles.get("m-b"), { index: 0, size: 1 });
});

Deno.test("computeMessageTimeBundles: same sentT but different arrivalT → singletons", () => {
	// Same departure, different flight time → already differentiated.
	const bundles = computeMessageTimeBundles([
		msg("m-a", "s-1", 0, 1000),
		msg("m-b", "s-1", 0, 2000),
	]);
	assertEquals(bundles.get("m-a"), { index: 0, size: 1 });
	assertEquals(bundles.get("m-b"), { index: 0, size: 1 });
});

Deno.test("computeMessageTimeBundles: same arrivalT but different sentT → singletons", () => {
	// Different departure → already differentiated.
	const bundles = computeMessageTimeBundles([
		msg("m-a", "s-1", 0, 1000),
		msg("m-b", "s-1", 500, 1000),
	]);
	assertEquals(bundles.get("m-a"), { index: 0, size: 1 });
	assertEquals(bundles.get("m-b"), { index: 0, size: 1 });
});

Deno.test("computeMessageTimeBundles: opposite-direction messages stay singletons", () => {
	// Same session, same timing, but opposite directions: mirror
	// arcs would land them at the same curve parameter, so they're
	// intentionally NOT bundled.
	const fwd: TimelineEvent = {
		id: "auth-m-fwd",
		t: 0,
		kind: "message-sent",
		messageId: "m-fwd",
		sessionId: "s-1",
		from: "a",
		to: "b",
		arrivalT: 1000,
	};
	const bwd: TimelineEvent = {
		id: "auth-m-bwd",
		t: 0,
		kind: "message-sent",
		messageId: "m-bwd",
		sessionId: "s-1",
		from: "b",
		to: "a",
		arrivalT: 1000,
	};
	const bundles = computeMessageTimeBundles([fwd, bwd]);
	assertEquals(bundles.get("m-fwd"), { index: 0, size: 1 });
	assertEquals(bundles.get("m-bwd"), { index: 0, size: 1 });
});

Deno.test("computeMessageTimeBundles: messages on different sessions stay independent", () => {
	const bundles = computeMessageTimeBundles([
		msg("m-a", "s-1", 0, 1000),
		msg("m-b", "s-2", 0, 1000),
	]);
	assertEquals(bundles.get("m-a"), { index: 0, size: 1 });
	assertEquals(bundles.get("m-b"), { index: 0, size: 1 });
});

Deno.test("computeMessageTimeBundles: index within bundle is stable by id sort", () => {
	// Three truly-simultaneous messages on same session.
	const bundles = computeMessageTimeBundles([
		msg("m-z", "s-1", 0, 1000),
		msg("m-a", "s-1", 0, 1000),
		msg("m-m", "s-1", 0, 1000),
	]);
	assertEquals(bundles.get("m-a")?.index, 0);
	assertEquals(bundles.get("m-m")?.index, 1);
	assertEquals(bundles.get("m-z")?.index, 2);
});

Deno.test("computeMessageTimeBundles: ignores non-message events", () => {
	const bundles = computeMessageTimeBundles([
		{
			id: "auth-peer-1",
			t: 0,
			kind: "peer-joined",
			peerId: "p-1",
			profile: "glowcap",
		},
		msg("m-a", "s-1", 0, 1000),
	]);
	assertEquals(bundles.size, 1);
	assertEquals(bundles.get("m-a")?.size, 1);
});

Deno.test("a claim shares the fan of the peer it names", () => {
	// The layout sits a claim on the very line a real edge to that peer runs
	// along, so the two occupy one corridor and collide. Bundling them puts
	// each in its own lane. It asserts nothing about who is on the end: the
	// bundle is geometry, and the claim is still drawn short, dashed, and at
	// half a peer's width.
	const world = createWorld();
	for (
		const [id, designator] of [
			["alice", "10.0.0.1"],
			["carol", "10.0.0.2"],
		] as const
	) {
		world.add({
			peer: { id, label: id, profile: "glowcap", designator },
			position: { x: 0, y: 0 },
		});
	}
	// A real session carol↔alice, and a second whose far end only CLAIMS alice.
	world.add({
		session: {
			id: "s-real",
			codec: "capnp",
			captpVersion: "v1_0",
			state: "open",
		},
		endpoints: { a: "carol", b: "alice" },
	});
	world.add({
		session: {
			id: "s-claim",
			codec: "capnp",
			captpVersion: "v1_0",
			state: "open",
		},
		endpoints: { a: "carol", b: "s-claim::b" },
	});
	world.add({
		endpoint: {
			id: "s-claim::b",
			sessionId: "s-claim",
			side: "b",
			designator: "10.0.0.1",
		},
		position: { x: 0, y: 0 },
	});

	const claimed = new Map([["s-claim::b", "alice"]]);
	const bundles = computeSessionBundles(
		world,
		claimTargets(world, claimed),
	);
	assertEquals(
		bundles.get("s-real")?.size,
		2,
		"the claim did not join the fan",
	);
	assertEquals(bundles.get("s-claim")?.size, 2);
	assert(
		bundles.get("s-real")!.index !== bundles.get("s-claim")!.index,
		"two edges in one corridor took the same lane",
	);
});

Deno.test("a claim nobody answers to keeps a fan of its own", () => {
	// An end naming nothing on stage stands where it stands, so it shares a
	// corridor with no one and must not be folded into somebody else's fan.
	const world = createWorld();
	world.add({
		peer: {
			id: "carol",
			label: "carol",
			profile: "glowcap",
			designator: "10.0.0.2",
		},
		position: { x: 0, y: 0 },
	});
	world.add({
		session: {
			id: "s1",
			codec: "capnp",
			captpVersion: "v1_0",
			state: "open",
		},
		endpoints: { a: "carol", b: "s1::b" },
	});
	world.add({
		session: {
			id: "s2",
			codec: "capnp",
			captpVersion: "v1_0",
			state: "open",
		},
		endpoints: { a: "carol", b: "s2::b" },
	});
	for (const id of ["s1", "s2"]) {
		world.add({
			endpoint: { id: `${id}::b`, sessionId: id, side: "b" },
			position: { x: 0, y: 0 },
		});
	}
	assertEquals(computeSessionBundles(world, NO_CLAIMS).get("s1")?.size, 1);
	assertEquals(computeSessionBundles(world, NO_CLAIMS).get("s2")?.size, 1);
});
