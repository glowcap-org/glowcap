/**
 * The placement and the drawing resolve claims the same way.
 *
 * The three answers that have to agree about one end at one moment:
 * whether the layout leaned it, whether the frame draws it as a claim,
 * and how the frame keys its session's lane.
 */

import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import { createWorld, findNode, type Vec2 } from "../../world.ts";
import { TimelineDocument } from "../../timeline.ts";
import { materializeWorldAt } from "../world-materializer.ts";
import { projectFromObservations } from "../../temporal/project-from-observations.ts";
import { Engine } from "../../engine.ts";
import { CLAIM_LEAN } from "../claim-placement.ts";
import { KeyframeLayoutSystem } from "../keyframe-layout-system.ts";
import { claimedPeerByEnd } from "../../claims.ts";
import { claimTargets, computeSessionBundles } from "../../session-geometry.ts";
import {
	ALICE_DESIGNATOR,
	between,
	BODIES_TOUCH,
	dist,
	docOf,
	joined,
	joinedAt,
	layoutTest,
	NEAR_PEER,
	onSegment,
	opened,
} from "./harness.ts";

/** The three answers that have to agree about one end at one moment: whether
 *  the layout leaned it, whether the frame draws it as a claim, and how the
 *  frame keys its session's lane. */
function readingAt(doc: TimelineDocument, t: number) {
	const world = createWorld();
	materializeWorldAt(world, doc, t);
	const system = new KeyframeLayoutSystem(doc);
	system.update(world, t);
	const towards = claimTargets(world, system.claims);
	return {
		at: (id: string): Vec2 | undefined => findNode(world, id)?.position,
		drawnAsClaim: towards,
		bundles: computeSessionBundles(world, towards),
	};
}

layoutTest(
	"a designator two peers answer to in different eras names neither",
	() => {
		// The two never stand on the stage together, so every moment draws exactly
		// one of them and a resolution asked of the moment would name that one.
		// Asked of the document — where the ambiguity is — it names neither, and
		// that is the answer both surfaces need: the layout refuses to lean the
		// claim, so a frame that resolved it anyway would key this session onto
		// Alice's lane and shove the real session on that pair out of its own.
		const doc = projectFromObservations(docOf([
			joined("carol"),
			joined("alice-home", ALICE_DESIGNATOR),
			between(
				"s-real",
				{ peer: "carol", attributedBy: "self-reported" },
				{
					peer: "alice-home",
					attributedBy: "self-reported",
				},
			),
			opened("s-claim", { designator: ALICE_DESIGNATOR }),
			{
				id: "home-leaves",
				t: 400,
				kind: "peer-left",
				peerId: "alice-home",
			},
			joinedAt(600, "alice-laptop", ALICE_DESIGNATOR),
		]));
		assertEquals(
			[...claimedPeerByEnd(doc).keys()],
			[],
			"an ambiguous claim resolved to one of the two peers",
		);

		const early = readingAt(doc, 200);
		assertEquals(
			[...early.drawnAsClaim],
			[],
			"the frame drew as a claim an end the layout would not lean",
		);
		const claim = early.at("s-claim::b");
		const home = early.at("alice-home");
		assert(claim !== undefined && home !== undefined);
		assert(
			dist(claim, home) > NEAR_PEER,
			"the layout leaned an end whose claim names two peers",
		);
		assertEquals(
			early.bundles.get("s-real")?.size,
			1,
			"a real session was nudged off its lane by a claim nobody resolved",
		);
	},
);

layoutTest(
	"a claim naming its own session's far peer is neither leaned nor drawn",
	() => {
		// The degenerate segment, read from both sides. The end claims to be
		// Alice and Alice is already sitting at the other end of this very
		// session, so there is no direction to lean in — and a frame that
		// resolved it anyway would key the pair as Alice-to-Alice, which is not a
		// corridor anything runs along.
		const doc = projectFromObservations(docOf([
			joined("alice", ALICE_DESIGNATOR),
			between("s", { peer: "alice", attributedBy: "self-reported" }, {
				designator: ALICE_DESIGNATOR,
			}),
		]));
		assertEquals([...claimedPeerByEnd(doc).keys()], []);
		const reading = readingAt(doc, 50);
		assertEquals([...reading.drawnAsClaim], []);
		const claim = reading.at("s::b");
		const alice = reading.at("alice");
		assert(claim !== undefined && alice !== undefined);
		assert(
			dist(claim, alice) > BODIES_TOUCH,
			"the end landed on the peer its own session already reaches",
		);
	},
);

layoutTest("naming a peer on the wire makes the end beside it a claim", () => {
	// A peer's durable name is what a claim matches, so writing one turns an
	// ordinary loose end into a claim about that peer — and the placement has
	// to follow in the same edit. Re-seeking alone left the layout answering
	// from the peer's old identity: the end was drawn as a claim, at half a
	// peer's width and with its wire cut short, while still standing where an
	// ordinary body had been solved.
	const engine = new Engine(docOf([
		joined("carol"),
		joined("alice"),
		opened("s", { designator: ALICE_DESIGNATOR }),
	]));
	const before = findNode(engine.world, "s::b")?.position;
	assert(before !== undefined, "the loose end was not drawn");
	const alice = findNode(engine.world, "alice")?.position;
	assert(alice !== undefined);
	assert(
		dist(before, alice) > NEAR_PEER,
		"the end was already a claim before anything named the peer",
	);

	engine.dispatch({
		kind: "update-peer",
		peerId: "alice",
		patch: { designator: ALICE_DESIGNATOR },
	});

	const claim = findNode(engine.world, "s::b")?.position;
	const named = findNode(engine.world, "alice")?.position;
	const carol = findNode(engine.world, "carol")?.position;
	assert(claim !== undefined && named !== undefined && carol !== undefined);
	assertEquals(
		[...engine.claims],
		[["s::b", "alice"]],
		"the edit did not reach the claim resolution",
	);
	assertAlmostEquals(
		onSegment(claim, carol, named).along,
		CLAIM_LEAN,
		1e-9,
		"the end was named a claim but never leaned toward the peer it names",
	);
});
