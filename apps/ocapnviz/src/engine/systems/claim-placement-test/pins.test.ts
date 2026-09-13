/**
 * A pin says where the claim's dot goes. It does not say what the
 * session is solved against, and the drawn edge still ends at the
 * claim.
 */

import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import type { TimelineEvent } from "../../timeline.ts";
import { createWorld, findNode } from "../../world.ts";
import { materializeWorldAt } from "../world-materializer.ts";
import { CLAIM_LEAN } from "../claim-placement.ts";
import { KeyframeLayoutSystem } from "../keyframe-layout-system.ts";
import { claimedPeerByEnd } from "../../claims.ts";
import {
	bezierAt,
	claimTargets,
	computeSessionBundles,
	curveBetween,
	drawnSessionCurve,
} from "../../session-geometry.ts";
import { ALICE_DESIGNATOR, docOf, joined, layoutTest, opened, placed } from "./harness.ts";

layoutTest("pinning a claim moves the claim and nothing else", () => {
	// The pin says where the dot goes. It does not say what the session is
	// solved against, and letting it say both would mean a nudge of a claim
	// pulled the whole picture: the session's link would come off Alice and
	// back onto the claim, and Alice would drift away from Carol with nothing
	// holding her. So the peers are bit-identical either way.
	const events = [
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s", { designator: ALICE_DESIGNATOR }),
	];
	const free = placed(docOf(events));
	const pinnedDoc = docOf(events);
	const session = pinnedDoc.entities?.sessions?.["s"];
	assert(session !== undefined);
	session.endpointPosition = { b: { x: 40, y: 70 } };
	const pinned = placed(pinnedDoc);
	assertEquals({ ...pinned.get("s::b") }, { x: 40, y: 70 });
	for (const peerId of ["alice", "carol"]) {
		const a = free.get(peerId);
		const b = pinned.get(peerId);
		assert(a !== undefined && b !== undefined);
		assertEquals(
			{ x: b.x, y: b.y },
			{ x: a.x, y: a.y },
			`${peerId} moved because a claim was pinned`,
		);
	}
});

layoutTest("the claim sits on the arc its own edge is drawn along", () => {
	// The regression pair put the claim on a visibly separate arc: the claim
	// bulged because the edge was built between the far end and the CLAIM's
	// position, which is a different chord and so a different arc. Both are
	// built from one curve now — the one a full session to the claimed peer
	// would take — so the drawn line ends exactly where the claim stands.
	const doc = docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		// Two sessions on the pair, so the fan is real and the lane is bowed.
		opened("s1", { peer: "alice" }),
		opened("s2", { designator: ALICE_DESIGNATOR }),
	]);
	const world = createWorld();
	materializeWorldAt(world, doc, 50);
	new KeyframeLayoutSystem(doc).update(world, 50);

	const towards = claimTargets(world, claimedPeerByEnd(doc));
	const bundles = computeSessionBundles(world, towards);
	const bundle = bundles.get("s2");
	assert(bundle !== undefined && bundle.size === 2, "the fan did not form");
	const curve = drawnSessionCurve(
		world,
		"carol",
		"s2::b",
		bundle,
		towards,
		CLAIM_LEAN,
	);
	assert(curve !== null, "the claimed edge had no curve");
	const claim = findNode(world, "s2::b")?.position;
	assert(claim !== undefined, "the claim was not placed");
	// The drawn arc stops AT the claim, rather than beside it.
	assertAlmostEquals(curve.bx, claim.x, 1e-9);
	assertAlmostEquals(curve.by, claim.y, 1e-9);

	// And every point of it lies on the lane a full session to alice would
	// take. This is the whole claim, and the endpoint alone does not make it:
	// an arc built between carol and the claim's own position also ends there,
	// while bulging along a different chord the whole way.
	const alice = findNode(world, "alice")?.position;
	const carol = findNode(world, "carol")?.position;
	assert(alice !== undefined && carol !== undefined);
	const lane = curveBetween("carol", carol, "alice", alice, bundle);
	for (const t of [0.25, 0.5, 0.75, 1]) {
		const drawn = bezierAt(curve, t);
		const onLane = bezierAt(lane, t * CLAIM_LEAN);
		assertAlmostEquals(
			drawn.x,
			onLane.x,
			1e-9,
			`x at t=${t} left the lane`,
		);
		assertAlmostEquals(
			drawn.y,
			onLane.y,
			1e-9,
			`y at t=${t} left the lane`,
		);
	}
});

layoutTest(
	"a closed session keeps its lane, so the claim beside it keeps its arc",
	() => {
		// One fact, two authorities, and they disagreed the moment a session
		// closed. The world draws a session for as long as its effective range
		// holds — a closed one is drawn faded, not removed — while the layout used
		// to drop it from the era the moment a `session-closed` observation went
		// by. The pair's bundle then had two lanes on screen and one in the solve,
		// so the claim was placed on the straight lane of a one-lane bundle and the
		// arc drawn to it bowed along a different chord.
		const doc = docOf([
			joined("carol"),
			joined("alice", ALICE_DESIGNATOR),
			opened("s1", { peer: "alice" }),
			opened("s2", { designator: ALICE_DESIGNATOR }),
			{
				id: "close-s1",
				t: 40,
				kind: "session-closed",
				sessionId: "s1",
			} as TimelineEvent,
		]);

		// After the close, and after the transition window has settled.
		const t = 900;
		const world = createWorld();
		materializeWorldAt(world, doc, t);
		new KeyframeLayoutSystem(doc).update(world, t);

		const bundle = computeSessionBundles(
			world,
			claimTargets(world, claimedPeerByEnd(doc)),
		).get("s2");
		assert(bundle !== undefined, "s2 left the world");
		assertEquals(
			bundle.size,
			2,
			"the closed session left the world, so this test no longer measures anything",
		);

		const curve = drawnSessionCurve(
			world,
			"carol",
			"s2::b",
			bundle,
			claimTargets(world, claimedPeerByEnd(doc)),
			CLAIM_LEAN,
		);
		assert(curve !== null, "the claimed edge had no curve");
		const alice = findNode(world, "alice")?.position;
		const carol = findNode(world, "carol")?.position;
		assert(alice !== undefined && carol !== undefined);
		// Every point of the drawn arc still lies on the lane a full session to
		// alice would take. The endpoint alone proves nothing here: when the two
		// disagree the renderer falls back to an ordinary edge, which also reaches
		// the claim, while bowing along a chord of its own the whole way.
		const lane = curveBetween("carol", carol, "alice", alice, bundle);
		for (const at of [0.25, 0.5, 0.75, 1]) {
			const drawn = bezierAt(curve, at);
			const onLane = bezierAt(lane, at * CLAIM_LEAN);
			assertAlmostEquals(
				drawn.x,
				onLane.x,
				1e-9,
				`x at t=${at} left the lane`,
			);
			assertAlmostEquals(
				drawn.y,
				onLane.y,
				1e-9,
				`y at t=${at} left the lane`,
			);
		}
	},
);

layoutTest("a pinned claim keeps its edge, and the lane lets go", () => {
	// Dragging a claim pins it, and the layout hands a pinned claim its pin
	// rather than the lean — so the lane it was riding no longer passes
	// through it. The edge stops being that lane's prefix and becomes an
	// ordinary edge to where the author put it, because the one thing that
	// must stay true is that the line reaches the node.
	const doc = docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s1", { peer: "alice" }),
		opened("s2", { designator: ALICE_DESIGNATOR }),
	]);
	const sessions = doc.entities?.sessions;
	assert(sessions !== undefined);
	sessions["s2"]!.endpointPosition = { b: { x: -900, y: 640 } };

	const world = createWorld();
	materializeWorldAt(world, doc, 50);
	new KeyframeLayoutSystem(doc).update(world, 50);

	const claim = findNode(world, "s2::b")?.position;
	assert(claim !== undefined);
	assertAlmostEquals(claim.x, -900, 1e-6, "the pin was not honored");
	assertAlmostEquals(claim.y, 640, 1e-6, "the pin was not honored");

	const bundle = computeSessionBundles(
		world,
		claimTargets(world, claimedPeerByEnd(doc)),
	).get("s2");
	assert(bundle !== undefined);
	const curve = drawnSessionCurve(
		world,
		"carol",
		"s2::b",
		bundle,
		claimTargets(world, claimedPeerByEnd(doc)),
		CLAIM_LEAN,
	);
	assert(curve !== null, "the pinned claim's edge vanished");
	assertAlmostEquals(curve.bx, claim.x, 1e-9, "the edge missed the claim");
	assertAlmostEquals(curve.by, claim.y, 1e-9, "the edge missed the claim");
});
