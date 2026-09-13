// Conversation traffic updates its own store slice without replacing the application shell projection.
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

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

function shellSame(
	before: ReturnType<typeof store.appShellState>,
	after: ReturnType<typeof store.appShellState>,
): boolean {
	for (const key of Object.keys(before) as (keyof typeof before)[]) {
		if (before[key] !== after[key]) return false;
	}
	return Object.keys(after).length === Object.keys(before).length;
}

Deno.test("a line does not replace the shell projection or the open conversation", () => {
	projection.reset();
	const open = store.ensureRoom(projection, dirId("test-dir"), "open-room");
	const other = store.ensureRoom(projection, dirId("test-dir"), "other-room");
	projection.set({ activeKey: open.key });
	const shell = store.appShellState(projection.get());
	const active = store.activeConvOf(projection.get());
	assert(active != null, "the open conversation was missing");
	assert(!("convs" in shell), "the shell projection still carried the conversation map");
	store.deliver(projection, other.key, store.chatItem(projection, "ada", "elsewhere", false));
	assert(store.activeConvOf(projection.get()) === active, "a line in another room replaced the open conversation");
	assert(shellSame(shell, store.appShellState(projection.get())), "a line in another room replaced a shell field");
	assert(store.unreadTotal(projection.get()) > 0, "the other room's line was not counted unread");
	store.deliver(projection, open.key, store.chatItem(projection, "ada", "here", false));
	assert(store.activeConvOf(projection.get()) === active, "a line in the open room replaced the conversation");
	assert(shellSame(shell, store.appShellState(projection.get())), "a line in the open room replaced a shell field");
	assert(store.historyOf(projection, open.key).length > 0, "the open room's line was not recorded");
});
