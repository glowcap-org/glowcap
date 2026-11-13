import { assertEquals } from "@std/assert";
import { smallFixture } from "./schema-test/harness.ts";
import { findDocIndexRefs, findEntityRefs } from "./walk.ts";

Deno.test("findEntityRefs: peer alice referenced by session.a", () => {
	const doc = smallFixture();
	const refs = findEntityRefs(doc, "peer", "alice");
	assertEquals(refs.length, 2); // session.a + message.from
	const sigs = refs
		.map((r) => `${r.entityKind}/${r.entityId}.${r.field}`)
		.sort();
	assertEquals(sigs, ["message/m1.from", "session/s1.a"]);
});

Deno.test("findEntityRefs: session s1 referenced by message.sessionId", () => {
	const doc = smallFixture();
	const refs = findEntityRefs(doc, "session", "s1");
	assertEquals(refs.length, 1);
	assertEquals(refs[0]?.entityKind, "message");
	assertEquals(refs[0]?.entityId, "m1");
	assertEquals(refs[0]?.field, "sessionId");
});

Deno.test("findEntityRefs: peer has no incoming entity refs from peers", () => {
	// Peers don't reference other peers via class-2.
	const doc = smallFixture();
	// No entity should reference "carol" since she doesn't exist.
	assertEquals(findEntityRefs(doc, "peer", "carol"), []);
});

Deno.test("findDocIndexRefs: peer alice appears in rowOrder.peers and rowHidden.peers", () => {
	const doc = smallFixture();
	const refs = findDocIndexRefs(doc, "peer", "alice");
	assertEquals(refs.length, 2);
	const names = refs.map((r) => r.edge.pathName).sort();
	assertEquals(names, ["rowHidden.peers", "rowOrder.peers"]);
});

Deno.test("findDocIndexRefs: session s1 only in rowOrder.sessions", () => {
	const doc = smallFixture();
	const refs = findDocIndexRefs(doc, "session", "s1");
	assertEquals(refs.length, 1);
	assertEquals(refs[0]?.edge.pathName, "rowOrder.sessions");
	assertEquals(refs[0]?.indexInList, 0);
});

Deno.test("findDocIndexRefs: id not in any list returns empty", () => {
	const doc = smallFixture();
	assertEquals(findDocIndexRefs(doc, "message", "m1"), []);
});
