import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { Engine } from "../engine.ts";
import { attachedEndpoint } from "../../schema/session-end.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import { peerEffective, sessionEffective } from "../temporal/doc-resolver.ts";
import { engineTest } from "./harness.ts";
import { emptyAuthoredDoc } from "./fixtures.ts";

// ─── paste / duplicate ──────────────────────────────────────────

engineTest("duplicate peer mints a -copy id and registers undo", () => {
	const e = new Engine(emptyAuthoredDoc());
	const peerId = e.dispatch({
		kind: "add-peer",
		profile: "glowcap",
		position: { x: 0, y: 0 },
	})!;
	const baseline = JSON.stringify({
		entities: e.doc.entities,
		events: primaryObservations(e.doc),
	});

	const r = e.duplicate({ peers: new Set([peerId]) });
	assert(r.ok);
	// Duplicate says its own name in the undo menu. It shares paste's
	// write, and for a while it borrowed paste's label with it, so the
	// menu offered "Undo Paste" for something nobody had pasted.
	assertEquals(e.nextUndoLabel, "Duplicate");
	// The remap should have surfaced the new id.
	const newPeerId = r.value.remap.peer.get(peerId)!;
	assert(newPeerId);
	assert(newPeerId !== peerId);
	assert(e.doc.entities?.peers?.[newPeerId]);
	// Original peer still there.
	assert(e.doc.entities?.peers?.[peerId]);
	// Undo restores the pre-duplicate state.
	e.undo();
	assertEquals(
		JSON.stringify({
			entities: e.doc.entities,
			events: primaryObservations(e.doc),
		}),
		baseline,
	);
});

engineTest("paste with missing external ref returns validation error", () => {
	const e = new Engine(emptyAuthoredDoc());
	// Build a payload that references a peer the target doc doesn't have.
	// Use a source doc with a session+peer, extract just the session.
	const source = TimelineDocument.parse({
		id: "src",
		duration: 1000,
		events: [
			{
				id: "p1",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "agent",
			},
			{
				id: "p2",
				t: 0,
				kind: "peer-joined",
				peerId: "bob",
				profile: "agent",
			},
			{
				id: "s1ev",
				t: 10,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "alice" },
				b: { peer: "bob" },
				codec: "capnp",
				captpVersion: "v1_0",
			},
		],
	});
	const sourceEngine = new Engine(source);
	const payload = sourceEngine.extractPayload({
		sessions: new Set(["s1"]),
	});
	// Target is empty, alice and bob don't exist there.
	const r = e.paste(payload);
	assert(!r.ok);
	assertEquals(r.error.code, "validation");
});

engineTest("duplicate session-with-peers preserves whole subgraph", () => {
	// Build a doc with two peers + a session, duplicate the lot, verify
	// the duplicate is a self-contained subgraph (its session points at
	// its own peer copies, not the originals).
	const doc = TimelineDocument.parse({
		id: "dup",
		layoutMode: "authored",
		duration: 1000,
		events: [
			{
				id: "p1",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "agent",
			},
			{
				id: "p2",
				t: 0,
				kind: "peer-joined",
				peerId: "bob",
				profile: "agent",
			},
			{
				id: "s1ev",
				t: 10,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "alice" },
				b: { peer: "bob" },
				codec: "capnp",
				captpVersion: "v1_0",
			},
		],
	});
	const e = new Engine(doc);

	const r = e.duplicate({
		peers: new Set(["alice", "bob"]),
		sessions: new Set(["s1"]),
	});
	assert(r.ok);

	const aliceCopy = r.value.remap.peer.get("alice")!;
	const bobCopy = r.value.remap.peer.get("bob")!;
	const s1Copy = r.value.remap.session.get("s1")!;
	assert(aliceCopy !== "alice");
	assert(bobCopy !== "bob");
	assert(s1Copy !== "s1");

	// The duplicated session points at the duplicated peers, not the originals.
	const dupSession = e.doc.entities?.sessions?.[s1Copy];
	assertEquals(dupSession?.a?.peer, aliceCopy);
	assertEquals(dupSession?.b?.peer, bobCopy);
});

// ── move-entity-span: freshly authored entities retime like loaded ones ──────
// The defect this family was written against: Build-mode entities have
// `entity.timing` and no observation events, and the event-addressed
// `move-event` silently dropped their timeline drags. The entity-addressed
// intent is the one write path for both provenances.

engineTest(
	"move-entity-span resizes a freshly authored peer's right edge",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "glowcap",
			position: { x: 0, y: 0 },
		})!;
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "resize-end",
				ref: { kind: "peer", id: peerId },
				newT: 4_000,
			},
		});
		const eff = peerEffective(e.doc, peerId);
		assertEquals(eff.end, 4_000);
	},
);

engineTest(
	"move-entity-span resizes a freshly authored peer's left edge, end pinned",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "glowcap",
			position: { x: 0, y: 0 },
		})!;
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "resize-end",
				ref: { kind: "peer", id: peerId },
				newT: 5_000,
			},
		});
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "resize-start",
				ref: { kind: "peer", id: peerId },
				newT: 1_000,
			},
		});
		const eff = peerEffective(e.doc, peerId);
		assertEquals(eff.start, 1_000);
		assertEquals(eff.end, 5_000, "left-edge resize must not slide the end");
	},
);

engineTest(
	"move-entity-span translates a freshly authored peer, duration preserved",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "glowcap",
			position: { x: 0, y: 0 },
		})!;
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "resize-end",
				ref: { kind: "peer", id: peerId },
				newT: 2_000,
			},
		});
		const before = peerEffective(e.doc, peerId);
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "translate",
				ref: { kind: "peer", id: peerId },
				newT: 3_000,
			},
		});
		const eff = peerEffective(e.doc, peerId);
		assertEquals(eff.start, 3_000);
		assertEquals(eff.end - eff.start, before.end - before.start);
	},
);

engineTest(
	"move-entity-span resizes a freshly authored session both edges",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const a = e.dispatch({
			kind: "add-peer",
			profile: "glowcap",
			position: { x: 0, y: 0 },
		})!;
		const b = e.dispatch({
			kind: "add-peer",
			profile: "glowcap",
			position: { x: 10, y: 0 },
		})!;
		const sessionId = e.dispatch({
			kind: "open-session",
			a: attachedEndpoint(a),
			b: attachedEndpoint(b),
		})!;
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "resize-end",
				ref: { kind: "session", id: sessionId },
				newT: 6_000,
			},
		});
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "resize-start",
				ref: { kind: "session", id: sessionId },
				newT: 2_000,
			},
		});
		const eff = sessionEffective(e.doc, sessionId);
		assertEquals(eff.start, 2_000);
		assertEquals(eff.end, 6_000);
	},
);

engineTest(
	"move-entity-span on a loaded peer moves its observation events too",
	() => {
		const doc = TimelineDocument.parse({
			id: "loaded",
			duration: 10_000,
			events: [
				{
					id: "e1",
					t: 1_000,
					kind: "peer-joined",
					peerId: "alice",
					profile: "agent",
				},
				{ id: "e2", t: 8_000, kind: "peer-left", peerId: "alice" },
			],
		});
		const e = new Engine(doc);
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "resize-start",
				ref: { kind: "peer", id: "alice" },
				newT: 2_000,
			},
		});
		const eff = peerEffective(e.doc, "alice");
		assertEquals(eff.start, 2_000);
		assertEquals(
			eff.end,
			8_000,
			"resize-start keeps the loaded end pinned",
		);
		const joined = primaryObservations(e.doc).find((ev) => ev.id === "e1")!;
		assertEquals(joined.t, 2_000, "the observation event moved to agree");
	},
);

engineTest(
	"move-entity-span refuses an inverted resize with a validation error",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "glowcap",
			position: { x: 0, y: 0 },
		})!;
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "resize-end",
				ref: { kind: "peer", id: peerId },
				newT: 3_000,
			},
		});
		const errors: string[] = [];
		const un = e.onError((err) => errors.push(err.code));
		e.dispatch({
			kind: "move-entity-span",
			move: {
				kind: "resize-start",
				ref: { kind: "peer", id: peerId },
				newT: 9_000,
			},
		});
		un();
		assert(errors.length > 0, "start after end must refuse");
		const eff = peerEffective(e.doc, peerId);
		assertEquals(
			eff.end,
			3_000,
			"a refused gesture leaves the span untouched",
		);
	},
);
