/**
 * What an era is, and what a recompute may reuse.
 *
 * These cover the three properties the per-topology layout rests on, each of
 * which was broken in a way nothing else noticed:
 *
 *   1. An era describes the moment it is stamped at. The node set used to be
 *      folded forward across the walk, and a session's departure did not remove
 *      the ends its arrival added, so every closed session left a body in every
 *      later era — a free node with charge and a footprint, seeded at the origin
 *      with nothing standing there. A live room that reconnects every few
 *      seconds accumulated one per reconnect for as long as anyone watched.
 *   2. Two moments presenting the solver the same problem are one era. While the
 *      node set grew forever this could never fire, because no two eras were
 *      ever equal.
 *   3. An era is a pure function of its moment, so a recompute may reuse the
 *      arrangement it already holds for a moment whose problem is unchanged.
 *
 * Validated by injection, one per property: accumulating the node set again
 * fails the first two, and dropping the reuse lookup fails the third. The pin
 * and claim cases are covered by `engine-test/` and
 * `claim-placement-test/`, which caught a first version of the reuse whose key
 * left them out.
 *
 * Not covered: the era count still grows by two per reconnect, because each one
 * really is two topology moments. That is a cost, not a wrong picture, and
 * `docs/era-collapse.md` records why no threshold was added for it.
 */

import { assert, assertEquals } from "@std/assert";
import { TimelineDocument, type TimelineEvent } from "../timeline.ts";
import { Engine } from "../engine.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import { attachedEndpoint, unattributedEndpoint } from "../../schema/session-end.ts";

function engineTest(name: string, fn: () => void): void {
	Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

/** A room: two peers that stay, and one session between them. */
function roomEngine(): Engine {
	const doc = TimelineDocument.parse({
		id: "room",
		duration: 600_000,
		recording: {
			sources: [{
				id: "feed",
				meta: { kind: "fixture" },
				observations: [
					{
						id: "p1",
						t: 5,
						kind: "peer-joined",
						peerId: "rooms",
						profile: "glowcap",
					},
					{
						id: "p2",
						t: 6,
						kind: "peer-joined",
						peerId: "alice",
						profile: "glowcap",
					},
					{
						id: "s0",
						t: 7,
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
	});
	const e = new Engine(doc);
	e.clock.play();
	for (let i = 0; i < 40; i++) e.tick(100);
	return e;
}

/** Two eras far enough apart that the first finishes easing before the second
 *  begins. The second holds a session with a loose far end, which is a node of
 *  its own and so is something a reader can drag. */
function twoEraEngine(): Engine {
	const doc = TimelineDocument.parse({
		id: "two",
		duration: 20_000,
		recording: {
			sources: [{
				id: "feed",
				meta: { kind: "fixture" },
				observations: [
					{
						id: "p1",
						t: 0,
						kind: "peer-joined",
						peerId: "a",
						profile: "glowcap",
					},
					{
						id: "p2",
						t: 0,
						kind: "peer-joined",
						peerId: "b",
						profile: "glowcap",
					},
					{
						id: "s0",
						t: 0,
						kind: "session-opened",
						sessionId: "s0",
						a: attachedEndpoint("a"),
						b: attachedEndpoint("b"),
						codec: "syrup",
						captpVersion: "v1_0",
						initialState: "open",
					},
					{
						id: "s1",
						t: 5000,
						kind: "session-opened",
						sessionId: "s1",
						a: attachedEndpoint("a"),
						b: unattributedEndpoint("carol"),
						codec: "syrup",
						captpVersion: "v1_0",
						initialState: "open",
					},
				],
			}],
		},
	});
	return new Engine(doc);
}

/** One reconnect: a session opens with a loose far end and closes again, under a
 *  fresh id, which is what the live feed does every few seconds. */
function reconnect(e: Engine, round: number): void {
	primaryObservations(e.doc).push({
		id: `o${round}`,
		t: e.clock.t + 1,
		kind: "session-opened",
		sessionId: `live-s${round}`,
		a: attachedEndpoint("rooms"),
		b: unattributedEndpoint("goblins-carol"),
		codec: "syrup",
		captpVersion: "v1_0",
		initialState: "open",
	} as TimelineEvent);
	e.tick(16);
	primaryObservations(e.doc).push({
		id: `c${round}`,
		t: e.clock.t + 1,
		kind: "session-closed",
		sessionId: `live-s${round}`,
	} as TimelineEvent);
	// Past the transition window, so any easing has finished either way.
	for (let i = 0; i < 10; i++) e.tick(100);
}

/** The largest node set any era holds. The property is that no era's set grows,
 *  and an accumulation that has drained by the last era would hide from a check
 *  that only read the tail. */
const widestEra = (e: Engine): number => {
	let widest = 0;
	for (const kf of e.layout.keyframes) {
		if (kf.layout.size > widest) widest = kf.layout.size;
	}
	return widest;
};

const positions = (e: Engine): Map<string, string> => {
	const m = new Map<string, string>();
	for (const p of e.world.with("peer", "position")) {
		m.set(
			p.peer.id,
			`${p.position.x.toFixed(3)},${p.position.y.toFixed(3)}`,
		);
	}
	return m;
};

engineTest("a closed session leaves no node behind", () => {
	// While a reconnect's session stands, its loose end is a node, and the era
	// covering that moment holds it — that is the picture being right. What must
	// not happen is the count growing with the number of reconnects, which is what
	// it did while the set was folded forward: one body per session ever opened,
	// piled at the origin, pushing the room outward a little further each time.
	const e = roomEngine();
	reconnect(e, 0);
	const afterOne = widestEra(e);
	for (let round = 1; round < 8; round++) reconnect(e, round);
	assertEquals(
		widestEra(e),
		afterOne,
		"the widest era grew with the number of reconnects, so closed sessions are still leaving bodies behind",
	);
});

engineTest("a reconnect leaves every peer where it was", () => {
	const e = roomEngine();
	for (let round = 0; round < 6; round++) {
		const before = positions(e);
		reconnect(e, round);
		const after = positions(e);
		for (const [id, at] of after) {
			assertEquals(
				at,
				before.get(id),
				`peer ${id} moved across reconnect ${round}`,
			);
		}
	}
});

engineTest(
	"a moment that changes nothing the solver reads is not an era",
	() => {
		const e = roomEngine();
		const before = e.layout.keyframes.length;
		// A session whose range is empty never stands anywhere, so the moment it
		// arrives at presents the solver exactly the problem the era before it did.
		primaryObservations(e.doc).push({
			id: "empty-open",
			t: e.clock.t + 1,
			kind: "session-opened",
			sessionId: "empty",
			a: attachedEndpoint("rooms"),
			b: attachedEndpoint("alice"),
			codec: "syrup",
			captpVersion: "v1_0",
			initialState: "open",
		} as TimelineEvent);
		primaryObservations(e.doc).push({
			id: "empty-close",
			t: e.clock.t + 1,
			kind: "session-closed",
			sessionId: "empty",
		} as TimelineEvent);
		e.tick(50);
		assertEquals(
			e.layout.keyframes.length,
			before,
			"a session that never stands anywhere still minted an era",
		);
	},
);

engineTest("a recompute reuses the arrangement it already holds", () => {
	const e = roomEngine();
	const held = e.layout.keyframes.map((kf) => kf.layout);
	assert(held.length > 0, "no eras to reuse, so this proves nothing");
	reconnect(e, 0);
	const after = e.layout.keyframes;
	assert(
		after.length > held.length,
		"the reconnect should have added eras, or reuse is being measured against nothing",
	);
	// Identity, not equality: a reused era is the same object, so no solve ran.
	for (let i = 0; i < held.length; i++) {
		assert(
			after[i]!.layout === held[i]!,
			`era ${i} was re-annealed even though its problem did not change`,
		);
	}
});

engineTest("a second session on the same pair is its own era", () => {
	// The other side of the dedup, and the case a first version of the key got
	// wrong. `bundleIndices` sorts the ids sharing a pair and indexes by position,
	// so which lane a session rides depends on which ids are on that pair. Two
	// eras carrying the same pairs under different ids are different problems, and
	// collapsing them left a claim leaning on a lane its arc was not drawn along.
	const e = roomEngine();
	const before = e.layout.keyframes.length;
	// A second wire between the peers that already have one: same pair, new id.
	primaryObservations(e.doc).push({
		id: "second-open",
		t: e.clock.t + 1,
		kind: "session-opened",
		sessionId: "second",
		a: attachedEndpoint("rooms"),
		b: attachedEndpoint("alice"),
		codec: "syrup",
		captpVersion: "v1_0",
		initialState: "open",
	} as TimelineEvent);
	for (let i = 0; i < 4; i++) e.tick(100);
	assert(
		e.layout.keyframes.length > before,
		"a second lane between the same pair was collapsed into the era before it",
	);
});

engineTest("swapping which ids share a pair is its own era", () => {
	// Sharper than the case above: the pair multiset is unchanged and only the ids
	// move, which is exactly what the key used to drop.
	const e = roomEngine();
	primaryObservations(e.doc).push({
		id: "aaa-open",
		t: e.clock.t + 1,
		kind: "session-opened",
		sessionId: "aaa",
		a: attachedEndpoint("rooms"),
		b: attachedEndpoint("alice"),
		codec: "syrup",
		captpVersion: "v1_0",
		initialState: "open",
	} as TimelineEvent);
	for (let i = 0; i < 4; i++) e.tick(100);
	const before = e.layout.keyframes.length;
	// In one moment: `aaa` leaves the pair and `zzz` takes its place. Same pairs,
	// different ids, so a different lane order.
	const at = e.clock.t + 1;
	primaryObservations(e.doc).push({
		id: "aaa-close",
		t: at,
		kind: "session-closed",
		sessionId: "aaa",
	} as TimelineEvent);
	primaryObservations(e.doc).push({
		id: "zzz-open",
		t: at,
		kind: "session-opened",
		sessionId: "zzz",
		a: attachedEndpoint("rooms"),
		b: attachedEndpoint("alice"),
		codec: "syrup",
		captpVersion: "v1_0",
		initialState: "open",
	} as TimelineEvent);
	for (let i = 0; i < 4; i++) e.tick(100);
	assert(
		e.layout.keyframes.length > before,
		"an era whose pairs are carried by different session ids was collapsed away",
	);
});

engineTest("a reconnect does not throw the room and pull it back", () => {
	// The excursion, not the destination. Every case above settles before it looks,
	// so all of them passed while a reconnect was still visibly re-animating the
	// room into place: the ease started from the arrangement of an era that had
	// been replaced two milliseconds after it arrived, so the picture jumped to it
	// in one frame and eased back out over the transition window.
	//
	// Sampled every frame across a reconnect, which is where the excursion lives.
	const e = roomEngine();
	const settled = positions(e);
	let worst = 0;
	let worstAt = "";
	primaryObservations(e.doc).push({
		id: "flick-open",
		t: e.clock.t + 1,
		kind: "session-opened",
		sessionId: "flick",
		a: attachedEndpoint("rooms"),
		b: unattributedEndpoint("goblins-carol"),
		codec: "syrup",
		captpVersion: "v1_0",
		initialState: "open",
	} as TimelineEvent);
	e.tick(2);
	primaryObservations(e.doc).push({
		id: "flick-close",
		t: e.clock.t + 1,
		kind: "session-closed",
		sessionId: "flick",
	} as TimelineEvent);
	// One frame at a time, right through the 600ms window and out the far side.
	for (let frame = 0; frame < 60; frame++) {
		e.tick(16);
		for (const [id, at] of positions(e)) {
			const was = settled.get(id);
			if (was === undefined || at === was) continue;
			const from = was.split(",").map(Number) as [number, number];
			const to = at.split(",").map(Number) as [number, number];
			const d = Math.hypot(to[0] - from[0], to[1] - from[1]);
			if (d > worst) {
				worst = d;
				worstAt = `${id} at frame ${frame}`;
			}
		}
	}
	// A node body is 60 world units across. A peer that never leaves a tenth of
	// its own width has not visibly moved.
	assert(
		worst < 6,
		`a reconnect moved ${worstAt} by ${worst.toFixed(1)} world units mid-transition`,
	);
});

engineTest("a placement edit leaves an era easing from where it began", () => {
	// `recomputeForPlacement` hands an era back the arrangement it already held
	// whenever the edit did not disturb it. What it must not hand back is that
	// arrangement as the era's ease ORIGIN: an era whose start is its own layout
	// sits at its target on its own first frame, which is a snap. Reusing a
	// layout does not make an era a first era, and what an era eases from is a
	// property of its place in the list rather than of the era itself.
	//
	// Dragging a loose end reaches this: the pin names a node the FIRST era does
	// not contain, so that era reuses unconditionally, while the second reuses
	// because the pin matches where it already had the end. Both keep their
	// arrangements, and those arrangements differ — the second era draws a
	// session the first does not.
	const e = twoEraEngine();
	const before = e.layout.keyframes;
	assertEquals(before.length, 2, "the fixture should state two eras");
	const looseAt = before[1]!.layout.get("s1::b");
	assert(looseAt !== undefined, "the second era should hold the loose end");
	assert(
		!before[0]!.layout.has("s1::b"),
		"the first era should not hold it, or both eras answer the pin",
	);

	e.repositionEndpoint("s1::b", { x: looseAt.x, y: looseAt.y });

	const after = e.layout.keyframes;
	assertEquals(after.length, 2, "the edit should not change the era count");
	const [first, second] = [after[0]!, after[1]!];

	// The eras have to differ, or there is nothing for an ease to cross and this
	// case proves nothing.
	const spread = widestGap(first.layout, second.layout);
	assert(
		spread > 20,
		`the two eras differ by only ${spread.toFixed(1)} units`,
	);

	// The first era ran 5000ms, far past the 600ms window, so it finished: the
	// arrangement the second era opens on is exactly the first era's.
	const off = widestGap(first.layout, second.start);
	assert(
		off < 1,
		`the reused era eases from ${off.toFixed(1)} world units away from where ` +
			`the picture actually was, so it snaps instead of easing`,
	);
});

/** The furthest any node named in both arrangements sits from itself. */
function widestGap(
	a: ReadonlyMap<string, { x: number; y: number }>,
	b: ReadonlyMap<string, { x: number; y: number }>,
): number {
	let worst = 0;
	for (const [id, at] of b) {
		const was = a.get(id);
		if (was === undefined) continue;
		worst = Math.max(worst, Math.hypot(at.x - was.x, at.y - was.y));
	}
	return worst;
}

engineTest("ending a peer's life takes it out of every later era", () => {
	// An era's membership is asked of the effective ranges, and those do not
	// follow from the topology moments: an Inspector edit that ends a peer
	// rewrites its stored timing and moves no observation. So every other part of
	// the recompute key stays put while the peer stops standing anywhere, and the
	// layout has to notice on its own.
	//
	// Left unnoticed, the peer keeps its place in every later era's solve — a body
	// with charge and a footprint at a spot the stage draws nothing, which is the
	// same defect the accumulating node set had, reached from the other side.
	const e = twoEraEngine();
	const later = e.layout.keyframes.find((k) => k.t === 5000);
	assert(later !== undefined, "the fixture should state an era at t=5000");
	assert(later.layout.has("b"), "that era should hold b to begin with");

	e.setPeerEnd("b", 1000);

	const afterward = e.layout.keyframes.find((k) => k.t === 5000);
	assert(afterward !== undefined, "the era should survive the edit");
	assert(
		!afterward.layout.has("b"),
		"a peer whose life ended before this era still had a place in its solve",
	);
	// The world is the authority for what stands at a moment, so the two agree.
	e.seekTo(5000);
	const drawn = [...e.world.with("peer", "position")].some((x) => x.peer.id === "b");
	assertEquals(drawn, false, "the world drew a peer whose life had ended");
});
