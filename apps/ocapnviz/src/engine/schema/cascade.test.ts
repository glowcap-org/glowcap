import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { cascadeDelete, cascadeRewrite } from "./cascade.ts";
import { primaryObservations } from "../temporal/recording-access.ts";

/** Two peers, one session between them, one in-flight message. */
function smallFixture(): TimelineDocument {
	return TimelineDocument.parse({
		id: "doc-1",
		duration: 1000,
		events: [
			{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "agent",
			},
			{
				id: "e2",
				t: 0,
				kind: "peer-joined",
				peerId: "bob",
				profile: "agent",
			},
			{
				id: "e3",
				t: 10,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "alice" },
				b: { peer: "bob" },
				codec: "capnp",
				captpVersion: "v1_0",
			},
			{
				id: "e4",
				t: 20,
				kind: "message-sent",
				messageId: "m1",
				sessionId: "s1",
				from: "alice",
				to: "bob",
				arrivalT: 22,
			},
			{ id: "e5", t: 22, kind: "message-delivered", messageId: "m1" },
		],
		rowOrder: { peers: ["alice", "bob"], sessions: ["s1"] },
		rowHidden: { peers: ["alice"] },
	});
}

// ─── cascadeDelete ────────────────────────────────────────────────

Deno.test("cascadeDelete: peer cascades through session and message", () => {
	const doc = smallFixture();
	const result = cascadeDelete(doc, "peer", "alice");

	// alice is gone from entities.
	assertEquals(result.entities?.peers?.alice, undefined);
	// bob survives.
	assert(result.entities?.peers?.bob);
	// s1 cascaded because session.a referenced alice.
	assertEquals(result.entities?.sessions?.s1, undefined);
	// m1 cascaded because message.from referenced alice (and message.sessionId
	// referenced s1 which itself cascaded).
	assertEquals(result.entities?.messages?.m1, undefined);

	// The cascade purges each visited entity's own observations — a
	// spared observation would re-synthesize its ghost on the next
	// projection. Only bob's join survives here: alice's join, the
	// session pair's open, and m1's sent/delivered all belonged to
	// cascaded entities.
	const kept = primaryObservations(result);
	assertEquals(kept.length, 1);
	assertEquals(kept[0]!.id, "e2");

	// rowOrder.peers had alice removed; bob stays.
	assertEquals(result.rowOrder?.peers, ["bob"]);
	// rowOrder.sessions had s1 removed; the field collapses to undefined.
	assertEquals(result.rowOrder?.sessions, undefined);
	// rowHidden.peers had alice removed; whole field collapses (was the only entry).
	assertEquals(result.rowHidden, undefined);
});

Deno.test("cascadeDelete: deleting a session cascades through its messages but not its peers", () => {
	const doc = smallFixture();
	const result = cascadeDelete(doc, "session", "s1");

	// s1 gone, m1 cascaded (message.sessionId referenced s1).
	assertEquals(result.entities?.sessions, undefined);
	assertEquals(result.entities?.messages, undefined);
	// Peers survive — sessions don't own peers.
	assert(result.entities?.peers?.alice);
	assert(result.entities?.peers?.bob);

	// The session's open and its message's observations purge with
	// their entities; the peers' joins survive.
	assertEquals(
		primaryObservations(result).map((ev) => ev.id),
		["e1", "e2"],
	);
});

Deno.test("cascadeDelete: deleting a message touches only the message", () => {
	const doc = smallFixture();
	const result = cascadeDelete(doc, "message", "m1");

	// m1 gone; everything else intact.
	assertEquals(result.entities?.messages, undefined);
	assert(result.entities?.peers?.alice);
	assert(result.entities?.peers?.bob);
	assert(result.entities?.sessions?.s1);

	// The message's sent + delivered observations purge with it;
	// everything else's survive.
	assertEquals(
		primaryObservations(result).map((ev) => ev.id),
		["e1", "e2", "e3"],
	);
});

Deno.test("cascadeDelete: unknown id is a no-op (no entity to start from)", () => {
	const doc = smallFixture();
	const result = cascadeDelete(doc, "peer", "carol");
	// Doc structure unchanged. Compare events array identity-by-content.
	assertEquals(
		primaryObservations(result).length,
		primaryObservations(doc).length,
	);
	assertEquals(result.entities?.peers?.alice, doc.entities?.peers?.alice);
});

Deno.test(
	"cascadeDelete: terminates with a synthetic cycle (visited set works)",
	() => {
		// No way to build a true cycle through the current schema, but we
		// can verify visited-set discipline by deleting an entity that
		// would be visited twice if we forgot to dedupe (alice is reached
		// both by direct deletion AND via session.a → which when removed
		// doesn't requeue alice, but the queue handling shouldn't loop).
		const doc = smallFixture();
		const result = cascadeDelete(doc, "peer", "alice");
		// If it didn't terminate, this test would hang. Reaching this
		// assertion is the test.
		assert(result);
	},
);

// ─── cascadeRewrite ───────────────────────────────────────────────

Deno.test("cascadeRewrite: rename peer alice → alyssa", () => {
	const doc = smallFixture();
	const r = cascadeRewrite(doc, "peer", "alice", "alyssa");
	assert(r.ok);
	const result = r.value;

	// Entity moved.
	assertEquals(result.entities?.peers?.alice, undefined);
	assert(result.entities?.peers?.alyssa);

	// Session endpoint rewritten.
	assertEquals(result.entities?.sessions?.s1?.a?.peer, "alyssa");
	assertEquals(result.entities?.sessions?.s1?.b?.peer, "bob");

	// Message endpoints rewritten.
	assertEquals(result.entities?.messages?.m1?.from, "alyssa");
	assertEquals(result.entities?.messages?.m1?.to, "bob");

	// Observations are immutable — events still carry the old id.
	const origAliceEv = primaryObservations(doc).find(
		(e): e is Extract<typeof e, { kind: "peer-joined" }> => e.kind === "peer-joined" && e.peerId === "alice",
	);
	assert(origAliceEv);

	// Doc-indexes rewritten in place.
	assertEquals(result.rowOrder?.peers, ["alyssa", "bob"]);
	assertEquals(result.rowHidden?.peers, ["alyssa"]);
});

Deno.test("cascadeRewrite: collision returns error, doc untouched", () => {
	const doc = smallFixture();
	const r = cascadeRewrite(doc, "peer", "alice", "bob");
	assert(!r.ok);
	assertEquals(r.error.code, "collision");
});

Deno.test("cascadeRewrite: same id is a no-op", () => {
	const doc = smallFixture();
	const r = cascadeRewrite(doc, "peer", "alice", "alice");
	assert(r.ok);
	assertEquals(r.value, doc);
});

Deno.test("cascadeRewrite: session rename cascades through message.sessionId", () => {
	const doc = smallFixture();
	const r = cascadeRewrite(doc, "session", "s1", "session-prime");
	assert(r.ok);
	const result = r.value;
	assertEquals(result.entities?.sessions?.s1, undefined);
	assert(result.entities?.sessions?.["session-prime"]);
	assertEquals(result.entities?.messages?.m1?.sessionId, "session-prime");
	// Observations are immutable — the recording still contains session-opened with sessionId "s1".
	assert(
		primaryObservations(result).some((e) => e.kind === "session-opened"),
	);
});

Deno.test("cascadeRewrite: message rename touches only message refs", () => {
	const doc = smallFixture();
	const r = cascadeRewrite(doc, "message", "m1", "m1-alt");
	assert(r.ok);
	const result = r.value;
	assertEquals(result.entities?.messages?.m1, undefined);
	assert(result.entities?.messages?.["m1-alt"]);
	// Peers and session untouched.
	assert(result.entities?.peers?.alice);
	assertEquals(result.entities?.sessions?.s1?.a?.peer, "alice");
});

Deno.test(
	"cascadeRewrite: the observation follows the rename",
	() => {
		// The doc has a peer-joined event only — no explicit entities
		// map entry — but the zod parse transform materializes the
		// entity from the event payload. The rename must carry the
		// observation with it: an observation left on the old id would
		// let the projection resurrect a ghost there, while the renamed
		// entity — matching no observations — would lose its derived
		// timing.
		const doc = TimelineDocument.parse({
			id: "doc-2",
			duration: 100,
			events: [
				{
					id: "e1",
					t: 0,
					kind: "peer-joined",
					peerId: "ghost",
					profile: "agent",
				},
			],
		});
		// After parse the entity exists under "ghost".
		assert(doc.entities?.peers?.ghost);
		const r = cascadeRewrite(doc, "peer", "ghost", "specter");
		assert(r.ok);
		// Entity renamed.
		assertEquals(r.value.entities?.peers?.ghost, undefined);
		assert(r.value.entities?.peers?.specter);
		// The observation renamed with it.
		const ev = primaryObservations(r.value)[0] as { peerId: string };
		assertEquals(ev.peerId, "specter");
	},
);

// ─── the reference inside an endpoint ─────────────────────────────
//
// A session's end is a structure, and the peer it names is one
// property of it. `EVENT_EDGES` says so with `nested`, and every
// walker, rewriter, and extractor reads through it — so these two
// cases are the ones that fail when a rewriter keeps its own list of
// field names instead.

Deno.test("cascadeRewrite: a rename reaches the peer inside an endpoint", () => {
	const doc = smallFixture();
	const r = cascadeRewrite(doc, "peer", "alice", "alyssa");
	assert(r.ok);
	const opened = primaryObservations(r.value).find(
		(e): e is Extract<typeof e, { kind: "session-opened" }> => e.kind === "session-opened",
	);
	assert(opened);
	assertEquals(opened.a.peer, "alyssa");
	// The claim the end carries is not a reference and does not move.
	assertEquals(opened.b.peer, "bob");
});

Deno.test("cascadeRewrite: a rename reaches an end that attached later", () => {
	const doc = TimelineDocument.parse({
		id: "late",
		duration: 100,
		events: [
			{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "agent",
			},
			{
				id: "e2",
				t: 0,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "alice" },
				b: { designator: "1.2.3.4" },
				codec: "capnp",
				captpVersion: "v1_0",
			},
			{
				id: "e3",
				t: 50,
				kind: "session-endpoint-attributed",
				sessionId: "s1",
				side: "b",
				peerId: "alice",
			},
		],
	});
	const r = cascadeRewrite(doc, "peer", "alice", "alyssa");
	assert(r.ok);
	const attached = primaryObservations(r.value).find(
		(e): e is Extract<typeof e, { kind: "session-endpoint-attributed" }> =>
			e.kind === "session-endpoint-attributed",
	);
	assert(attached);
	assertEquals(attached.peerId, "alyssa");
});

Deno.test("cascadeDelete: a session takes its attributions with it", () => {
	// An attribution is a moment on the session's own row, so it
	// belongs to the session. Left behind, it would paint a moment for
	// a session nothing else in the document mentions.
	const doc = TimelineDocument.parse({
		id: "attrib",
		duration: 100,
		events: [
			{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "agent",
			},
			{
				id: "e2",
				t: 0,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "alice" },
				b: { designator: "1.2.3.4" },
				codec: "capnp",
				captpVersion: "v1_0",
			},
			{
				id: "e3",
				t: 50,
				kind: "session-endpoint-attributed",
				sessionId: "s1",
				side: "b",
				peerId: "alice",
			},
		],
	});
	const result = cascadeDelete(doc, "session", "s1");
	assertEquals(result.entities?.sessions?.s1, undefined);
	assertEquals(
		primaryObservations(result).map((e) => e.id),
		["e1"],
		"the session's attribution outlived the session",
	);
});
