// A private-room address waits for a restored room to state its policy, and
// stops waiting once nothing will answer. Without the bound, a reload on the
// address of a room that is gone or behind a lost directory renders nothing.

/// <reference lib="dom" />

import { assertEquals } from "../assert.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/types.ts");

function restored(name: string) {
	const projection = new store.PageProjection();
	const dir = dirId("policy-dir");
	store.openDir(projection, dir, "policy-dir");
	store.setDirSession(projection, dir, "connected");
	const room = store.ensureRoom(projection, dir, name, {
		persistId: "conv-" + name,
		policy: { visibility: "listed", entry: "open", speaking: "open" },
	});
	return { projection, dir, key: room.key };
}

Deno.test("a restored room waits for its policy while its directory can answer", () => {
	const { projection } = restored("#quiet");
	assertEquals(store.roomPolicyPending(projection.get(), "#quiet"), true);
	assertEquals(store.roomPolicyPending(projection.get(), "#other"), false);
});

Deno.test("a stated policy ends the wait", () => {
	const { projection, key } = restored("#quiet");
	const conv = store.getConv(projection, key);
	if (conv?.type !== "room") throw new Error("room fixture");
	store.setRoomPolicy(projection, key, conv.policy);
	assertEquals(store.roomPolicyPending(projection.get(), "#quiet"), false);
});

Deno.test("an unavailable room ends the wait", () => {
	const { projection, key } = restored("#gone");
	store.setRoomMembership(projection, key, "unavailable", "The room is gone.");
	assertEquals(store.roomPolicyPending(projection.get(), "#gone"), false);
});

Deno.test("a disconnected directory ends the wait", () => {
	const { projection, dir } = restored("#far");
	store.setDirSession(projection, dir, "disconnected");
	assertEquals(store.roomPolicyPending(projection.get(), "#far"), false);
	store.setDirSession(projection, dir, "reconnecting");
	assertEquals(store.roomPolicyPending(projection.get(), "#far"), true);
});
