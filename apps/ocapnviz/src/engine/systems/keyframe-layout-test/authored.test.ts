// Authored positions pin the force modes.
//
// An authored `position` inside a force mode is a pin: every
// keyframe carries it exactly, and the sim holds the node fixed
// (`fx`/`fy`) while links still pull free neighbors around it. The
// defect this family was written against: a sim that integrates a
// pinned node like any other, drifting it off its authored point.

import { assert } from "@std/assert";
import { DEFAULT_LAYOUT_CONFIG, KeyframeLayoutSystem } from "../keyframe-layout-system.ts";
import { TimelineDocument } from "../../timeline.ts";
import { attachedEndpoint } from "../../../schema/session-end.ts";
import { dist, freshWorld, layoutTest } from "./harness.ts";
import type { Vec2 } from "../../world.ts";

layoutTest("authored mode places peers at their declared position", () => {
	const doc: TimelineDocument = {
		id: "authored-layout-test",
		duration: 1000,
		layoutMode: "authored",
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
						position: { x: 140, y: -82 },
					},
					{
						id: "j2",
						t: 0,
						kind: "peer-joined",
						peerId: "bob",
						profile: "goblins",
						position: { x: -210, y: 60 },
					},
				],
			}],
		},
	};
	const layout = new KeyframeLayoutSystem(doc, {
		...DEFAULT_LAYOUT_CONFIG,
		mode: "authored",
	});
	const world = freshWorld(["alice", "bob"]);
	layout.update(world, 0);
	const positions = new Map<string, Vec2>();
	for (const e of world.with("peer", "position")) {
		positions.set(e.peer.id, e.position);
	}
	const alice = positions.get("alice")!;
	const bob = positions.get("bob")!;
	assert(
		alice.x === 140 && alice.y === -82,
		`alice should be at (140, -82); got ${JSON.stringify(alice)}`,
	);
	assert(
		bob.x === -210 && bob.y === 60,
		`bob should be at (-210, 60); got ${JSON.stringify(bob)}`,
	);
});

layoutTest(
	"authored mode falls back to (0, 0) for peers without a position",
	() => {
		const doc: TimelineDocument = {
			id: "authored-missing-position",
			duration: 1000,
			layoutMode: "authored",
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
							// position omitted
						},
					],
				}],
			},
		};
		const layout = new KeyframeLayoutSystem(doc, {
			...DEFAULT_LAYOUT_CONFIG,
			mode: "authored",
		});
		const world = freshWorld(["alice"]);
		layout.update(world, 0);
		const alice = [...world.with("peer", "position")][0]?.position;
		assert(
			alice?.x === 0 && alice?.y === 0,
			`alice should fall back to origin; got ${JSON.stringify(alice)}`,
		);
	},
);

// ───────────────── authored positions pin the force modes ─────────────────
// An authored `position` inside a force mode is a pin: every
// keyframe carries it exactly, and the sim holds the node fixed
// (`fx`/`fy`) while links still pull free neighbors around it. The
// defect this family was written against: a sim that integrates a
// pinned node like any other, drifting it off its authored point.

layoutTest(
	"per-topology keyframes hold a pinned peer exactly while free peers move",
	() => {
		const doc: TimelineDocument = {
			id: "pin-per-topology-test",
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
							position: { x: 300, y: 200 },
						},
						{
							id: "j2",
							t: 0,
							kind: "peer-joined",
							peerId: "bob",
							profile: "goblins",
						},
						{
							id: "j3",
							t: 0,
							kind: "peer-joined",
							peerId: "carol",
							profile: "glowcap",
						},
						{
							id: "s1",
							t: 100,
							kind: "session-opened",
							sessionId: "alice--bob",
							a: attachedEndpoint("alice"),
							b: attachedEndpoint("bob"),
							codec: "syrup",
							captpVersion: "v1_0",
						},
					],
				}],
			},
		};
		const layout = new KeyframeLayoutSystem(doc, DEFAULT_LAYOUT_CONFIG);
		const kfs = layout.keyframes;
		assert(kfs.length === 2, `expected 2 keyframes; got ${kfs.length}`);
		for (const kf of kfs) {
			const alice = kf.layout.get("alice")!;
			assert(
				alice.x === 300 && alice.y === 200,
				`alice must sit exactly on her pin in every keyframe; got ${JSON.stringify(alice)} at t=${kf.t}`,
			);
		}
		// Bob gains a link to the pin at t=100, his converged position
		// must move between the keyframes (he is NOT pinned).
		const bobBefore = kfs[0]!.layout.get("bob")!;
		const bobAfter = kfs[1]!.layout.get("bob")!;
		assert(
			dist(bobBefore, bobAfter) > 1,
			`bob should re-settle when the topology changes; before=${JSON.stringify(bobBefore)} after=${
				JSON.stringify(bobAfter)
			}`,
		);
	},
);

layoutTest(
	"static-union keyframe holds a pinned peer exactly at its authored position",
	() => {
		const doc: TimelineDocument = {
			id: "pin-static-union-test",
			duration: 1000,
			layoutMode: "static-union",
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
							position: { x: -450, y: 120 },
						},
						{
							id: "j2",
							t: 0,
							kind: "peer-joined",
							peerId: "bob",
							profile: "goblins",
						},
						{
							id: "s1",
							t: 100,
							kind: "session-opened",
							sessionId: "alice--bob",
							a: attachedEndpoint("alice"),
							b: attachedEndpoint("bob"),
							codec: "syrup",
							captpVersion: "v1_0",
						},
					],
				}],
			},
		};
		const layout = new KeyframeLayoutSystem(doc, {
			...DEFAULT_LAYOUT_CONFIG,
			mode: "static-union",
		});
		assert(layout.keyframes.length === 1);
		const kf = layout.keyframes[0]!;
		const alice = kf.layout.get("alice")!;
		assert(
			alice.x === -450 && alice.y === 120,
			`alice must sit exactly on her pin; got ${JSON.stringify(alice)}`,
		);
		const bob = kf.layout.get("bob")!;
		assert(
			bob.x !== -450 || bob.y !== 120,
			`bob must not collapse onto the pin; got ${JSON.stringify(bob)}`,
		);
	},
);

layoutTest(
	"all-pinned doc: per-topology keyframes match authored-mode placement",
	() => {
		const makeDoc = (): TimelineDocument => ({
			id: "all-pinned-test",
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
							position: { x: 140, y: -82 },
						},
						{
							id: "j2",
							t: 0,
							kind: "peer-joined",
							peerId: "bob",
							profile: "goblins",
							position: { x: -210, y: 60 },
						},
						{
							id: "s1",
							t: 100,
							kind: "session-opened",
							sessionId: "alice--bob",
							a: attachedEndpoint("alice"),
							b: attachedEndpoint("bob"),
							codec: "syrup",
							captpVersion: "v1_0",
						},
					],
				}],
			},
		});
		const forced = new KeyframeLayoutSystem(
			makeDoc(),
			DEFAULT_LAYOUT_CONFIG,
		);
		const authored = new KeyframeLayoutSystem(makeDoc(), {
			...DEFAULT_LAYOUT_CONFIG,
			mode: "authored",
		});
		const reference = authored.keyframes[0]!.layout;
		assert(forced.keyframes.length > 0);
		for (const kf of forced.keyframes) {
			for (const [peerId, pos] of kf.layout) {
				const expected = reference.get(peerId)!;
				assert(
					pos.x === expected.x && pos.y === expected.y,
					`${peerId} must match authored placement; got ${JSON.stringify(pos)} expected ${
						JSON.stringify(expected)
					} at t=${kf.t}`,
				);
			}
		}
	},
);

layoutTest(
	"all-pinned recomputeForPlacement stays cheap under many iterations",
	() => {
		// Every peer is pinned: the solver must not spend `iterations`
		// ticks moving nothing. A cold anneal at 5000 ticks on a small
		// all-pinned graph is tens of milliseconds; the pin-only path
		// is a map copy. The bound is loose. It fails when
		// someone removes the all-pinned short-circuit, not when a
		// machine is briefly busy.
		const joins: Array<{
			id: string;
			t: number;
			kind: "peer-joined";
			peerId: string;
			profile: string;
			position: { x: number; y: number };
		}> = [];
		for (let i = 0; i < 20; i += 1) {
			joins.push({
				id: `j${i}`,
				t: 0,
				kind: "peer-joined",
				peerId: `p${i}`,
				profile: "glowcap",
				position: { x: i * 40, y: (i % 5) * 40 },
			});
		}
		const sessions = [];
		for (let i = 0; i < 19; i += 1) {
			sessions.push({
				id: `s${i}`,
				t: 0,
				kind: "session-opened" as const,
				sessionId: `s${i}`,
				a: attachedEndpoint(`p${i}`),
				b: attachedEndpoint(`p${i + 1}`),
				codec: "syrup" as const,
				captpVersion: "v1_0" as const,
			});
		}
		const doc = {
			id: "all-pinned-cheap",
			duration: 1000,
			recording: {
				sources: [{
					id: "fixture",
					meta: { kind: "fixture" },
					observations: [...joins, ...sessions],
				}],
			},
		} as unknown as TimelineDocument;
		const layout = new KeyframeLayoutSystem(doc, {
			...DEFAULT_LAYOUT_CONFIG,
			iterations: 5000,
		});
		const t0 = performance.now();
		for (let i = 0; i < 30; i += 1) {
			const join = joins[i % 20]!;
			join.position = { x: join.position.x + 3, y: join.position.y };
			layout.recomputeForPlacement();
		}
		const elapsed = performance.now() - t0;
		assert(
			elapsed < 200,
			`all-pinned recompute spent ${elapsed.toFixed(1)}ms over 30 drags; expected the pin-only path`,
		);
	},
);

layoutTest(
	"pinning a peer in place does not anneal free eras",
	() => {
		// The old placement path cold-solved every era, then threw the result away
		// via reuseIfEquilibrium when the pin sat where the era already had the
		// peer. With a handful of free eras and a high iteration count that
		// throwaway was tens of milliseconds per drag; checking equilibrium
		// before runForce makes the same gesture a map copy.
		const observations: unknown[] = [];
		for (let i = 0; i < 8; i += 1) {
			observations.push({
				id: `j${i}`,
				t: i * 50,
				kind: "peer-joined",
				peerId: `p${i}`,
				profile: "glowcap",
			});
		}
		for (let i = 0; i < 7; i += 1) {
			observations.push({
				id: `s${i}`,
				t: i * 50 + 1,
				kind: "session-opened",
				sessionId: `s${i}`,
				a: attachedEndpoint(`p${i}`),
				b: attachedEndpoint(`p${i + 1}`),
				codec: "syrup",
				captpVersion: "v1_0",
			});
		}
		const doc = {
			id: "pin-in-place-cheap",
			duration: 1000,
			recording: {
				sources: [{
					id: "fixture",
					meta: { kind: "fixture" },
					observations,
				}],
			},
		} as unknown as TimelineDocument;
		const layout = new KeyframeLayoutSystem(doc, {
			...DEFAULT_LAYOUT_CONFIG,
			iterations: 4000,
		});
		const at = layout.keyframes[0]!.layout.get("p0");
		assert(at !== undefined, "p0 should have a solved position");
		// Seed the pin at the solved point once so subsequent placement edits
		// are "pin here" rather than first-time pins.
		const joins = observations.filter((o) => (o as { kind: string }).kind === "peer-joined") as Array<
			{ peerId: string; position?: { x: number; y: number } }
		>;
		const p0 = joins.find((j) => j.peerId === "p0")!;
		p0.position = { x: at.x, y: at.y };
		layout.recomputeForPlacement();
		const t0 = performance.now();
		for (let i = 0; i < 25; i += 1) {
			p0.position = { x: at.x, y: at.y };
			layout.recomputeForPlacement();
		}
		const elapsed = performance.now() - t0;
		assert(
			elapsed < 500,
			`pin-in-place spent ${elapsed.toFixed(1)}ms over 25 edits; ` +
				`free eras were probably annealed then discarded`,
		);
	},
);
