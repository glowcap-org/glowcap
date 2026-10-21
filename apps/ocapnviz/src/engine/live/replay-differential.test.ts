/**
 * Live and replay must draw the same picture.
 *
 * For one document and one moment there is exactly one right answer, and how
 * a reader arrived at that moment is not part of it. The two arrivals are
 * built differently: Live never rebuilds the world, it reconciles
 * the world it already has as observations arrive. Replay throws the world
 * away and materializes a fresh one at the moment it is asked for. So a status-allow: state at observation
 * reconciler that adds an entity on one test and removes it on another shows
 * up here and nowhere else, as one picture with something in it the other
 * picture does not have.
 *
 * The comparison is over what is DRAWN, not over raw ids, and the two are the
 * same thing here because both engines read the SAME observations. The stage
 * ledger's fresh-incarnation-per-rejoin lives upstream of this: it turns
 * producer records into observations, and by the time an observation exists
 * its stage id is settled. Feeding both paths the already-converted stream is
 * what makes id equality the honest comparison rather than a coincidence.
 *
 * The live engine is given only what has happened by `t`, and the replay
 * engine the whole document. That gap is the point rather than a flaw in the
 * harness: it is what the app does, Live accumulates, and Stop hands the
 * finished recording to Play, so a moment whose picture depends on something
 * that has not happened yet is a moment the two modes disagree status-allow: pending state or quoted runtime label
 * about, and this is where that shows.
 */

import { assertEquals } from "@std/assert";
import { Engine } from "../engine.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import type { TimelineDocument, TimelineEvent } from "../timeline.ts";
import { makeBaseEventConverter } from "./feed.ts";
import { type BaseTimelineEvent } from "./record.ts";

const DURATION_MS = 60_000;

function emptyLiveDoc(): TimelineDocument {
	return {
		id: "live",
		metadata: { "dct:title": "differential" },
		duration: DURATION_MS,
		recording: {
			sources: [{
				id: "live",
				meta: { kind: "glowcap-host" },
				observations: [],
			}],
		},
	};
}

function docWith(events: readonly TimelineEvent[]): TimelineDocument {
	const doc = emptyLiveDoc();
	primaryObservations(doc).push(...events.map((ev) => ({ ...ev })));
	return doc;
}

/** Run the whole stream through a producer-record converter, which is what a
 *  real feed hands the engine. */
function convertAll(records: readonly BaseTimelineEvent[]): TimelineEvent[] {
	const convert = makeBaseEventConverter();
	const out: TimelineEvent[] = [];
	for (const record of records) out.push(...convert(record));
	return out;
}

/**
 * The Live arrival: one engine, playing, with observations appended just
 * before the tick that crosses their moment. The world is never reset.
 */
function driveLive(
	events: readonly TimelineEvent[],
	targetT: number,
	stepMs = 8,
): Engine {
	const engine = new Engine(emptyLiveDoc());
	engine.enqueue({ kind: "play" });
	const pending = [...events].sort((a, b) => a.t - b.t);
	let i = 0;
	while (engine.clock.t < targetT) {
		const next = Math.min(engine.clock.t + stepMs, targetT);
		while (i < pending.length && pending[i]!.t <= next) {
			primaryObservations(engine.doc).push({ ...pending[i]! });
			i++;
		}
		engine.tick(next - engine.clock.t);
	}
	return engine;
}

/** The replay arrival: a fresh engine over the whole document, seeking. */
function driveReplay(
	events: readonly TimelineEvent[],
	targetT: number,
): Engine {
	const engine = new Engine(docWith(events));
	engine.seekTo(targetT);
	return engine;
}

/** Positions are floats produced by the same arithmetic on both paths, so
 *  they compare exactly when the keyframes behind them agree. Rounded only
 *  far below anything a reader could see, to keep an ulp out of the diff. */
function at(p: { x: number; y: number }): string {
	return `${p.x.toFixed(3)},${p.y.toFixed(3)}`;
}

/** Everything the stage draws at this moment, in a form two engines can be
 *  compared on. Sorted, so iteration order is not part of the picture. */
function pictureOf(engine: Engine): {
	peers: string[];
	endpoints: string[];
	sessions: string[];
	messages: string[];
} {
	const peers: string[] = [];
	for (const e of engine.queries.peers) {
		peers.push(
			[
				e.peer.id,
				e.peer.label,
				e.peer.profile,
				e.peer.designator ?? "-",
				at(e.position),
			].join(" "),
		);
	}
	const endpoints: string[] = [];
	for (const e of engine.queries.endpoints) {
		endpoints.push(
			[
				e.endpoint.id,
				e.endpoint.sessionId,
				e.endpoint.side,
				e.endpoint.designator ?? "-",
				at(e.position),
			].join(" "),
		);
	}
	const sessions: string[] = [];
	for (const e of engine.queries.sessions) {
		sessions.push(
			[
				e.session.id,
				e.session.codec,
				e.session.captpVersion,
				e.session.state,
				e.endpoints.a,
				e.endpoints.b,
			].join(" "),
		);
	}
	const messages: string[] = [];
	for (const e of engine.queries.messagesInFlight) {
		messages.push(
			[
				e.messageInFlight.id,
				e.messageInFlight.sessionId,
				e.messageInFlight.from,
				e.messageInFlight.to,
				e.messageInFlight.label ?? "-",
				at(e.position),
			].join(" "),
		);
	}
	return {
		peers: peers.sort(),
		endpoints: endpoints.sort(),
		sessions: sessions.sort(),
		messages: messages.sort(),
	};
}

/** Drive one stream both ways to the same moment and insist on one picture. */
function assertSamePicture(
	what: string,
	events: readonly TimelineEvent[],
	targetT: number,
): void {
	const live = pictureOf(driveLive(events, targetT));
	const replay = pictureOf(driveReplay(events, targetT));
	assertEquals(live, replay, `${what}: live and replay drew two pictures`);
}

// ── shapes ──

const open = (
	session: string,
	a: string,
	b: string,
	t_ns: number,
	extra: Partial<BaseTimelineEvent> = {},
): BaseTimelineEvent => ({
	v: 1,
	sim_t_ns: t_ns,
	kind: "ocapn.session-opened",
	transport: "tcp",
	captp_version: "1.0",
	session,
	a,
	b,
	codec: "syrup",
	...extra,
});

const close = (session: string, t_ns: number): BaseTimelineEvent => ({
	v: 1,
	sim_t_ns: t_ns,
	kind: "ocapn.session-closed",
	session,
});

const wire = (seed: string): string => seed.repeat(64).slice(0, 64);

Deno.test("differential: a session opening and closing", () => {
	const events = convertAll([
		open("s1", "rooms", "bob", 100_000_000),
		close("s1", 400_000_000),
	]);
	for (const t of [50, 200, 350, 500, 900]) {
		assertSamePicture(`session lifecycle at t=${t}`, events, t);
	}
});

Deno.test("differential: a peer that returns after leaving", () => {
	const events = convertAll([
		open("s1", "rooms", "bob", 100_000_000),
		close("s1", 300_000_000),
		open("s2", "rooms", "bob", 500_000_000),
	]);
	for (const t of [200, 400, 600, 900]) {
		assertSamePicture(`peer rejoin at t=${t}`, events, t);
	}
});

Deno.test("differential: an end nothing has attributed", () => {
	const events = convertAll([
		open("p1/s1", "rooms", "127.0.0.1:0", 100_000_000, {
			provenance: "unauthenticated",
			session_id: wire("a"),
		}),
		close("p1/s1", 500_000_000),
	]);
	for (const t of [200, 400, 600, 900]) {
		assertSamePicture(`loose end at t=${t}`, events, t);
	}
});

Deno.test("differential: a loose end learning who is on it", () => {
	const events = convertAll([
		open("p1/s1", "rooms", "127.0.0.1:0", 100_000_000, {
			provenance: "unauthenticated",
			session_id: wire("b"),
		}),
		open("p2/s1", "tab-key", "rooms", 300_000_000, {
			session_id: wire("b"),
		}),
		close("p1/s1", 700_000_000),
		close("p2/s1", 700_000_000),
	]);
	for (const t of [200, 400, 600, 800]) {
		assertSamePicture(`attribution at t=${t}`, events, t);
	}
});

Deno.test("differential: an end attributed to a peer already on stage", () => {
	// The attribution arrives with no peer arriving beside it, so nothing about
	// the peer or session id set changes at that moment. What changes is which
	// node the wire ends on, and the picture has to move with it either way it
	// is reached.
	const events = convertAll([
		open("p1/room", "rooms", "alice-key", 100_000_000, {
			session_id: wire("c"),
		}),
		open("p2/room", "bob-key", "rooms", 150_000_000, {
			session_id: wire("d"),
		}),
		open("p2/dm", "bob-key", "127.0.0.1:0", 300_000_000, {
			provenance: "unauthenticated",
			session_id: wire("e"),
		}),
		open("p1/dm", "alice-key", "bob-key", 500_000_000, {
			session_id: wire("e"),
		}),
		close("p2/dm", 800_000_000),
		close("p1/dm", 800_000_000),
	]);
	for (const t of [200, 400, 600, 900]) {
		assertSamePicture(`quiet attribution at t=${t}`, events, t);
	}
});

Deno.test("differential: messages in flight across the boundary", () => {
	const events = convertAll([
		open("s1", "alice", "bob", 100_000_000),
		{
			v: 1,
			sim_t_ns: 300_000_000,
			kind: "ocapn.message-decoded",
			session: "s1",
			outbound: true,
			op: "op:deliver",
			depart_ns: 200_000_000,
		},
		close("s1", 600_000_000),
	]);
	for (const t of [150, 220, 260, 320, 500, 800]) {
		assertSamePicture(`message flight at t=${t}`, events, t);
	}
});

Deno.test("differential: a peer named after it joined", () => {
	const events = convertAll([
		open("s1", "rooms", "127.0.0.1:0", 100_000_000),
		{
			v: 1,
			sim_t_ns: 300_000_000,
			kind: "ocapn.session-meta",
			session: "s1",
			meta: { label: "carol" },
		},
		close("s1", 600_000_000),
	]);
	for (const t of [200, 400, 800]) {
		assertSamePicture(`late name at t=${t}`, events, t);
	}
});

Deno.test("differential: three peers, overlapping sessions, one epoch change", () => {
	const events = convertAll([
		open("s1", "rooms", "alice", 100_000_000, { epoch: 1 }),
		open("s2", "rooms", "bob", 200_000_000, { epoch: 1 }),
		close("s1", 400_000_000),
		open("s3", "rooms", "carol", 500_000_000, { epoch: 1 }),
		open("s4", "rooms", "dave", 700_000_000, { epoch: 2 }),
	]);
	for (const t of [150, 300, 450, 600, 750, 1000]) {
		assertSamePicture(`mixed topology at t=${t}`, events, t);
	}
});
