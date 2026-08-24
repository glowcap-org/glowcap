/**
 * The two trajectory tables.
 *
 * These tests hold the claim the tables exist to make: that the app's
 * knowledge of what changes about a peer, and about a session, lives
 * here and nowhere else. Each one reads a property through its table
 * rather than by name, so a new property joins them by appearing in
 * `PEER_PROPERTIES` or `SESSION_PROPERTIES` — and a consumer that
 * hardcoded `label` or `state` behind the table's back fails them.
 */

import { assert, assertEquals, assertThrows } from "@std/assert";
import {
	PEER_PROPERTIES,
	PEER_TRAJECTORY,
	type PeerUpdate,
	peerUpdateStates,
	SESSION_PROPERTIES,
	SESSION_TRAJECTORY,
	sessionRowDisplay,
	sessionTrajectoryRows,
	type SessionValue,
	type TrajectoryDisplay,
} from "./trajectory.ts";
import { SessionState } from "../schema/topology.ts";
import { attachedEndpoint, EndpointAttribution, SESSION_SIDES, sessionEndpoint } from "../schema/session-end.ts";
import type { PeerDefinition, SessionDefinition, TimelineDocument } from "./timeline.ts";
import { peerPropertyAt } from "./temporal/doc-resolver.ts";

const update = (fields: Partial<PeerUpdate> = {}): PeerUpdate => ({
	id: "u1",
	kind: "peer-updated",
	t: 100,
	peerId: "p1",
	...fields,
});

/** A value the property will accept, asked of the property itself.
 *
 * A free-text property takes any string; a property that picks from a
 * closed set takes one of the values it declares, and writing outside
 * that set is a caller bug the table refuses rather than stores. These
 * tests are generic over the table, so they have to ask it what a
 * valid value is instead of assuming every property is free text —
 * which also makes them prove that what `editor.options` offers is
 * exactly what the storage half accepts. `nth` picks a second
 * distinct value where a case needs one. */
function sampleValue(spec: TrajectoryDisplay, nth = 0): string {
	if (spec.editor.kind !== "enum") return `value-${nth + 1}`;
	const options = spec.editor.options;
	const at = options[nth % options.length];
	assert(at !== undefined, "an enum property declares at least one option");
	return at;
}

Deno.test("every property is declared once and listed once", () => {
	assertEquals(
		[...PEER_PROPERTIES].sort(),
		Object.keys(PEER_TRAJECTORY).sort(),
		"PEER_PROPERTIES and PEER_TRAJECTORY name the same set",
	);
	assertEquals(
		PEER_PROPERTIES.length,
		new Set(PEER_PROPERTIES).size,
		"no property is listed twice",
	);
});

Deno.test("a property round-trips through write, read, and clear", () => {
	for (const property of PEER_PROPERTIES) {
		const spec = PEER_TRAJECTORY[property];
		const blank = update();
		assertEquals(
			spec.read(blank),
			null,
			`${property}: a blank update states nothing`,
		);
		const value = sampleValue(spec);
		const stated = spec.write(blank, value);
		assertEquals(spec.read(stated), value, `${property}: write then read`);
		assertEquals(
			spec.read(spec.clear(stated)),
			null,
			`${property}: clear un-states it`,
		);
		// Clearing leaves the observation itself intact — one moment can
		// state several properties, and only this one goes.
		assertEquals(spec.clear(stated).t, blank.t);
		assertEquals(spec.clear(stated).peerId, blank.peerId);
	}
});

Deno.test("an update states exactly the properties written onto it", () => {
	for (const property of PEER_PROPERTIES) {
		const spec = PEER_TRAJECTORY[property];
		const value = sampleValue(spec);
		const stated = peerUpdateStates(spec.write(update(), value));
		assertEquals(stated, [{ property, value }]);
	}
	assertEquals(peerUpdateStates(update()), []);
});

Deno.test("a property's track round-trips onto a definition", () => {
	for (const property of PEER_PROPERTIES) {
		const spec = PEER_TRAJECTORY[property];
		const bare: PeerDefinition = { profile: "pancake" };
		assertEquals(spec.track(bare), undefined, `${property}: no track yet`);

		const value = sampleValue(spec);
		const keyframes = spec.withTrack(bare, [{ t: 10, value }]);
		assert(keyframes !== undefined, `${property}: a track lands`);
		const withTrack: PeerDefinition = { ...bare, keyframes };
		assertEquals(spec.track(withTrack), [{ t: 10, value }]);

		// Dropping the last track drops the keyframes object with it, so
		// a quiet definition stays quiet in the saved document.
		assertEquals(
			spec.withTrack(withTrack, undefined),
			undefined,
			`${property}: dropping the only track drops keyframes`,
		);
	}
});

// ── the session table ─────────────────────────────────────────────
//
// The session lane's storage half is shaped by what a session's
// moment IS: one observation stating one property. So these read
// through `read` / `observation` rather than through field edits on a
// shared observation, and they are generic over `SESSION_PROPERTIES`
// for the same reason the peer cases are generic over its list.

/** A session with both ends attached and nothing stated yet. */
const sessionDef = (over: Partial<SessionDefinition> = {}) =>
	({
		a: { peer: "alice" },
		b: { peer: "bob" },
		codec: "syrup",
		captpVersion: "v1_0",
		...over,
	}) as SessionDefinition;

/** A value the session property will accept. A state picks one of
 *  its declared options; an end takes a peer id, which the table
 *  cannot enumerate because the peers are the document's. */
function sampleSessionValue(property: string, nth = 0): SessionValue {
	const spec = SESSION_TRAJECTORY[property as keyof typeof SESSION_TRAJECTORY];
	// A non-enum session property is an end, and an end's value is a pair.
	// Built through the property's own door so the sample is whatever the
	// property actually carries.
	if (spec.editor.kind !== "enum") return spec.parse(`peer-${nth + 1}`);
	const at = spec.editor.options[nth % spec.editor.options.length];
	assert(at !== undefined, "an enum property declares at least one option");
	return at;
}

Deno.test("every session property is declared once and listed once", () => {
	assertEquals(
		[...SESSION_PROPERTIES].sort(),
		Object.keys(SESSION_TRAJECTORY).sort(),
		"SESSION_PROPERTIES and SESSION_TRAJECTORY name the same set",
	);
	assertEquals(SESSION_PROPERTIES.length, new Set(SESSION_PROPERTIES).size);
	// Both ends are properties, so both are authorable. This is the
	// gap the endpoint model closed: the tracks existed and no editor
	// could reach them.
	for (const side of SESSION_SIDES) {
		assert(
			SESSION_PROPERTIES.includes(side),
			`end ${side} is not a trajectory row`,
		);
	}
});

Deno.test("a session property round-trips through observation and read", () => {
	for (const property of SESSION_PROPERTIES) {
		const spec = SESSION_TRAJECTORY[property];
		const value = sampleSessionValue(property);
		const ev = spec.observation("o1", "s1", 100, value);
		assertEquals(
			spec.read(ev, "s1"),
			value,
			`${property}: write then read`,
		);
		// The moment belongs to ONE session and one property. Reading it
		// as another session's, or as another property's, must come back
		// empty — this is what lets one predicate address a moment.
		assertEquals(
			spec.read(ev, "other"),
			null,
			`${property}: another session`,
		);
		for (const other of SESSION_PROPERTIES) {
			if (other === property) continue;
			assertEquals(
				SESSION_TRAJECTORY[other].read(ev, "s1"),
				null,
				`${property}'s observation was read as ${other}`,
			);
		}
	}
});

Deno.test("a session property reads its track and its genesis", () => {
	for (const property of SESSION_PROPERTIES) {
		const spec = SESSION_TRAJECTORY[property];
		assertEquals(
			spec.track(sessionDef()),
			undefined,
			`${property}: no track`,
		);
		const value = sampleSessionValue(property);
		const def = sessionDef({
			keyframes: { [property]: [{ t: 10, value }] },
		});
		assertEquals(spec.track(def), [{ t: 10, value }]);
	}
	assertEquals(SESSION_TRAJECTORY.state.genesis(sessionDef()), undefined);
	assertEquals(
		SESSION_TRAJECTORY.state.genesis(sessionDef({ initialState: "open" })),
		"open",
	);
	assertEquals(SESSION_TRAJECTORY.a.genesis(sessionDef()), { peer: "alice" });
	// A loose end has no genesis peer, and that is an answer rather
	// than a gap: nothing has attributed it.
	assertEquals(
		SESSION_TRAJECTORY.b.genesis(
			sessionDef({ b: sessionEndpoint({ designator: "1.2.3.4" }) }),
		),
		undefined,
	);
});

Deno.test("only a definition-durable property carries withTrack", () => {
	// `withTrack` is how a property's authored track lands on the
	// definition, and a property whose track the projection re-derives
	// from the observations must NOT have one — a track stored beside
	// the observation would be a second copy of a derived fact. The
	// ends are derived; the state is authored.
	assert(
		SESSION_TRAJECTORY.state.withTrack !== undefined,
		"the state track is authored on the definition",
	);
	for (const side of SESSION_SIDES) {
		assertEquals(
			SESSION_TRAJECTORY[side].withTrack,
			undefined,
			`end ${side} stored a track the projection re-derives`,
		);
	}
	const written = SESSION_TRAJECTORY.state.withTrack!(sessionDef(), [{
		t: 5,
		value: "open",
	}]);
	assertEquals(written?.state, [{ t: 5, value: "open" }]);
});

Deno.test("a session property that names an entity says so", () => {
	// The write refuses a value naming an entity the document does not
	// declare, and this is the field that tells it to. An end names a
	// peer; a state names nothing.
	for (const side of SESSION_SIDES) {
		assertEquals(SESSION_TRAJECTORY[side].names, "peers");
	}
	assertEquals(SESSION_TRAJECTORY.state.names, undefined);
});

Deno.test("the state observation refuses a state nobody declared", () => {
	assertThrows(
		() => SESSION_TRAJECTORY.state.observation("o1", "s1", 0, "loitering"),
		"an undeclared state was stored rather than refused",
	);
});

Deno.test("an end's row resolves its peers against the document", () => {
	// The table says an end attaches to a peer without saying which
	// peers; the row fills them in as it paints. What may have backed the
	// attachment is the whole domain and travels with the table, because a
	// row that could not offer it could not author a moment a signed
	// handoff proved. Every other property passes through unchanged.
	const peers = ["alice", "bob"];
	const end = sessionRowDisplay("a", peers);
	assertEquals(end.editor.kind, "attachment");
	if (end.editor.kind !== "attachment") return;
	assertEquals([...end.editor.peers], peers);
	assertEquals(
		[...end.editor.attributions],
		[...EndpointAttribution.options],
		"a row offers fewer attributions than a recording can hold",
	);
	assertEquals(sessionRowDisplay("state", peers), SESSION_TRAJECTORY.state);
});

/** A document whose only content is the moments listed — the shape a
 *  session's trajectory is read out of. Each moment is one
 *  observation, which is what gives it a name. */
function momentDoc(
	moments: { id: string; property: string; t: number; value: string }[],
): TimelineDocument {
	return {
		id: "moments",
		duration: 10_000,
		recording: {
			sources: [{
				id: "primary",
				meta: { kind: "authored" },
				observations: moments.map((m) =>
					SESSION_TRAJECTORY[
						m.property as keyof typeof SESSION_TRAJECTORY
					]
						.observation(m.id, "s1", m.t, m.value)
				),
			}],
		},
	} as unknown as TimelineDocument;
}

Deno.test("a session's moments list in time order, then property order", () => {
	const doc = momentDoc([
		{ id: "m1", property: "state", t: 200, value: "open" },
		{ id: "m2", property: "a", t: 200, value: "alice" },
		{ id: "m3", property: "b", t: 100, value: "bob" },
	]);
	// Each row carries what its property states, in that property's own
	// value channel: a lifecycle word, or the pair an end attached by.
	assertEquals(sessionTrajectoryRows(doc, "s1"), [
		{ property: "b", eventId: "m3", t: 100, value: { peer: "bob" } },
		{ property: "state", eventId: "m1", t: 200, value: "open" },
		{ property: "a", eventId: "m2", t: 200, value: { peer: "alice" } },
	]);
	assertEquals(sessionTrajectoryRows(momentDoc([]), "s1"), []);
	// Another session's moments are not this one's.
	assertEquals(sessionTrajectoryRows(doc, "s2"), []);
});

Deno.test("a moment keeps its identity when its time moves", () => {
	// The mechanical cause behind a drag that died after one step. The
	// Inspector lists these rows and keys each on the moment's identity;
	// when that identity was the time, the row React was rendering ceased
	// to exist the instant the drag changed it, and the pointer capture
	// went with the unmounted element.
	//
	// This pins the CAUSE, not the gesture. That a real drag now scrubs
	// the row is measured by `scripts/playwright-trajectory-scrub-probe.ts`
	// against a running dev server.
	const at = (t: number) =>
		sessionTrajectoryRows(
			momentDoc([
				{ id: "m1", property: "state", t: 100, value: "open" },
				{ id: "m2", property: "state", t, value: "closed" },
			]),
			"s1",
		);
	const before = at(300);
	const after = at(900);
	const identity = (rows: ReturnType<typeof sessionTrajectoryRows>) => rows.map((r) => r.eventId);
	assertEquals(identity(before), identity(after));
	assertEquals(before.map((r) => r.t), [100, 300]);
	assertEquals(after.map((r) => r.t), [100, 900]);
});

Deno.test("a moment keeps its identity when a moment lands before it", () => {
	// The other half, and the one an index could not survive: inserting
	// a moment earlier in the same track shifts every later index by
	// one, so a list keyed on the index hands a mounted row's fiber to a
	// different keyframe. Clicking Insert with a value select focused
	// remounted the row and took the focus with it.
	const later = { id: "m2", property: "state", t: 900, value: "closed" };
	const before = sessionTrajectoryRows(momentDoc([later]), "s1");
	const after = sessionTrajectoryRows(
		momentDoc([
			{ id: "m1", property: "state", t: 100, value: "open" },
			later,
		]),
		"s1",
	);
	assertEquals(before[0]!.eventId, "m2");
	assertEquals(after[1]!.eventId, "m2");
});

Deno.test("every property says how a row names and edits it", () => {
	// Both lanes render through the same row and insert controls, so
	// both owe the same description. A property that skipped it would
	// render a nameless row or an empty picker.
	const described: [string, TrajectoryDisplay, string][] = [
		...PEER_PROPERTIES.map((
			p,
		) => [p, PEER_TRAJECTORY[p], "peers"] as [
			string,
			TrajectoryDisplay,
			string,
		]),
		...SESSION_PROPERTIES.map((
			p,
		) => [p, SESSION_TRAJECTORY[p], "sessions"] as [
			string,
			TrajectoryDisplay,
			string,
		]),
	];
	assert(described.length >= 2, "both lanes declare at least one property");
	for (const [name, spec, lane] of described) {
		assert(spec.noun.length > 0, `${name}: has a noun to show`);
		assertEquals(spec.lane, lane, `${name}: names its lane`);
		if (spec.editor.kind === "enum") {
			assert(
				spec.editor.options.length > 0,
				`${name}: an enum editor offers options`,
			);
		}
	}
});

Deno.test("the session state picker offers exactly the declared states", () => {
	// The schema is the authority; the picker reads it rather than
	// keeping a list that can drift from it.
	const editor = SESSION_TRAJECTORY.state.editor;
	assertEquals(editor.kind, "enum");
	if (editor.kind !== "enum") return;
	assertEquals([...editor.options], [...SessionState.options]);
});

Deno.test("a closed-set property refuses a value it never declared", () => {
	// The other half of `sampleValue`'s contract, and it needs its own case:
	// every test above writes values the table itself offered, so none of them
	// would notice if a closed property quietly stored whatever it was handed.
	// A stored undeclared value would not surface here at all — it would
	// surface later, as a document whose keyframe track fails to parse.
	//
	// Only the CLOSED pickers. A profile's options are the well-known
	// implementations rather than the only legal ones, so refusing an
	// unfamiliar name there would be this viewer overreaching.
	//
	// Both lanes, because the invariant is the table's rather than the
	// peer table's: a session's `state` is closed, and no peer property
	// is, so checking only one lane would leave this unexercised
	// whenever the other lane is where the closed pickers live.
	let checked = 0;
	for (const property of PEER_PROPERTIES) {
		const spec = PEER_TRAJECTORY[property];
		if (spec.editor.kind !== "enum" || !spec.editor.closed) continue;
		assertThrows(
			() => spec.write(update(), "not-a-declared-option"),
			`${property}: an undeclared value was stored rather than refused`,
		);
		checked += 1;
	}
	for (const property of SESSION_PROPERTIES) {
		const spec = SESSION_TRAJECTORY[property];
		if (spec.editor.kind !== "enum" || !spec.editor.closed) continue;
		assertThrows(
			() => spec.observation("o1", "w1", 10, "not-a-declared-option"),
			`${property}: an undeclared value was stored rather than refused`,
		);
		checked += 1;
	}
	assert(checked > 0, "no closed picker was actually exercised");
});

// ── totality ──────────────────────────────────────────────────────
//
// The trajectory insert control offers "what this peer carries at
// the playhead" as the starting value for a property the author has
// just added. It holds a `PeerProperty` it cannot name, so it has no
// per-property default to reach for and asks `peerPropertyAt`.
//
// Before that reader existed, the control substituted the empty
// string for a peer the document said nothing about, and a closed
// picker refused it: the insert raised a schema error naming the
// options instead of adding a row. The general shape is a fallback
// the property's own `write` will not take, so these check the round
// trip rather than the values.

/** A peer the document knows by id and says nothing else about —
 *  what build mode makes when you add one. */
const bareDoc = {
	version: 1,
	duration: 100,
	events: [],
	entities: { peers: { p1: {} } },
} as unknown as TimelineDocument;

Deno.test("every property offers a value a bare peer can be given", () => {
	for (const property of PEER_PROPERTIES) {
		const spec = PEER_TRAJECTORY[property];
		const offered = peerPropertyAt(bareDoc, "p1", property, 10);
		assert(
			offered !== "",
			`${property} offered the empty string, which states "no value"`,
		);
		// `write` is where a closed picker refuses, so this is the throw
		// the Inspector surfaced as "Something went wrong".
		assertEquals(
			spec.read(spec.write(update(), offered)),
			offered,
			`${property}: what the insert offers is not what it can store`,
		);
	}
});

Deno.test("a closed picker only ever offers one of its own options", () => {
	let checked = 0;
	for (const property of PEER_PROPERTIES) {
		const spec = PEER_TRAJECTORY[property];
		if (spec.editor.kind !== "enum" || !spec.editor.closed) continue;
		const offered = peerPropertyAt(bareDoc, "p1", property, 10);
		assert(
			spec.editor.options.includes(offered),
			`${property} offered ${JSON.stringify(offered)}, not one of ` +
				spec.editor.options.join(" | "),
		);
		checked += 1;
	}
	// The session lane's closed picker, for the same reason the refusal
	// case checks both: the peer lane carries none today.
	for (const property of SESSION_PROPERTIES) {
		const spec = SESSION_TRAJECTORY[property];
		if (spec.editor.kind !== "enum" || !spec.editor.closed) continue;
		// Through `stated`, because that is the channel a picker offers: the
		// options are strings and an end's value is a pair.
		const genesis = spec.genesis({
			a: attachedEndpoint("p1"),
			b: attachedEndpoint("p2"),
			codec: "syrup",
			captpVersion: "v1_0",
			initialState: "open",
		});
		const offered = genesis === undefined ? spec.editor.options[0]! : spec.stated(genesis);
		assert(
			spec.editor.options.includes(offered),
			`${property} offered ${JSON.stringify(offered)}, not one of ` +
				spec.editor.options.join(" | "),
		);
		checked += 1;
	}
	assert(checked > 0, "no closed picker was actually exercised");
});

Deno.test("a peer the document has never heard of still answers", () => {
	// The Inspector can be pointed at a peer that is on stage but has
	// no definition yet. Every property must still be insertable.
	for (const property of PEER_PROPERTIES) {
		assert(
			peerPropertyAt(bareDoc, "ghost", property, 10) !== "",
			`${property} for an undefined peer`,
		);
	}
	assertEquals(peerPropertyAt(bareDoc, "ghost", "label", 10), "ghost");
});
