/**
 * Era sealing and the recompute signature, without going through the solver.
 *
 * `era-reuse.test.ts` proves the same start-arrangement through Engine ticks.
 * These ask `sealEras` and `layoutInputSignature` themselves, so a start that
 * snapped or a signature that ignored an Inspector end would fail here even
 * if the anneal happened to hide it.
 */

import { assertEquals } from "@std/assert";
import { attachedEndpoint } from "../../schema/session-end.ts";
import { claimedPeerByEnd } from "../claims.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import { projectFromObservations } from "../temporal/project-from-observations.ts";
import { TimelineDocument } from "../timeline.ts";
import { DEFAULT_LAYOUT_CONFIG, findActiveKeyframe, layoutInputSignature, sealEras } from "./layout-eras.ts";

const linear = {
	...DEFAULT_LAYOUT_CONFIG,
	transitionWindow: 600,
	easing: (t: number) => t,
};

Deno.test("the first era opens on its own arrangement", () => {
	const layout = new Map([["alice", { x: 10, y: 20 }]]);
	const [first] = sealEras(
		[{ t: 0, problem: "a", layout }],
		linear,
	);
	assertEquals(first?.start.get("alice"), { x: 10, y: 20 });
});

Deno.test("a short era eases from where the picture actually was", () => {
	const firstLayout = new Map([["alice", { x: 0, y: 0 }]]);
	const secondLayout = new Map([["alice", { x: 600, y: 0 }]]);
	const sealed = sealEras(
		[
			{ t: 0, problem: "a", layout: firstLayout },
			{ t: 150, problem: "b", layout: secondLayout },
		],
		linear,
	);
	// The second era lasted 150 of a 600 ms window, so it starts 25% of the
	// way from the first era's start (its own layout) toward that layout,
	// which is the same point, so the picture has not moved yet. A third era status-allow: pending state or quoted runtime label
	// is what reads that progress.
	assertEquals(sealed[1]?.start.get("alice"), { x: 0, y: 0 });
	const thirdLayout = new Map([["alice", { x: 0, y: 0 }]]);
	const withThird = sealEras(
		[
			{ t: 0, problem: "a", layout: firstLayout },
			{ t: 150, problem: "b", layout: secondLayout },
			{ t: 300, problem: "c", layout: thirdLayout },
		],
		linear,
	);
	// The second era ran 150 ms toward (600, 0) from (0, 0) → (150, 0).
	assertEquals(withThird[2]?.start.get("alice"), { x: 150, y: 0 });
});

Deno.test("a node the previous era did not hold appears at its own place", () => {
	const sealed = sealEras(
		[
			{
				t: 0,
				problem: "a",
				layout: new Map([["alice", { x: 0, y: 0 }]]),
			},
			{
				t: 600,
				problem: "b",
				layout: new Map([
					["alice", { x: 10, y: 0 }],
					["bob", { x: 100, y: 100 }],
				]),
			},
		],
		linear,
	);
	assertEquals(sealed[1]?.start.has("bob"), false);
});

Deno.test("findActiveKeyframe is the latest era that has already begun", () => {
	const sealed = sealEras(
		[
			{ t: 0, problem: "a", layout: new Map() },
			{ t: 100, problem: "b", layout: new Map() },
			{ t: 200, problem: "c", layout: new Map() },
		],
		linear,
	);
	assertEquals(findActiveKeyframe(sealed, -1), undefined);
	assertEquals(findActiveKeyframe(sealed, 0)?.index, 0);
	assertEquals(findActiveKeyframe(sealed, 99)?.index, 0);
	assertEquals(findActiveKeyframe(sealed, 100)?.index, 1);
	assertEquals(findActiveKeyframe(sealed, 250)?.index, 2);
});

function twoPeerDoc(): TimelineDocument {
	return projectFromObservations(TimelineDocument.parse({
		id: "sig",
		duration: 10_000,
		recording: {
			sources: [{
				id: "feed",
				meta: { kind: "fixture" },
				observations: [
					{
						id: "p1",
						t: 0,
						kind: "peer-joined",
						peerId: "rooms",
						profile: "glowcap",
					},
					{
						id: "p2",
						t: 0,
						kind: "peer-joined",
						peerId: "alice",
						profile: "glowcap",
					},
					{
						id: "s0",
						t: 0,
						kind: "session-opened",
						sessionId: "base",
						a: attachedEndpoint("rooms"),
						b: attachedEndpoint("alice"),
						codec: "syrup",
						captpVersion: "v1_0",
						initialState: "open",
					},
				],
			}],
		},
	}));
}

Deno.test("a message does not change the layout input signature", () => {
	const doc = twoPeerDoc();
	const claimed = claimedPeerByEnd(doc);
	const before = layoutInputSignature(doc, claimed);
	primaryObservations(doc).push({
		id: "m1",
		t: 50,
		kind: "message-sent",
		messageId: "m",
		sessionId: "base",
		from: "rooms",
		to: "alice",
		arrivalT: 80,
	});
	assertEquals(layoutInputSignature(doc, claimed), before);
});

Deno.test("an Inspector end rewrite changes the layout input signature", () => {
	const doc = twoPeerDoc();
	const claimed = claimedPeerByEnd(doc);
	const before = layoutInputSignature(doc, claimed);
	const alice = doc.entities!.peers!.alice!;
	alice.timing = {
		start: { value: 0, explicit: false },
		duration: { value: 1000, explicit: true },
	};
	assertEquals(layoutInputSignature(doc, claimed) === before, false);
});
