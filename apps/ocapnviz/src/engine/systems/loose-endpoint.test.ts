import { assert, assertEquals } from "@std/assert";
import { createWorld, findEndpoint, findNode } from "../world.ts";
import { materializeWorldAt } from "./world-materializer.ts";
import { sessionCurve } from "../session-geometry.ts";
import type { TimelineDocument } from "../timeline.ts";
import { KeyframeLayoutSystem } from "./keyframe-layout-system.ts";

Deno.test("a loose end is a node on the stage, and its edge is drawn", () => {
	// The claim this file exists to hold. An end nothing attributed occupies a
	// place: the force layout needs a position at both ends of every edge, and
	// a reader needs something to select in order to ask what the end claims.
	//
	// It was asserted before it was true. `endpointNodeId` reached the layout
	// while the materializer minted world entities only from `doc.entities.peers`,
	// so the loose end had no entity and no position — and `sessionCurve`, which
	// looked ends up with `findPeer`, returned null and dropped the whole edge
	// along with every message on it. Nothing failed; the session simply was
	// not there.
	const doc = {
		id: "d",
		duration: 100,
		rowOrder: {},
		rowHidden: {},
		rowLabelHidden: {},
		rowBodyHidden: {},
		entities: {
			peers: {
				carol: {
					profile: "glowcap",
					timing: {
						start: { value: 0, explicit: true },
						duration: { value: 100, explicit: true },
					},
				},
			},
			sessions: {
				s: {
					a: { peer: "carol", attributedBy: "self-reported" },
					b: { designator: "127.0.0.1:0" },
					codec: "syrup",
					captpVersion: "v1_0",
					timing: {
						start: { value: 0, explicit: true },
						duration: { value: 100, explicit: true },
					},
				},
			},
		},
	} as unknown as TimelineDocument;
	const world = createWorld();
	materializeWorldAt(world, doc, 50);
	const loose = findEndpoint(world, "s::b");
	assert(loose !== undefined, "the loose end was not drawn");
	assertEquals(loose.endpoint.designator, "127.0.0.1:0");
	assert(findNode(world, "s::b") !== undefined, "findNode cannot reach it");
	assert(findNode(world, "carol") !== undefined, "the peer is still a node");
	const curve = sessionCurve(world, "carol", "s::b", {
		index: 0,
		size: 1,
	});
	assert(curve !== null, "the edge to a loose end had no curve");
});

Deno.test("a loose end is placed by the layout, not left at the origin", () => {
	// The layout already solved for this node — `endpointNodeId` seeds it into
	// the force graph — but the write-back walked peers alone, so the entity
	// kept the origin it was minted at and its edge was drawn to (0, 0). A
	// node the solver placed and the world did not is worse than an unplaced
	// one: it looks like a position rather than an absence.
	const doc = {
		id: "d",
		duration: 100,
		rowOrder: {},
		rowHidden: {},
		rowLabelHidden: {},
		rowBodyHidden: {},
		recording: {
			sources: [{
				id: "s",
				meta: { kind: "input" },
				observations: [
					{
						id: "e1",
						kind: "peer-joined",
						t: 0,
						peerId: "carol",
						profile: "glowcap",
					},
					{
						id: "e2",
						kind: "session-opened",
						t: 0,
						sessionId: "s",
						a: { peer: "carol", attributedBy: "self-reported" },
						b: { designator: "127.0.0.1:0" },
						codec: "syrup",
						captpVersion: "v1_0",
					},
				],
			}],
		},
		entities: {
			peers: {
				carol: {
					profile: "glowcap",
					timing: {
						start: { value: 0, explicit: true },
						duration: { value: 100, explicit: true },
					},
				},
			},
			sessions: {
				s: {
					a: { peer: "carol", attributedBy: "self-reported" },
					b: { designator: "127.0.0.1:0" },
					codec: "syrup",
					captpVersion: "v1_0",
					timing: {
						start: { value: 0, explicit: true },
						duration: { value: 100, explicit: true },
					},
				},
			},
		},
	} as unknown as TimelineDocument;
	const world = createWorld();
	materializeWorldAt(world, doc, 50);
	const layout = new KeyframeLayoutSystem(doc);
	layout.update(world, 50);
	const loose = findEndpoint(world, "s::b");
	assert(loose !== undefined, "the loose end was not drawn");
	const carol = findNode(world, "carol");
	assert(carol !== undefined);
	const at = loose.position;
	const peerAt = carol.position;
	assert(at !== undefined, "the loose end has no position component");
	assert(peerAt !== undefined, "the peer has no position component");
	assert(
		at.x !== 0 || at.y !== 0 || (peerAt.x === 0 && peerAt.y === 0),
		"the layout placed the peer but left the loose end at the origin",
	);
});

Deno.test("authored loose ends are placed apart, not stacked on the origin", () => {
	// The sibling above carries a `session-opened` observation, which is how it
	// reached the layout at all. A session authored in Build has a definition
	// and nothing that announced it, and both walks over the node set are walks
	// over observations — so every such end fell through to the origin and any
	// two of them landed on the same spot. Both ends of a peer-to-peer session
	// hid it, because a peer has a position of its own.
	const session = (id: string) =>
		[id, {
			a: { peer: "alice", attributedBy: "self-reported" },
			b: {},
			codec: "syrup",
			captpVersion: "v1_0",
			timing: {
				start: { value: 0, explicit: true },
				duration: { value: 100, explicit: true },
			},
		}] as const;
	const doc = {
		id: "d",
		duration: 100,
		rowOrder: {},
		rowHidden: {},
		rowLabelHidden: {},
		rowBodyHidden: {},
		entities: {
			peers: {
				alice: {
					profile: "glowcap",
					timing: {
						start: { value: 0, explicit: true },
						duration: { value: 100, explicit: true },
					},
				},
			},
			sessions: Object.fromEntries(["s1", "s2", "s3"].map(session)),
		},
	} as unknown as TimelineDocument;

	const layout = new KeyframeLayoutSystem(doc);
	const world = createWorld();
	materializeWorldAt(world, doc, 50);
	layout.update(world, 50);

	const at = ["s1::b", "s2::b", "s3::b"].map((id) => {
		const e = findEndpoint(world, id);
		assert(e !== undefined, `${id} was not drawn`);
		const pos = e.position;
		assert(pos !== undefined, `${id} has no position`);
		return { id, x: pos.x, y: pos.y };
	});
	const spots = new Set(
		at.map((p) => `${Math.round(p.x)},${Math.round(p.y)}`),
	);
	assertEquals(
		spots.size,
		at.length,
		`authored loose ends share a position: ${JSON.stringify(at)}`,
	);
});
