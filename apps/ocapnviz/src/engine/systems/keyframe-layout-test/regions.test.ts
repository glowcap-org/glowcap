/**
 * Region-aware layout in `KeyframeLayoutSystem`.
 *
 * The keyframe layout normally produces opaque positions (d3-force
 * convergence depends on the full graph). We verify the
 * region-aware behavior by:
 *
 * 1. Building a `TimelineDocument` with region-prefixed peers
 *    spread across continents.
 * 2. Running the layout system on a fresh `GameWorld`.
 * 3. Asserting that each peer's final position is closer to its
 *    region's centroid than to other regions' centroids — i.e. the
 *    region pull force won.
 *
 * This pins the behavior so a future refactor can't accidentally
 * regress region-aware layout to a global force-only blob.
 */

import { assert } from "@std/assert";
import { DEFAULT_LAYOUT_CONFIG, KeyframeLayoutSystem } from "../keyframe-layout-system.ts";
import { TimelineDocument } from "../../timeline.ts";
import { attachedEndpoint } from "../../../schema/session-end.ts";
import { dist, freshWorld, layoutTest } from "./harness.ts";
import type { Vec2 } from "../../world.ts";

function makeRegionDoc(): TimelineDocument {
	return {
		id: "region-layout-test",
		duration: 1000,
		recording: {
			sources: [{
				id: "fixture",

				meta: { kind: "fixture" },

				observations: [
					{
						id: "j1",
						t: 0,
						kind: "peer-joined",
						peerId: "us-alice",
						profile: "glowcap",
					},
					{
						id: "j2",
						t: 0,
						kind: "peer-joined",
						peerId: "eu-bob",
						profile: "glowcap",
					},
					{
						id: "j3",
						t: 0,
						kind: "peer-joined",
						peerId: "ap-carol",
						profile: "glowcap",
					},
					{
						id: "s1",
						t: 100,
						kind: "session-opened",
						sessionId: "eu-bob--us-alice",
						a: attachedEndpoint("us-alice"),
						b: attachedEndpoint("eu-bob"),
						codec: "syrup",
						captpVersion: "v1_0",
					},
					{
						id: "s2",
						t: 100,
						kind: "session-opened",
						sessionId: "ap-carol--us-alice",
						a: attachedEndpoint("us-alice"),
						b: attachedEndpoint("ap-carol"),
						codec: "syrup",
						captpVersion: "v1_0",
					},
				],
			}],
		},
	};
}

layoutTest("region-prefixed peers land near their continental centroid", () => {
	const doc = makeRegionDoc();
	const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
	const world = freshWorld(["us-alice", "eu-bob", "ap-carol"]);
	layout.update(world, 100); // post-session keyframe, transition complete

	const positions = new Map<string, Vec2>();
	for (const e of world.with("peer", "position")) {
		positions.set(e.peer.id, e.position);
	}

	const usCentroid = { x: -480, y: -60 };
	const euCentroid = { x: 60, y: -180 };
	const apCentroid = { x: 460, y: -40 };

	const us = positions.get("us-alice")!;
	const eu = positions.get("eu-bob")!;
	const ap = positions.get("ap-carol")!;

	// Each peer must be closer to ITS centroid than to either of the
	// other two — the region force won over the link / charge forces.
	assert(
		dist(us, usCentroid) < dist(us, euCentroid),
		`us-alice should be closer to US than EU; got us=${JSON.stringify(us)}`,
	);
	assert(
		dist(us, usCentroid) < dist(us, apCentroid),
		`us-alice should be closer to US than AP; got us=${JSON.stringify(us)}`,
	);
	assert(
		dist(eu, euCentroid) < dist(eu, usCentroid),
		`eu-bob should be closer to EU than US; got eu=${JSON.stringify(eu)}`,
	);
	assert(
		dist(eu, euCentroid) < dist(eu, apCentroid),
		`eu-bob should be closer to EU than AP; got eu=${JSON.stringify(eu)}`,
	);
	assert(
		dist(ap, apCentroid) < dist(ap, usCentroid),
		`ap-carol should be closer to AP than US; got ap=${JSON.stringify(ap)}`,
	);
	assert(
		dist(ap, apCentroid) < dist(ap, euCentroid),
		`ap-carol should be closer to AP than EU; got ap=${JSON.stringify(ap)}`,
	);
});

layoutTest(
	"unprefixed peers ignore the region force and stay near (0, 0)",
	() => {
		const doc: TimelineDocument = {
			id: "unprefixed-layout-test",
			duration: 1000,
			recording: {
				sources: [{
					id: "fixture",

					meta: { kind: "fixture" },

					observations: [
						{
							id: "j1",
							t: 0,
							kind: "peer-joined",
							peerId: "alice",
							profile: "glowcap",
						},
						{
							id: "j2",
							t: 0,
							kind: "peer-joined",
							peerId: "bob",
							profile: "glowcap",
						},
					],
				}],
			},
		};
		const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
		const world = freshWorld(["alice", "bob"]);
		layout.update(world, 0);

		// Without region prefix, both peers should be within ~400 of the
		// origin — the existing behavior. Far less than the ~480 a US-only
		// centroid would pull them.
		for (const e of world.with("peer", "position")) {
			const d = Math.hypot(e.position.x, e.position.y);
			assert(
				d < 400,
				`${e.peer.id} should stay near origin; got distance=${d}`,
			);
		}
	},
);

layoutTest(
	"multiple peers in the same region spread out from the centroid",
	() => {
		const doc: TimelineDocument = {
			id: "many-in-region-test",
			duration: 1000,
			recording: {
				sources: [{
					id: "fixture",

					meta: { kind: "fixture" },

					observations: [
						{
							id: "j1",
							t: 0,
							kind: "peer-joined",
							peerId: "us-a",
							profile: "glowcap",
						},
						{
							id: "j2",
							t: 0,
							kind: "peer-joined",
							peerId: "us-b",
							profile: "glowcap",
						},
						{
							id: "j3",
							t: 0,
							kind: "peer-joined",
							peerId: "us-c",
							profile: "glowcap",
						},
					],
				}],
			},
		};
		const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
		const world = freshWorld(["us-a", "us-b", "us-c"]);
		layout.update(world, 0);

		const positions: Vec2[] = [];
		for (const e of world.with("peer", "position")) {
			positions.push(e.position);
		}
		// No two peers should occupy the same point (collision force +
		// distinct seed positions). Pairwise distance > 0.
		for (let i = 0; i < positions.length; i++) {
			for (let j = i + 1; j < positions.length; j++) {
				const d = dist(positions[i]!, positions[j]!);
				assert(d > 1, `peers should not coincide; got distance=${d}`);
			}
		}
	},
);

layoutTest(
	"two-segment cloud-region tags (us-east, us-west) place peers at distinct sub-region centroids",
	() => {
		const doc: TimelineDocument = {
			id: "cloud-region-test",
			duration: 1000,
			recording: {
				sources: [{
					id: "fixture",

					meta: { kind: "fixture" },

					observations: [
						{
							id: "j1",
							t: 0,
							kind: "peer-joined",
							peerId: "us-east-alice",
							profile: "glowcap",
						},
						{
							id: "j2",
							t: 0,
							kind: "peer-joined",
							peerId: "us-west-bob",
							profile: "glowcap",
						},
						{
							id: "j3",
							t: 0,
							kind: "peer-joined",
							peerId: "ap-northeast-carol",
							profile: "glowcap",
						},
						{
							id: "j4",
							t: 0,
							kind: "peer-joined",
							peerId: "ap-southeast-dave",
							profile: "glowcap",
						},
					],
				}],
			},
		};
		const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
		const world = freshWorld([
			"us-east-alice",
			"us-west-bob",
			"ap-northeast-carol",
			"ap-southeast-dave",
		]);
		layout.update(world, 0);

		const positions = new Map<string, Vec2>();
		for (const e of world.with("peer", "position")) {
			positions.set(e.peer.id, e.position);
		}
		const usEast = positions.get("us-east-alice")!;
		const usWest = positions.get("us-west-bob")!;
		const apNe = positions.get("ap-northeast-carol")!;
		const apSe = positions.get("ap-southeast-dave")!;

		// East/West coast separation: us-east-alice should sit clearly
		// RIGHT of us-west-bob (us-east x = -380, us-west x = -560).
		assert(
			usEast.x > usWest.x,
			`us-east should be east (right) of us-west; got us-east=${JSON.stringify(usEast)} us-west=${
				JSON.stringify(usWest)
			}`,
		);
		// ap-southeast (Singapore-ish) should sit BELOW ap-northeast (Tokyo-ish).
		assert(
			apSe.y > apNe.y,
			`ap-southeast should be south (below) of ap-northeast; got se=${JSON.stringify(apSe)} ne=${
				JSON.stringify(apNe)
			}`,
		);
	},
);

layoutTest(
	"single-segment 'us-alice' falls back to continental rollup",
	() => {
		// Multiple peers across continents — d3-force's `forceCenter`
		// anchors center-of-mass to origin, so single-peer scenarios
		// are degenerate (the lone peer IS the COM and gets pulled to
		// origin). With three peers in three continents, COM averages
		// out and per-node region forces win.
		const doc: TimelineDocument = {
			id: "rollup-test",
			duration: 1000,
			recording: {
				sources: [{
					id: "fixture",

					meta: { kind: "fixture" },

					observations: [
						{
							id: "j1",
							t: 0,
							kind: "peer-joined",
							peerId: "us-alice",
							profile: "glowcap",
						},
						{
							id: "j2",
							t: 0,
							kind: "peer-joined",
							peerId: "eu-bob",
							profile: "glowcap",
						},
						{
							id: "j3",
							t: 0,
							kind: "peer-joined",
							peerId: "ap-carol",
							profile: "glowcap",
						},
					],
				}],
			},
		};
		const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
		const world = freshWorld(["us-alice", "eu-bob", "ap-carol"]);
		layout.update(world, 0);
		const positions = new Map<string, Vec2>();
		for (const e of world.with("peer", "position")) {
			positions.set(e.peer.id, e.position);
		}
		// 'us' continental rollup is at x=-480, eu at x=60, ap at x=480.
		// After force settles, us-alice should be CLEARLY left of eu-bob
		// and eu-bob clearly left of ap-carol — proving rollup parsing
		// handed each peer to its continental centroid.
		const us = positions.get("us-alice")!;
		const eu = positions.get("eu-bob")!;
		const ap = positions.get("ap-carol")!;
		assert(us.x < eu.x, `us should be left of eu; us=${us.x} eu=${eu.x}`);
		assert(eu.x < ap.x, `eu should be left of ap; eu=${eu.x} ap=${ap.x}`);
	},
);

// `authored` layout mode is the builder's substrate: peer positions
// come straight from each `peer-joined` event's `position` field and
// no d3-force convergence runs. These tests pin that contract — a
// builder that writes `(140, -82)` should see the canvas place that
// peer at exactly `(140, -82)`, every frame, forever.
