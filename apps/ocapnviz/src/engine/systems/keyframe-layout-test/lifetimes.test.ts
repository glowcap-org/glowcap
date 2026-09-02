// When each thing arrives, and when it leaves.

import { assert, assertEquals } from "@std/assert";
import { World } from "miniplex";
import { DEFAULT_LAYOUT_CONFIG, KeyframeLayoutSystem } from "../keyframe-layout-system.ts";
import { TimelineDocument } from "../../timeline.ts";
import { attachedEndpoint } from "../../../schema/session-end.ts";
import { materializeWorldAt } from "../world-materializer.ts";
import { layoutTest } from "./harness.ts";
import type { Components, GameWorld, Vec2 } from "../../world.ts";

/** A document with a peer nothing announces beside peers that observations
 *  do, so both halves of the moment stream are in play. `timing` is stated
 *  where the test wants the declared entity to arrive and leave. */
function declaredAndObservedDoc(
	timing?: { start: number; duration: number },
): TimelineDocument {
	return {
		id: "declared-and-observed",
		duration: 2000,
		entities: {
			peers: {
				authored: {
					profile: "glowcap",
					...(timing !== undefined
						? {
							timing: {
								start: { value: timing.start, explicit: true },
								duration: {
									value: timing.duration,
									explicit: true,
								},
							},
						}
						: {}),
				},
			},
		},
		recording: {
			sources: [{
				id: "fixture",
				meta: { kind: "fixture" },
				observations: [
					{
						id: "j-carol",
						t: 0,
						kind: "peer-joined",
						peerId: "carol",
						profile: "glowcap",
					},
					{
						id: "j-bob",
						t: 0,
						kind: "peer-joined",
						peerId: "bob",
						profile: "glowcap",
					},
					{
						id: "o-s",
						t: 0,
						kind: "session-opened",
						sessionId: "s",
						a: attachedEndpoint("carol"),
						b: attachedEndpoint("bob"),
						codec: "syrup",
						captpVersion: "v1_0",
					},
				],
			}],
		},
	} as unknown as TimelineDocument;
}

layoutTest("one moment is one keyframe", () => {
	// A keyframe list is one layout per moment. When the entities the document
	// declares were seeded as a keyframe of their own, a document that also
	// observed something at t=0 got two keyframes at that one moment: the
	// second read as the era in force and the first as the era before it, so at
	// t=0 the stage drew the seed and then slid into the real layout over the
	// whole transition window. Nothing had changed, and scrubbing back replayed
	// it every time.
	const system = new KeyframeLayoutSystem(declaredAndObservedDoc());
	const moments = system.keyframes.map((kf) => kf.t);
	assertEquals(
		moments.length,
		new Set(moments).size,
		`two keyframes at one moment: ${moments.join(", ")}`,
	);
});

layoutTest("nothing moves through a window in which nothing changed", () => {
	// The consequence, in the pixels. The window after t=0 is the transition
	// window, which is exactly where the duplicate moment was visible.
	const doc = declaredAndObservedDoc();
	const system = new KeyframeLayoutSystem(doc);
	const world = new World<Components>();
	materializeWorldAt(world, doc, 0);
	system.update(world, 0);
	const startOfWindow = new Map(
		[...world.with("peer", "position")].map((
			e,
		) => [e.peer.id, { x: e.position.x, y: e.position.y }]),
	);
	system.update(world, DEFAULT_LAYOUT_CONFIG.transitionWindow / 2);
	for (const e of world.with("peer", "position")) {
		const was = startOfWindow.get(e.peer.id);
		assert(was !== undefined);
		assertEquals(
			{ x: e.position.x, y: e.position.y },
			was,
			`${e.peer.id} drifted through a window in which nothing happened`,
		);
	}
});

layoutTest(
	"an entity only the document declares keeps to its own timing",
	() => {
		// Nothing announces an entity authored in Build, so its declared timing is
		// what says when it arrives and when it leaves — the same two moments an
		// observed entity's join and departure state. Seeded into every era
		// instead, it was a body in the solve before it existed, holding space
		// against peers that were standing there and taking none of its own when it
		// finally was.
		const doc = declaredAndObservedDoc({ start: 800, duration: 200 });
		const eras = new KeyframeLayoutSystem(doc).keyframes;
		const at = (t: number) =>
			[...eras].reverse().find((kf) => kf.t <= t)?.layout ?? new Map<
				string,
				Vec2
			>();
		assertEquals(
			at(0).has("authored"),
			false,
			"a peer timed to a later window held a place in the first era",
		);
		assertEquals(
			at(900).has("authored"),
			true,
			"a peer never arrived in the window its timing declares",
		);
		assertEquals(
			at(1100).has("authored"),
			false,
			"a peer outstayed the window its timing declares",
		);
	},
);

layoutTest(
	"settled update still lands a placement recompute",
	() => {
		// Past the transition window, `update` skips rewriting positions.
		// A pin must still land: recomputeForPlacement bumps the layout
		// generation so the next update cannot keep the pre-pin coords.
		const doc = TimelineDocument.parse({
			id: "settled-placement",
			duration: 5000,
			layoutMode: "authored",
			events: [
				{
					id: "a0",
					t: 0,
					kind: "peer-joined",
					peerId: "a",
					profile: "glowcap",
					position: { x: 0, y: 0 },
				},
				{
					id: "b0",
					t: 0,
					kind: "peer-joined",
					peerId: "b",
					profile: "goblins",
					position: { x: 100, y: 0 },
				},
			],
		});
		const layout = new KeyframeLayoutSystem(doc);
		const world = new World<Components>() as GameWorld;
		materializeWorldAt(world, doc, 0);
		const settledT = DEFAULT_LAYOUT_CONFIG.transitionWindow + 50;
		layout.update(world, settledT);
		layout.update(world, settledT); // second call is the early-out
		const beforePos = [...world.with("peer", "position")].find((e) => e.peer.id === "a")!
			.position;
		const before = { x: beforePos.x, y: beforePos.y };
		doc.entities!.peers!.a!.position = { x: 40, y: 40 };
		layout.recomputeForPlacement();
		layout.update(world, settledT);
		const after = [...world.with("peer", "position")].find((e) => e.peer.id === "a")!
			.position;
		assertEquals(
			{ x: after.x, y: after.y },
			{ x: 40, y: 40 },
			"a settled early-out kept the pre-pin position after placement",
		);
		assert(
			before.x !== after.x || before.y !== after.y,
			"the peer was already at the pin, so this test proves nothing",
		);
	},
);
