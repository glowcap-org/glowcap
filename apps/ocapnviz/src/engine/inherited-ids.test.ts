import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "./timeline.ts";
import { Engine } from "./engine.ts";
import { engineTest } from "./engine-test/harness.ts";
import { projectFromObservations } from "./temporal/project-from-observations.ts";
import { peerEffective } from "./temporal/doc-resolver.ts";
import { ownEntry } from "./schema/entity-maps.ts";
import { documentHolds } from "../interactions/selection-store.ts";
import { sessionEndName } from "../ui/session-name.ts";
import { UNNAMED_END_LABEL } from "../schema/session-end.ts";
import { findPeer, findSession, queries } from "./world.ts";

/** Ids come from a loaded file, and the names an object inherits are valid
 *  ids: a peer, session, or message called `constructor` is an ordinary one. */
function inheritedIdsDoc(): TimelineDocument {
	return TimelineDocument.parse({
		id: "inherited",
		duration: 5000,
		events: [
			{ id: "e1", t: 0, kind: "peer-joined", peerId: "constructor", profile: "glowcap" },
			{ id: "e2", t: 0, kind: "peer-joined", peerId: "toString", profile: "goblins" },
			{
				id: "e3",
				t: 0,
				kind: "session-opened",
				sessionId: "constructor",
				a: { peer: "constructor" },
				b: { peer: "toString" },
				codec: "syrup",
				captpVersion: "v1_0",
				initialState: "open",
			},
			{
				id: "e4",
				t: 1000,
				kind: "message-sent",
				messageId: "toString",
				sessionId: "constructor",
				from: "constructor",
				to: "toString",
				arrivalT: 1500,
			},
		],
	});
}

/** A document whose three maps exist and hold only ordinary ids, so a lookup of
 *  an inherited name reaches a real map. */
function ordinaryDoc(): TimelineDocument {
	return TimelineDocument.parse({
		id: "ordinary",
		duration: 5000,
		events: [
			{ id: "e1", t: 0, kind: "peer-joined", peerId: "alice", profile: "glowcap" },
			{ id: "e2", t: 0, kind: "peer-joined", peerId: "bob", profile: "goblins" },
			{
				id: "e3",
				t: 0,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "alice" },
				b: { peer: "bob" },
				codec: "syrup",
				captpVersion: "v1_0",
				initialState: "open",
			},
			{
				id: "e4",
				t: 1000,
				kind: "message-sent",
				messageId: "m1",
				sessionId: "s1",
				from: "alice",
				to: "bob",
				arrivalT: 1500,
			},
		],
	});
}

Deno.test("parse: ids an object inherits become entities of their own", () => {
	const entities = inheritedIdsDoc().entities;
	assertEquals(Object.keys(entities?.peers ?? {}).sort(), ["constructor", "toString"]);
	assertEquals(Object.keys(entities?.sessions ?? {}), ["constructor"]);
	assertEquals(Object.keys(entities?.messages ?? {}), ["toString"]);
	assertEquals(entities?.peers?.["toString"]?.profile, "goblins");
});

Deno.test("project: an inherited id is seeded and given a span like any other", () => {
	const doc = inheritedIdsDoc();
	const bare = { ...doc, entities: undefined };
	const projected = projectFromObservations(bare);
	assertEquals(Object.keys(projected.entities?.peers ?? {}).sort(), ["constructor", "toString"]);
	assertEquals(Object.keys(projected.entities?.sessions ?? {}), ["constructor"]);
	assertEquals(Object.keys(projected.entities?.messages ?? {}), ["toString"]);
	assertEquals(peerEffective(projected, "constructor").start, 0);
});

engineTest("materialize: an inherited id reaches the stage", () => {
	const engine = new Engine(inheritedIdsDoc());
	engine.enqueue({ kind: "play" });
	engine.tick(0);
	engine.tick(1200);
	assert(findPeer(engine.world, "constructor") !== undefined);
	assert(findPeer(engine.world, "toString") !== undefined);
	assert(findSession(engine.world, "constructor") !== undefined);
	const flights = [...queries(engine.world).messagesInFlight];
	assertEquals(flights.map((e) => e.messageInFlight.id), ["toString"]);
});

Deno.test("lookup: an id the document does not hold gets nothing from what an object inherits", () => {
	const doc = inheritedIdsDoc();
	const ordinary = ordinaryDoc();
	assertEquals(peerEffective(ordinary, "constructor"), peerEffective(ordinary, "absent"));
	assertEquals(ownEntry(ordinary.entities?.peers, "constructor"), undefined);
	assertEquals(ownEntry(doc.entities?.peers, "hasOwnProperty"), undefined);
	assertEquals(ownEntry(doc.entities?.peers, "toString")?.profile, "goblins");
});

engineTest("an entity named for an inherited name can be edited and removed, and leaves no ghost", () => {
	const engine = new Engine(inheritedIdsDoc());
	const errors: string[] = [];
	engine.onError((e) => errors.push(e.detail));
	engine.dispatch({ kind: "update-peer", peerId: "constructor", patch: { label: "edited" } });
	assertEquals(ownEntry(engine.doc.entities?.peers, "constructor")?.label, "edited");
	assert(documentHolds(engine.doc.entities, { kind: "peer", id: "constructor" }));
	engine.dispatch({ kind: "delete-peer", peerId: "constructor" });
	assertEquals(errors, []);
	// The peer, its session, and the message all went.
	assertEquals(Object.keys(engine.doc.entities?.peers ?? {}), ["toString"]);
	for (const ref of [{ kind: "peer", id: "constructor" }, { kind: "session", id: "constructor" }] as const) {
		assertEquals(documentHolds(engine.doc.entities, ref), false);
	}
	assertEquals(documentHolds(engine.doc.entities, { kind: "message", id: "toString" }), false);
	assertEquals(documentHolds(engine.doc.entities, { kind: "endpoint", id: "constructor::a" }), false);
	// An id the document does not hold does not read as one it does.
	assertEquals(sessionEndName(engine.doc, "constructor", "a", 0), { text: UNNAMED_END_LABEL, opaque: false });
});

Deno.test("a document that never held an inherited name answers no to it", () => {
	const ordinary = ordinaryDoc();
	for (const kind of ["peer", "session", "message"] as const) {
		assertEquals(documentHolds(ordinary.entities, { kind, id: "constructor" }), false);
	}
	assertEquals(sessionEndName(ordinary, "constructor", "a", 0), { text: UNNAMED_END_LABEL, opaque: false });
});
