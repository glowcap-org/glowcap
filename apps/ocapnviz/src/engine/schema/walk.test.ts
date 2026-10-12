import { assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { findDocIndexRefs, findEntityRefs, findEventRefs } from "./walk.ts";
import { primaryObservations } from "../temporal/recording-access.ts";

/** Build a fixture with two peers, one session connecting them, one
 *  message in flight, plus rowOrder entries, exercises all three
 *  edge classes. */
function fixture(): TimelineDocument {
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
			{
				id: "e5",
				t: 22,
				kind: "message-delivered",
				messageId: "m1",
			},
		],
		rowOrder: { peers: ["alice", "bob"], sessions: ["s1"] },
		rowHidden: { peers: ["alice"] },
	});
}

Deno.test("findEventRefs: peer alice referenced by 4 events", () => {
	const doc = fixture();
	const refs = findEventRefs(primaryObservations(doc), "peer", "alice");
	// peer-joined.peerId, session-opened.a, message-sent.from
	// (peer-left/etc. absent in this fixture).
	assertEquals(refs.length, 3);
	const fields = refs.map((r) => `${r.event.kind}.${r.field}`).sort();
	assertEquals(fields, [
		"message-sent.from",
		"peer-joined.peerId",
		"session-opened.a",
	]);
});

Deno.test("findEventRefs: peer bob referenced by 3 events as b/to/peerId", () => {
	const doc = fixture();
	const refs = findEventRefs(primaryObservations(doc), "peer", "bob");
	assertEquals(refs.length, 3);
	const fields = refs.map((r) => `${r.event.kind}.${r.field}`).sort();
	assertEquals(fields, [
		"message-sent.to",
		"peer-joined.peerId",
		"session-opened.b",
	]);
});

Deno.test("findEventRefs: session s1 referenced by 2 events", () => {
	const doc = fixture();
	const refs = findEventRefs(primaryObservations(doc), "session", "s1");
	assertEquals(refs.length, 2);
	const fields = refs.map((r) => `${r.event.kind}.${r.field}`).sort();
	assertEquals(fields, [
		"message-sent.sessionId",
		"session-opened.sessionId",
	]);
});

Deno.test("findEventRefs: message m1 referenced by 2 events", () => {
	const doc = fixture();
	const refs = findEventRefs(primaryObservations(doc), "message", "m1");
	assertEquals(refs.length, 2);
	const fields = refs.map((r) => `${r.event.kind}.${r.field}`).sort();
	assertEquals(fields, [
		"message-delivered.messageId",
		"message-sent.messageId",
	]);
});

Deno.test("findEventRefs: unknown id returns empty", () => {
	const doc = fixture();
	assertEquals(findEventRefs(primaryObservations(doc), "peer", "carol"), []);
});

Deno.test("findEntityRefs: peer alice referenced by session.a", () => {
	const doc = fixture();
	const refs = findEntityRefs(doc, "peer", "alice");
	assertEquals(refs.length, 2); // session.a + message.from
	const sigs = refs
		.map((r) => `${r.entityKind}/${r.entityId}.${r.field}`)
		.sort();
	assertEquals(sigs, ["message/m1.from", "session/s1.a"]);
});

Deno.test("findEntityRefs: session s1 referenced by message.sessionId", () => {
	const doc = fixture();
	const refs = findEntityRefs(doc, "session", "s1");
	assertEquals(refs.length, 1);
	assertEquals(refs[0]?.entityKind, "message");
	assertEquals(refs[0]?.entityId, "m1");
	assertEquals(refs[0]?.field, "sessionId");
});

Deno.test("findEntityRefs: peer has no incoming entity refs from peers", () => {
	// Peers don't reference other peers via class-2.
	const doc = fixture();
	// No entity should reference "carol" since she doesn't exist.
	assertEquals(findEntityRefs(doc, "peer", "carol"), []);
});

Deno.test("findDocIndexRefs: peer alice appears in rowOrder.peers and rowHidden.peers", () => {
	const doc = fixture();
	const refs = findDocIndexRefs(doc, "peer", "alice");
	assertEquals(refs.length, 2);
	const names = refs.map((r) => r.edge.pathName).sort();
	assertEquals(names, ["rowHidden.peers", "rowOrder.peers"]);
});

Deno.test("findDocIndexRefs: session s1 only in rowOrder.sessions", () => {
	const doc = fixture();
	const refs = findDocIndexRefs(doc, "session", "s1");
	assertEquals(refs.length, 1);
	assertEquals(refs[0]?.edge.pathName, "rowOrder.sessions");
	assertEquals(refs[0]?.indexInList, 0);
});

Deno.test("findDocIndexRefs: id not in any list returns empty", () => {
	const doc = fixture();
	assertEquals(findDocIndexRefs(doc, "message", "m1"), []);
});
