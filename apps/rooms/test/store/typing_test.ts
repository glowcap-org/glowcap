// Typing projection changes only ephemeral composition state and retires it with the conversation.
/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

const store = await import("../../web/ui/store.ts");
const projection = new store.PageProjection();
const { dirId } = await import("../../web/ui/types.ts");
const { assertEquals } = await import("../assert.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("a typing flag does not replace the conversation", () => {
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "typing-identity");
	const before = store.getConv(projection, room.key);
	store.setTyper(projection, room.key, "bob", true);
	assert(store.getConv(projection, room.key) === before, "typing replaced the conversation");
	assertEquals([...store.typersOf(projection, room.key)], ["bob"]);
	store.setTyper(projection, room.key, "bob", true);
	assert(store.getConv(projection, room.key) === before, "a repeated flag replaced the conversation");
	store.setTyper(projection, room.key, "bob", false);
	assertEquals([...store.typersOf(projection, room.key)], []);
	assert(store.getConv(projection, room.key) === before, "clearing typing replaced the conversation");
});

Deno.test("forgetting a conversation forgets who was composing in it", () => {
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "typing-forget");
	store.setTyper(projection, room.key, "bob", true);
	store.forgetConv(projection, room.key);
	assertEquals([...store.typersOf(projection, room.key)], []);
	store.setTyper(projection, room.key, "bob", true);
	assertEquals([...store.typersOf(projection, room.key)], []);
});
