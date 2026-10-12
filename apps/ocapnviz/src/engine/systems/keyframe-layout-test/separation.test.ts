// What a node draws is what is separated.
//
// A node's label is wider than its body, several times wider once it carries a
// designator, and hangs below it. A constant radius around each node's center,
// tuned to the body, lets labels sit on top of each other, and one sized for
// the label spends that width upward too. `nodeFootprint` is the box the solver
// separates instead, and these hold the two halves of that: nothing drawn
// overlaps anything else drawn, and the box is the one the renderer draws.

import { assert, assertEquals } from "@std/assert";
import { DEFAULT_LAYOUT_CONFIG, KeyframeLayoutSystem } from "../keyframe-layout-system.ts";
import { forceFootprints } from "../force-layout.ts";
import { type NodeFootprint, nodeFootprint } from "../node-footprint.ts";
import { NODE_RADIUS } from "../../../render/draw-helpers.ts";
import {
	endpointLabelText,
	NODE_LABEL,
	NODE_LABEL_GAP_PX,
	peerLabelText,
	pillSize,
} from "../../../render/stage-labels.ts";
import { TimelineDocument } from "../../timeline.ts";
import { layoutTest } from "./harness.ts";
import type { Vec2 } from "../../world.ts";

/** One session per end, all of them hanging off a single peer, each end
 *  naming something nobody on stage answers to. So every end is an ordinary
 *  solved body rather than a claim leaning on its own edge. */
function hubDoc(
	designators: readonly (string | undefined)[],
): TimelineDocument {
	const observations: unknown[] = [{
		id: "j-hub",
		t: 0,
		kind: "peer-joined",
		peerId: "hub",
		profile: "glowcap",
	}];
	designators.forEach((designator, i) => {
		observations.push({
			id: `o-${i}`,
			t: 0,
			kind: "session-opened",
			sessionId: `s${i}`,
			a: { peer: "hub", attributedBy: "self-reported" },
			b: designator === undefined ? {} : { designator },
			codec: "syrup",
			captpVersion: "v1_0",
		});
	});
	return {
		id: "hub-doc",
		duration: 1000,
		recording: {
			sources: [{
				id: "fixture",
				meta: { kind: "fixture" },
				observations,
			}],
		},
	} as unknown as TimelineDocument;
}

/** A hub every peer holds a session with, each of those peers wearing the
 *  same display name. A name is the label a person chose, so unlike a
 *  designator it is drawn whole however long it is. */
function namedHubDoc(name: string, count: number): TimelineDocument {
	const observations: unknown[] = [{
		id: "j-hub",
		t: 0,
		kind: "peer-joined",
		peerId: "hub",
		profile: "glowcap",
	}];
	for (let i = 0; i < count; i++) {
		observations.push({
			id: `j-${i}`,
			t: 0,
			kind: "peer-joined",
			peerId: `p${i}`,
			label: name,
			profile: "glowcap",
		});
		observations.push({
			id: `o-${i}`,
			t: 0,
			kind: "session-opened",
			sessionId: `s${i}`,
			a: { peer: "hub", attributedBy: "self-reported" },
			b: { peer: `p${i}`, attributedBy: "self-reported" },
			codec: "syrup",
			captpVersion: "v1_0",
		});
	}
	return {
		id: "named-hub-doc",
		duration: 1000,
		recording: {
			sources: [{
				id: "fixture",
				meta: { kind: "fixture" },
				observations,
			}],
		},
	} as unknown as TimelineDocument;
}

/** The last keyframe's layout, which is the arrangement a reader ends on. */
/** Two peers wearing the same caption, joined by one session. The smallest
 *  document in which a peer caption is the only thing deciding how far apart
 *  the graph has to stand. */
function pairDoc(label: string): TimelineDocument {
	return {
		id: "pair-doc",
		duration: 1000,
		recording: {
			sources: [{
				id: "fixture",
				meta: { kind: "fixture" },
				observations: [
					{
						id: "j0",
						t: 0,
						kind: "peer-joined",
						peerId: "p0",
						label,
					},
					{
						id: "j1",
						t: 0,
						kind: "peer-joined",
						peerId: "p1",
						label,
					},
					{
						id: "o0",
						t: 0,
						kind: "session-opened",
						sessionId: "s0",
						a: { peer: "p0", attributedBy: "self-reported" },
						b: { peer: "p1", attributedBy: "self-reported" },
						codec: "syrup",
						captpVersion: "v1_0",
					},
				],
			}],
		},
	} as unknown as TimelineDocument;
}

function settled(doc: TimelineDocument): Map<string, Vec2> {
	const kfs = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG).keyframes;
	return new Map(kfs[kfs.length - 1]!.layout);
}

/** How far into each other two nodes' drawn boxes reach, in world units.
 *  zero or less when they clear. */
function boxOverlap(
	a: Vec2,
	aBox: NodeFootprint,
	b: Vec2,
	bBox: NodeFootprint,
): number {
	const x = aBox.halfWidth + bBox.halfWidth - Math.abs(a.x - b.x);
	const upper = a.y <= b.y ? aBox : bBox;
	const lower = a.y <= b.y ? bBox : aBox;
	const y = upper.below + lower.above - Math.abs(a.y - b.y);
	return Math.min(x, y);
}

layoutTest(
	"the box the solver keeps clear is the one the renderer draws",
	() => {
		// At 100% zoom, which is where a world-unit box and a counter-scaled
		// label are the same size. Zooming out grows every label against a graph
		// solved once; `stage-labels.ts` carries that and bounds the worst case.
		//
		// The mirror `node-footprint.ts` keeps of `NODE_RADIUS`, checked
		// against the authority rather than trusted. A body drawn at one size and
		// separated at another is a gap no reader could explain.
		assertEquals(nodeFootprint("", false).above, NODE_RADIUS);
		// The pill is not mirrored at all. It is read from the same module the
		// renderer sets the type from, and this is that arithmetic stated once
		// more from the outside. A padding change in `stage-labels.ts` moves both
		// sides of this together; a padding change made at either call site moves
		// only one, and `stage-labels.test.ts` is what refuses that.
		const label = "carol (exporter)";
		const pill = pillSize(label.length, NODE_LABEL, false);
		const box = nodeFootprint(label, false);
		assertEquals(box.halfWidth, pill.width / 2);
		assertEquals(box.below, NODE_RADIUS + NODE_LABEL_GAP_PX + pill.height);
		// And the label really is measured: a longer name is a wider box, in the
		// family the renderer draws that kind of label in.
		const short = nodeFootprint("ab", true);
		const long = nodeFootprint("ab".repeat(20), true);
		assert(
			long.halfWidth > short.halfWidth * 4,
			`a 40-character label measured ${long.halfWidth}, barely more than a two-character one at ${short.halfWidth}`,
		);
		// A short label still leaves the body as the widest thing at the node.
		assertEquals(short.halfWidth, NODE_RADIUS);
	},
);

layoutTest(
	"an end's box is the shortened designator the stage writes, not the whole one",
	() => {
		// The two halves of one fact. The stage shortens a long designator before
		// drawing it, so the room reserved for that end has to be the room the
		// shortened pill takes, reserving for the whole sixty-four characters
		// would hold a hub's ends a pill's width apart for a label nobody draws,
		// and the fan would not fit on one ring.
		const hostId = "9f".repeat(32);
		const drawn = endpointLabelText(hostId);
		const doc = hubDoc([hostId]);
		const at = settled(doc);
		const end = at.get("s0::b");
		const hub = at.get("hub");
		assert(end !== undefined && hub !== undefined);
		// What the solver kept clear, measured against what is written there.
		const box = nodeFootprint(drawn, true);
		assertEquals(
			box.halfWidth,
			pillSize(drawn.length, NODE_LABEL, true).width / 2,
		);
		assert(
			box.halfWidth < nodeFootprint(hostId, true).halfWidth / 2,
			"shortening the designator did not shrink the box the solver reserves",
		);
		// And the pair really settled: the end is on stage at a place of its own
		// rather than on top of the hub it belongs to.
		assert(Math.hypot(end.x - hub.x, end.y - hub.y) > NODE_RADIUS * 2);
	},
);

layoutTest(
	"a peer's box is the shortened caption the stage writes, not the whole one",
	() => {
		// The same fact on the peer side, and the reason it is a separate test:
		// a peer with no stated name wears its id, which for a wire-derived peer
		// is as long as any designator. The renderer shortens it; if the solver
		// did not, two such peers would be held a whole pill apart for text
		// nobody draws.
		const long = `glowcap-peer-${"b4".repeat(40)}`;
		const doc = pairDoc(long);
		const at = settled(doc);
		const p0 = at.get("p0");
		const p1 = at.get("p1");
		assert(p0 !== undefined && p1 !== undefined);

		const drawn = peerLabelText(long);
		const drawnBox = nodeFootprint(drawn, false);
		assertEquals(
			drawnBox.halfWidth,
			pillSize(drawn.length, NODE_LABEL, false).width / 2,
		);
		// What the reservation has to buy: the captions the stage really writes
		// clear each other.
		assert(
			boxOverlap(p0, drawnBox, p1, drawnBox) <= 0,
			"two long-captioned peers overlap the labels they actually draw",
		);
		// And what it must not buy: room for the whole string. Nothing but the
		// caption differs between these two documents, so a solver measuring
		// what the stage draws settles them identically. One that measures the
		// whole caption stands the long pair further apart, for text nobody
		// writes, and the two pictures come apart.
		const asDrawn = settled(pairDoc(drawn));
		assertEquals(
			[p0, p1],
			[asDrawn.get("p0"), asDrawn.get("p1")],
			"the pair laid out differently from the caption the stage draws for it",
		);
	},
);

layoutTest("wide labels are kept out of each other", () => {
	// The screenshot this work started from: ends whose labels were several
	// times wider than the bodies they named, overlapping constantly. Every
	// node here wears a full-length designator, so the labels are the only
	// thing deciding how much room the graph needs.
	const doc = hubDoc(
		Array.from(
			{ length: 8 },
			(_, i) => String.fromCharCode(97 + i).repeat(48),
		),
	);
	const at = settled(doc);
	const boxes = new Map(
		[...at.keys()].map((
			id,
		) => [
			id,
			id === "hub" ? nodeFootprint("hub", false) : nodeFootprint(
				// The label the stage actually writes under the end, which is what
				// the solver reserved for: a designator this long is shortened
				// before it is drawn.
				endpointLabelText(
					String.fromCharCode(97 + Number(id[1])).repeat(48),
				),
				true,
			),
		]),
	);
	const ids = [...at.keys()];
	for (let i = 0; i < ids.length; i++) {
		for (let j = i + 1; j < ids.length; j++) {
			const overlap = boxOverlap(
				at.get(ids[i]!)!,
				boxes.get(ids[i]!)!,
				at.get(ids[j]!)!,
				boxes.get(ids[j]!)!,
			);
			assert(
				overlap <= 0,
				`${ids[i]} and ${ids[j]} reach ${overlap.toFixed(0)} into each other's drawing`,
			);
		}
	}
});

layoutTest(
	"a wide label costs sideways room, not room in every direction",
	() => {
		// What the box buys over a circle, and the reason the separation is not
		// simply `forceCollide` with a bigger radius. A long display name's pill is
		// several hundred units across; a circle wide enough to clear it sideways
		// clears it upward too, so every node ends up demanding its widest
		// dimension in every direction. The dense-middle, empty-margin picture.
		// Two nodes wearing wide labels are free to sit one above the other, and
		// here they do, closer than a circle sized for the label would ever have
		// let them.
		//
		// A peer's display name rather than a designator, because a designator is
		// shortened before it is drawn and can no longer be the widest thing on
		// the stage. A name a person chose is not shortened, so it still can.
		const name = "a".repeat(48);
		const width = nodeFootprint(name, false).halfWidth * 2;
		const at = [...settled(namedHubDoc(name, 6)).values()];
		let closest = Infinity;
		for (let i = 0; i < at.length; i++) {
			for (let j = i + 1; j < at.length; j++) {
				closest = Math.min(
					closest,
					Math.hypot(at[i]!.x - at[j]!.x, at[i]!.y - at[j]!.y),
				);
			}
		}
		assert(
			closest < width,
			`the closest pair sits ${closest.toFixed(0)} apart with labels ${
				width.toFixed(0)
			} wide, which is the separation a circle would have insisted on`,
		);
		// And not so close that the bodies crowd: the box still holds them a body
		// and its label apart in the direction that matters.
		assert(
			closest > NODE_RADIUS * 4,
			`the closest pair sits ${closest.toFixed(0)} apart`,
		);
	},
);

layoutTest("a peer's unattributed ends fan around it", () => {
	// Seeding every node with no region prefix on the same point starts the
	// solver from a pile that its repulsion breaks arbitrarily: a peer's ends
	// would come out gathered on one side of it, with a wedge of empty canvas
	// opposite. The seed is a phyllotaxis spiral, so the ends start apart and
	// stay apart.
	const at = settled(hubDoc(Array.from({ length: 8 }, () => undefined)));
	const hub = at.get("hub");
	assert(hub !== undefined);
	const angles = [...at.entries()]
		.filter(([id]) => id !== "hub")
		.map(([, p]) => Math.atan2(p.y - hub.y, p.x - hub.x))
		.sort((a, b) => a - b);
	let widest = angles[0]! + Math.PI * 2 - angles[angles.length - 1]!;
	for (let i = 1; i < angles.length; i++) {
		widest = Math.max(widest, angles[i]! - angles[i - 1]!);
	}
	// An even fan of eight leaves a quarter turn between neighbours. Allow half
	// as much again for the pull of the links, and no more: at twice the even
	// share the ends have visibly taken one side.
	const even = (Math.PI * 2) / angles.length;
	assert(
		widest < even * 1.5,
		`the widest empty wedge around the peer is ${
			(widest / even).toFixed(2)
		} times an even share, so its ends are bunched`,
	);
});

/** One pass of the separation force over nodes starting at these points,
 *  answering where each would be once its velocity is integrated. Every node
 *  wears a bare body, and the padding is zero, so the room a pair needs is
 *  simply two half-widths. */
function afterOnePass(at: readonly Vec2[]): Vec2[] {
	const box = nodeFootprint("", false);
	const boxes = new Map(at.map((_, i) => [`n${i}`, box]));
	const nodes = at.map((p, i) => ({
		id: `n${i}`,
		x: p.x,
		y: p.y,
		vx: 0,
		vy: 0,
	}));
	const force = forceFootprints(boxes, 0, 1);
	force.initialize(nodes);
	force();
	return nodes.map((n) => ({ x: n.x + n.vx, y: n.y + n.vy }));
}

layoutTest(
	"two nodes on one point are pushed apart, wherever they sit in the array",
	() => {
		// A pile has no line to separate along, so the force invents a ray for it.
		// The ray used to be handed to arithmetic that grows an EXISTING gap, and a
		// pile has none: at the first index the ray runs along x, the growth factor
		// came out exactly one, and the pair was left stacked for every remaining
		// tick. At every other index it moved a fraction of the distance it needed.
		//
		// One pass with nothing else acting, because a whole solve's charge would
		// separate a pile anyway and hide the whole thing.
		const box = nodeFootprint("", false);
		const needX = box.halfWidth * 2;
		const needY = box.above + box.below;
		const clears = (p: Vec2, q: Vec2): boolean =>
			Math.abs(p.x - q.x) >= needX - 1e-9 ||
			Math.abs(p.y - q.y) >= needY - 1e-9;

		// The pair the first index owns, which is the one that never moved at all.
		const first = afterOnePass([{ x: 0, y: 0 }, { x: 0, y: 0 }]);
		assert(
			clears(first[0]!, first[1]!),
			`the first pair came out of the pass ${
				Math.hypot(first[0]!.x - first[1]!.x, first[0]!.y - first[1]!.y)
					.toFixed(1)
			} apart, still inside each other's boxes`,
		);

		// And a pair further along, which moved but nothing like far enough. The
		// node ahead of them sits well clear so only the pile is in play.
		const later = afterOnePass([{ x: 900, y: 900 }, { x: 0, y: 0 }, {
			x: 0,
			y: 0,
		}]);
		assert(
			clears(later[1]!, later[2]!),
			`a later pair came out of the pass ${
				Math.hypot(later[1]!.x - later[2]!.x, later[1]!.y - later[2]!.y)
					.toFixed(1)
			} apart, still inside each other's boxes`,
		);

		// The fan is still deterministic, and it is still a fan: two piles at
		// different indices leave along different rays.
		assertEquals(afterOnePass([{ x: 0, y: 0 }, { x: 0, y: 0 }]), first);
	},
);

/** The layout as a comparable value: every keyframe's placements, in one
 *  string per node so a failure names the node that moved. */
function placements(doc: TimelineDocument): string[][] {
	return new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG).keyframes.map(
		(k) =>
			[...k.layout.entries()]
				.map(([id, p]) => `${id}:${p.x}:${p.y}`)
				.sort(),
	);
}

/** The same document with its observations stated in the opposite order. Same
 *  topology, same moments, different insertion order. */
function reordered(doc: TimelineDocument): TimelineDocument {
	const source = (doc as unknown as {
		recording: { sources: Array<{ observations: unknown[] }> };
	}).recording.sources[0]!;
	return {
		...doc,
		recording: {
			sources: [{
				...source,
				observations: [...source.observations].reverse(),
			}],
		},
	} as unknown as TimelineDocument;
}

layoutTest("the same document lays out identically every time", () => {
	// Half the contract the whole file is built on: no randomness and no wall
	// clock, so scrubbing forward and back visits the same pixels. Two runs of
	// one document is exactly what that catches and no more, a stray
	// `Math.random` or `Date.now` anywhere in the solve.
	const doc = () =>
		hubDoc([
			undefined,
			undefined,
			"tcp://198.51.100.4:9001",
			undefined,
			undefined,
		]);
	assertEquals(placements(doc()), placements(doc()));
});

layoutTest(
	"the same topology lays out identically whatever order it was stated in",
	() => {
		// The other half, and the one two runs of one document cannot reach. The
		// solve walks nodes in array order and the separation force reads and writes
		// velocities in that order, so a tie broken by position in the array would
		// be perfectly repeatable and still wrong: the same graph, saved by two
		// authors who added their peers in different orders, would settle into two
		// different pictures. Every ordering-sensitive step is sorted for this
		// reason, the node ids, and the session ids a bundle's lanes are numbered
		// by, and this is what says so.
		const doc = hubDoc([
			undefined,
			"tcp://198.51.100.4:9001",
			undefined,
			"tcp://203.0.113.9:9001",
		]);
		assertEquals(placements(doc), placements(reordered(doc)));
	},
);
