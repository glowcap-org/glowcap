/**
 * How a claim sits on its session's edge: the lean fraction, matching
 * a peer by the name it answers to, standing alone when nobody matches,
 * and fanning when two claims share a pair.
 */

import { assert, assertAlmostEquals, assertEquals } from "@std/assert";
import { CLAIM_LEAN } from "../claim-placement.ts";
import { DEFAULT_LAYOUT_CONFIG } from "../keyframe-layout-system.ts";
import { LOOSE_END_CLAIMING } from "../../../render/draw-helpers.ts";
import {
	ALICE_DESIGNATOR,
	between,
	BOB_DESIGNATOR,
	BODIES_TOUCH,
	dist,
	docOf,
	joined,
	layoutTest,
	NEAR_PEER,
	onSegment,
	opened,
	placed,
} from "./harness.ts";

layoutTest("a claim sits at CLAIM_LEAN along its session's edge", () => {
	// The whole design in one assertion. The session was solved as if its far
	// end were already Alice, so the edge points at Alice; the claim rides that
	// edge and stops a third short of her.
	const at = placed(docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s", { designator: ALICE_DESIGNATOR }),
	]));
	const alice = at.get("alice");
	const carol = at.get("carol");
	const claim = at.get("s::b");
	assert(alice !== undefined && carol !== undefined);
	assert(claim !== undefined, "the loose end was not drawn");
	const on = onSegment(claim, carol, alice);
	assertAlmostEquals(
		on.along,
		CLAIM_LEAN,
		1e-9,
		`claim sat ${on.along} along`,
	);
	assertAlmostEquals(on.off, 0, 1e-9, `claim sat ${on.off} off the edge`);
	// And the reading that fraction buys: near enough to be about Alice, far
	// enough that the two bodies do not touch.
	assert(dist(claim, alice) < NEAR_PEER);
	assert(
		dist(claim, alice) > BODIES_TOUCH,
		"the claim body reached the peer's",
	);
});

layoutTest("a peer is matched on the name it answers to, not its id", () => {
	// The claim is a wire name and the peer id is the viewer's handle, so a
	// claim spelling the id is a claim about a name nobody on the wire uses.
	const at = placed(docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s", { designator: "alice" }),
	]));
	const alice = at.get("alice");
	const loose = at.get("s::b");
	assert(alice !== undefined && loose !== undefined);
	assert(
		dist(loose, alice) > NEAR_PEER,
		"a claim spelling a peer id was placed on that peer",
	);
});

layoutTest("a claim naming nobody the stage draws stands on its own", () => {
	// No destination, so the end is an ordinary
	// body in the solve and takes the solver's own separation, which is a
	// node's width and then some rather than a claim's third of an edge.
	const at = placed(docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s", { designator: "tcp://198.51.100.7:9001" }),
	]));
	const alice = at.get("alice");
	const carol = at.get("carol");
	const loose = at.get("s::b");
	assert(alice !== undefined && carol !== undefined);
	assert(loose !== undefined, "the loose end was not drawn");
	const nearest = Math.min(dist(loose, alice), dist(loose, carol));
	assert(
		nearest > NEAR_PEER,
		`a stranger's claim landed ${nearest} from a peer, close enough to read as being about it`,
	);
});

layoutTest("an end with no claim at all stands on its own", () => {
	const at = placed(docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s", {}),
	]));
	const alice = at.get("alice");
	const loose = at.get("s::b");
	assert(alice !== undefined);
	assert(loose !== undefined, "the loose end was not drawn");
	assert(
		dist(loose, alice) > NEAR_PEER,
		"an end claiming nothing was placed on a peer",
	);
});

layoutTest("a claim two peers answer to is placed on neither", () => {
	// A designator two peers hold names neither of them in particular, and
	// putting the claim on whichever was indexed first would assert a
	// relationship the document does not support.
	const at = placed(docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		joined("alias", ALICE_DESIGNATOR),
		opened("s", { designator: ALICE_DESIGNATOR }),
	]));
	const alice = at.get("alice");
	const alias = at.get("alias");
	const loose = at.get("s::b");
	assert(alice !== undefined && alias !== undefined);
	assert(loose !== undefined, "the loose end was not drawn");
	const nearest = Math.min(dist(loose, alice), dist(loose, alias));
	assert(
		nearest > NEAR_PEER,
		"an ambiguous claim was placed on one of the two",
	);
});

layoutTest("an author's placement of a loose end wins", () => {
	const doc = docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s", { designator: ALICE_DESIGNATOR }),
	]);
	// The pin lives on the session, the only thing that outlives the end. An
	// author who put the end somewhere meant it, so the pin beats the lean and
	// the end is a solved body again, holding its own position.
	const session = doc.entities?.sessions?.["s"];
	assert(session !== undefined);
	session.endpointPosition = { b: { x: 1234, y: -900 } };
	const loose = placed(doc).get("s::b");
	assert(loose !== undefined);
	assertEquals({ x: loose.x, y: loose.y }, { x: 1234, y: -900 });
});

layoutTest("attribution moves the end and nothing else", () => {
	// Why the placement is worth having, and the strongest claim this file
	// makes. The session was solved to Alice while the end was still only
	// claiming to be her, so backing the claim changes no force in the graph:
	// every peer stays where it was, to the last bit. The placeholder is removed
	// and the edge's end is on Alice, who has not moved.
	const claiming = docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s", { designator: ALICE_DESIGNATOR }),
	]);
	const attributed = docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s", {
			peer: "alice",
			designator: ALICE_DESIGNATOR,
			attributedBy: "authenticated-transport",
		}),
	]);
	const before = placed(claiming);
	const after = placed(attributed);
	assertEquals(
		after.has("s::b"),
		false,
		"the placeholder outlived the attribution that replaced it",
	);
	for (const peerId of ["alice", "carol"]) {
		const was = before.get(peerId);
		const now = after.get(peerId);
		assert(was !== undefined && now !== undefined);
		assertEquals(
			{ x: now.x, y: now.y },
			{ x: was.x, y: was.y },
			`${peerId} moved when the end was attributed`,
		);
	}
});

layoutTest("a claim at each end takes its own third of the wire", () => {
	// Neither end has a solved position of its own, so each contributes the
	// peer IT names and the segment is the one between those two peers. The
	// lookup is one step deep by construction, a claim never reads another
	// claim's position, so the two resolve together instead of chasing each
	// other.
	const at = placed(docOf([
		joined("alice", ALICE_DESIGNATOR),
		joined("bob", BOB_DESIGNATOR),
		between("s", { designator: ALICE_DESIGNATOR }, {
			designator: BOB_DESIGNATOR,
		}),
	]));
	const alice = at.get("alice");
	const bob = at.get("bob");
	const towardAlice = at.get("s::a");
	const towardBob = at.get("s::b");
	assert(alice !== undefined && bob !== undefined);
	assert(towardAlice !== undefined && towardBob !== undefined);
	assertAlmostEquals(
		onSegment(towardAlice, bob, alice).along,
		CLAIM_LEAN,
		1e-9,
	);
	assertAlmostEquals(
		onSegment(towardBob, alice, bob).along,
		CLAIM_LEAN,
		1e-9,
	);
	// What is left of the wire between them, so the two read as two things.
	assertAlmostEquals(
		dist(towardAlice, towardBob),
		dist(alice, bob) * (2 * CLAIM_LEAN - 1),
		1e-9,
	);
});

layoutTest(
	"a session claiming the peer at its own far end leans nowhere",
	() => {
		// The degenerate segment: the end claims to be Alice and Alice is already
		// sitting at the other end of this very session. There is no direction to
		// lean in, so the end is an ordinary solved body, which is also what stops
		// the resolution from having to ask what a zero-length segment means.
		const at = placed(docOf([
			joined("alice", ALICE_DESIGNATOR),
			between("s", { peer: "alice", attributedBy: "self-reported" }, {
				designator: ALICE_DESIGNATOR,
			}),
		]));
		const alice = at.get("alice");
		const loose = at.get("s::b");
		assert(alice !== undefined && loose !== undefined);
		assert(
			dist(loose, alice) > BODIES_TOUCH,
			"the end landed on the peer its own session already reaches",
		);
	},
);

layoutTest("claims on one peer arrive from their own directions", () => {
	// What answers the crowd. Two claims about Alice, one on Bob's wire and one
	// on Carol's, ride two different edges and so land in two different places
	// without anything arranging them.
	const at = placed(docOf([
		joined("carol"),
		joined("bob"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s1", { designator: ALICE_DESIGNATOR }),
		between("s2", { peer: "bob", attributedBy: "self-reported" }, {
			designator: ALICE_DESIGNATOR,
		}),
	]));
	const first = at.get("s1::b");
	const second = at.get("s2::b");
	assert(first !== undefined && second !== undefined);
	assert(
		dist(first, second) > 60,
		`two claims from different peers landed ${dist(first, second)} apart`,
	);
});

layoutTest("two claims on one pair each ride their own lane", () => {
	// Two sessions between one pair describe one segment, so two claims leaning
	// along it on a single lane would sit on one point and a reader would see
	// A bundle offset moves a session's control point and never its endpoints,
	// so on its own it cannot separate two claims on the straight chord. A
	// claim placed on the CURVE rides the bow, so the same offset that fans the
	// two arcs apart carries their claims apart with them, and the reader sees
	// two ends because there are two.
	// sees two ends because there are two.
	const at = placed(docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s1", { designator: ALICE_DESIGNATOR }),
		opened("s2", { designator: ALICE_DESIGNATOR }),
	]));
	const first = at.get("s1::b");
	const second = at.get("s2::b");
	assert(first !== undefined && second !== undefined);
	assert(
		dist(first, second) > LOOSE_END_CLAIMING.radius,
		`two claims on one pair landed ${dist(first, second)} apart, close ` +
			`enough to read as one end`,
	);
});

layoutTest("authored mode places a claim on its edge too", () => {
	// Authored mode honors the author for every node it can, and a loose end is
	// not a node the author named. The session states a claim, and the claim
	// states where the end belongs. One rule, both modes.
	const doc = docOf([
		joined("carol"),
		joined("alice", ALICE_DESIGNATOR),
		opened("s", { designator: ALICE_DESIGNATOR }),
	]);
	const peers = doc.entities?.peers;
	assert(peers !== undefined);
	peers["carol"]!.position = { x: -300, y: 0 };
	peers["alice"]!.position = { x: 300, y: 0 };
	const at = placed(doc, { ...DEFAULT_LAYOUT_CONFIG, mode: "authored" });
	const claim = at.get("s::b");
	assert(claim !== undefined, "authored mode left the claim unplaced");
	// Almost, not exactly: a lone session is a singleton bundle whose curve
	// degenerates to its own chord, so this is the straight lean computed
	// through the Bezier and lands within float residue of it.
	assertAlmostEquals(claim.x, -300 + 600 * CLAIM_LEAN, 1e-9);
	assertAlmostEquals(claim.y, 0, 1e-9);
});
