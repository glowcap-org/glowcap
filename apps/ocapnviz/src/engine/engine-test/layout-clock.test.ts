import { assert, assertEquals } from "@std/assert";
import { TimelineDocument, type TimelineEvent } from "../timeline.ts";
import { Engine } from "../engine.ts";
import { observationsOf, primaryObservations } from "../temporal/recording-access.ts";
import {
	claimTargets,
	computeMessageTimeBundles,
	computeSessionBundles,
	EMPTY_FRAME_GEOMETRY,
} from "../session-geometry.ts";
import { engineTest } from "./harness.ts";
import { doc } from "./fixtures.ts";

// ──────────── What playback is allowed to recompute ────────────
//
// The keyframes are a pure function of the document, so playing a document
// nobody edits must not re-derive them. The recompute is not triggered by
// the set of peers and sessions present in the world AT `t`, which changes on
// any frame where something comes into view: a document whose sessions arrive
// steadily would run one d3-force convergence per era per arrival and throw
// away keyframes identical to the ones it already had. On a hand-built
// document that is three quarters of the frame.
//
// Both halves are held here, because either one alone can be satisfied by a
// broken engine: never recomputing makes live mode's later peers land at their
// seed position forever, and always recomputing is the defect above.
//
// The assertion is object identity on the keyframes array rather than a frame
// budget. `recompute` replaces the array, so identity answers "did it run"
// exactly, on any machine, in any build, where a millisecond budget would
// pass on a tree that had doubled the cost and fail on a busy laptop.
//
// Validated by injection, one per half, because a pair that passes on a
// healthy tree has shown nothing: recomputing unconditionally (the original
// defect) fails the first test, and dropping the recompute altogether fails
// the second. What this pair does NOT reach: it says nothing about how much a
// recompute costs. The seek path shares the document-changed recompute gate
// with playback (`#doSeek`); the live-arrival seek case below holds that half.
// `scripts/playwright-masterpiece-cost-probe.ts` is the instrument for the
// cost itself, and it is not a check, it needs a CPU throttle to
// mean anything, which trades away machine independence.

engineTest("playing an unedited document never recomputes the layout", () => {
	// Peers and sessions that arrive across the timeline rather than all at
	// t=0: entities appearing mid-playback are the condition that would
	// trigger a recompute, so a document where everything exists from the
	// start would pass this test without exercising it.
	const staggered = TimelineDocument.parse({
		id: "staggered",
		duration: 4000,
		events: [
			{
				id: "p1",
				t: 0,
				kind: "peer-joined",
				peerId: "a",
				profile: "glowcap",
			},
			{
				id: "p2",
				t: 500,
				kind: "peer-joined",
				peerId: "b",
				profile: "glowcap",
			},
			{
				id: "s1",
				t: 800,
				kind: "session-opened",
				sessionId: "s-ab",
				a: { peer: "a" },
				b: { peer: "b" },
				codec: "syrup",
				captpVersion: "v1_0",
				initialState: "open",
			},
			{
				id: "p3",
				t: 1500,
				kind: "peer-joined",
				peerId: "c",
				profile: "goblins",
			},
			{
				id: "s2",
				t: 2000,
				kind: "session-opened",
				sessionId: "s-bc",
				a: { peer: "b" },
				b: { peer: "c" },
				codec: "capnp",
				captpVersion: "v1_0",
				initialState: "open",
			},
			{ id: "p4", t: 3000, kind: "peer-left", peerId: "a" },
		],
	});
	const e = new Engine(staggered);
	const atConstruction = e.layout.keyframes;
	e.clock.play();
	// Step rather than jump, so every arrival above is crossed by a tick that
	// materializes the world across it. One big tick would skip the frames
	// where the topology changes, which is where the defect lived.
	for (let i = 0; i < 40; i++) e.tick(100);
	assert(
		e.layout.keyframes === atConstruction,
		"playing a document nobody edited re-derived its keyframes",
	);
	// The staggered arrivals really were crossed, otherwise the assertion
	// above is vacuous and would keep passing if the trigger came back.
	assert(e.clock.t >= 3000, "the clock did not reach the last arrival");
	assert(
		atConstruction.length > 1,
		"this document should have produced several eras to re-derive",
	);
});

engineTest(
	"a live observation arriving mid-playback recomputes the layout",
	() => {
		const live = TimelineDocument.parse({
			id: "live",
			duration: 60_000,
			recording: {
				sources: [{
					id: "feed",
					meta: { kind: "fixture" },
					observations: [
						{
							id: "o1",
							t: 10,
							kind: "peer-joined",
							peerId: "a",
							profile: "glowcap",
						},
					],
				}],
			},
		});
		const e = new Engine(live);
		e.clock.play();
		e.tick(50);
		const beforeArrival = e.layout.keyframes;
		// What a feed does: append in place, leaving the document object identical.
		// Projection is what notices, which is why the recompute hangs off it.
		primaryObservations(e.doc).push({
			id: "o2",
			t: e.clock.t + 1,
			kind: "peer-joined",
			peerId: "b",
			profile: "goblins",
		});
		e.tick(50);
		assert(
			e.layout.keyframes !== beforeArrival,
			"a peer that arrived live never reached a keyframe",
		);
		const placed = e.layout.keyframes.at(-1)?.layout.get("b");
		assert(
			placed !== undefined,
			"the live peer has no position in any keyframe",
		);
	},
);

engineTest(
	"seeking an unedited document never recomputes the layout",
	() => {
		const e = new Engine(TimelineDocument.parse({
			id: "quiet-seek",
			duration: 1000,
			events: [{
				id: "p1",
				t: 0,
				kind: "peer-joined",
				peerId: "a",
				profile: "glowcap",
			}],
		}));
		const beforeSeek = e.layout.keyframes;
		e.seekTo(Math.min(100, e.doc.duration));
		assert(
			e.layout.keyframes === beforeSeek,
			"an ordinary seek re-derived unchanged keyframes",
		);
	},
);

engineTest(
	"seeking after a live observation recomputes the layout",
	() => {
		const live = TimelineDocument.parse({
			id: "live-seek",
			duration: 60_000,
			recording: {
				sources: [{
					id: "feed",
					meta: { kind: "fixture" },
					observations: [
						{
							id: "o1",
							t: 10,
							kind: "peer-joined",
							peerId: "a",
							profile: "glowcap",
						},
					],
				}],
			},
		});
		const e = new Engine(live);
		e.clock.pause();
		e.seekTo(50);
		const beforeArrival = e.layout.keyframes;
		primaryObservations(e.doc).push({
			id: "o2",
			t: 100,
			kind: "peer-joined",
			peerId: "b",
			profile: "goblins",
		});
		e.seekTo(150);
		assert(
			e.layout.keyframes !== beforeArrival,
			"seek after a live arrival never rebuilt keyframes",
		);
		assert(
			e.layout.keyframes.at(-1)?.layout.get("b") !== undefined,
			"the live peer has no position after seek",
		);
	},
);

// ──────── What a playing clock is allowed to wake ────────
//
// `version` promises to catch any mutation, so it moves on every frame of
// playback and a panel subscribed to it re-renders at the frame rate. That is
// the right contract for a consumer following the world. It is the wrong one
// for a panel showing what the document says, its source, its title, whether
// an id is taken, and those panels were paying it.
//
// `docVersion` is the narrower fact. The assertion is a count rather than a
// duration for the same reason as the keyframes above: it holds on any machine
// and in any build, and it names the work instead of its price.
//
// Validated by injection: bumping `#docVersion` unconditionally in `#notify`
// fails the first test, and never bumping it fails the second. What this pair
// does NOT reach: it says nothing about which components subscribe to which,
// so a panel switched back to `useEngineVersion` would not fail here.

engineTest("a playing clock does not move the document version", () => {
	const e = new Engine(structuredClone(doc));
	const before = e.docVersion;
	const versionBefore = e.version;
	e.clock.play();
	for (let i = 0; i < 30; i++) e.tick(50);
	assertEquals(
		e.docVersion,
		before,
		"playback moved the document version, so document-shaped panels re-render per frame",
	);
	// The ticks really did wake subscribers, or the assertion above is vacuous.
	assert(
		e.version > versionBefore,
		"playback notified nobody, so this test proves nothing",
	);
});

engineTest("editing the document moves the document version", () => {
	const e = new Engine(structuredClone(doc));
	const before = e.docVersion;
	e.dispatch({
		kind: "reposition-peer",
		peerId: "a",
		position: { x: 42, y: 42 },
	});
	assert(
		e.docVersion > before,
		"an edit left the document version behind, so a panel would show stale state",
	);
});

engineTest("a live observation moves the document version", () => {
	const live = TimelineDocument.parse({
		id: "live-docversion",
		duration: 60_000,
		recording: {
			sources: [{
				id: "feed",
				meta: { kind: "fixture" },
				observations: [
					{
						id: "o1",
						t: 10,
						kind: "peer-joined",
						peerId: "a",
						profile: "glowcap",
					},
				],
			}],
		},
	});
	const e = new Engine(live);
	e.clock.play();
	e.tick(50);
	const before = e.docVersion;
	primaryObservations(e.doc).push({
		id: "o2",
		t: e.clock.t + 1,
		kind: "peer-joined",
		peerId: "b",
		profile: "goblins",
	});
	e.tick(50);
	assert(
		e.docVersion > before,
		"a peer that arrived live never moved the document version",
	);
});

// ──────── Frame geometry shared once per stage update ────────
//
// Flight and the Stage projection share one `claimTargets` /
// `computeSessionBundles` result, and flight does not rebuild time bundles
// every tick because those are observation-stable. The engine owns one
// `frameGeometry` per stage pass. Validated by injection: rebuilding
// time bundles every `#runStageSystems` fails the identity test; leaving
// Stage to compute its own session bundles would not fail these, but the
// render path takes `engine.frameGeometry` by construction.

engineTest(
	"frameGeometry matches an independent claim/bundle resolution",
	() => {
		const e = new Engine(structuredClone(doc));
		e.seekTo(1000);
		const g = e.frameGeometry;
		const toward = claimTargets(e.world, e.claims);
		assertEquals([...g.claimsToward.entries()], [...toward.entries()]);
		assertEquals(
			[...g.sessionBundles.entries()],
			[...computeSessionBundles(e.world, toward).entries()],
		);
	},
);

engineTest(
	"message time bundles keep identity across playback ticks",
	() => {
		const e = new Engine(structuredClone(doc));
		e.clock.play();
		e.tick(50);
		const first = e.frameGeometry.timeBundles;
		for (let i = 0; i < 20; i++) e.tick(50);
		assert(
			e.frameGeometry.timeBundles === first,
			"playback rebuilt time bundles every tick",
		);
		// The cached map is still the right answer, not a stale empty.
		assertEquals(
			[...first.entries()],
			[
				...computeMessageTimeBundles(
					observationsOf(e.doc) as readonly TimelineEvent[],
				).entries(),
			],
		);
	},
);

engineTest(
	"pair tables keep identity across playback ticks without topology change",
	() => {
		// Between t=0 and the first message at t=1000 the standing set is
		// stable, so claim/bundle maps must not be rebuilt every frame.
		const e = new Engine(structuredClone(doc));
		e.clock.play();
		e.tick(50);
		const claims = e.frameGeometry.claimsToward;
		const bundles = e.frameGeometry.sessionBundles;
		for (let i = 0; i < 10; i++) e.tick(50);
		assert(
			e.frameGeometry.claimsToward === claims,
			"playback rebuilt claim targets while membership was stable",
		);
		assert(
			e.frameGeometry.sessionBundles === bundles,
			"playback rebuilt session bundles while membership was stable",
		);
		// Curves depend on positions and are rebuilt every stage pass.
		assert(
			e.frameGeometry.sessionCurves !==
				EMPTY_FRAME_GEOMETRY.sessionCurves,
			"session curves were never built",
		);
	},
);

engineTest(
	"seek after a document edit rebuilds message time bundles",
	() => {
		const e = new Engine(structuredClone(doc));
		const before = e.frameGeometry.timeBundles;
		e.dispatch({
			kind: "reposition-peer",
			peerId: "a",
			position: { x: 7, y: 7 },
		});
		// Seek is the path that must not trust a pre-edit table: authoring
		// rewrites observations in place and then seeks.
		e.seekTo(e.clock.t);
		assert(
			e.frameGeometry.timeBundles !== before,
			"a seek after an edit kept the previous time-bundle map",
		);
	},
);

engineTest(
	"retiming a message updates time-bundle contents after seek",
	() => {
		// Authoring rewrites observations in place and seeks. `#doSeek`
		// always allocates a new map; this pins that the new map reflects
		// the rewritten observation. Injection: keep computing time bundles
		// from a cloned pre-move event list and this fails.
		const e = new Engine(structuredClone(doc));
		e.dispatch({
			kind: "move-event",
			move: { kind: "resize-end", eventId: "e4", newArrivalT: 2200 },
		});
		const rebuilt = e.frameGeometry.timeBundles;
		const expected = computeMessageTimeBundles(
			observationsOf(e.doc) as readonly TimelineEvent[],
		);
		assertEquals([...rebuilt.entries()], [...expected.entries()]);
	},
);
