// Both Rooms controllers finish a composer submission through one commit:
// a refusal is delivered there, and a finished line empties the conversation
// that was composed. Tab commands run even with no live session; chat does not.

/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

const store = await import("../web/ui/store.ts");
const { dirId } = await import("../web/ui/types.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { send } = await import("../web/ui/net.ts");
const { attachedCommandPowers } = await import("../web/ui/session/attached_command_powers.ts");
const { attachedComposerActions } = await import("../web/ui/session/attached_composer.ts");
const { COMPOSER_NOT_CONNECTED } = await import("../web/ui/composer/commit.ts");
const { DIRECTORY_NO_CHAT } = await import("../web/ui/composer/send.ts");
const { notRegisteredForDirect } = await import("../web/ui/commands/targets.ts");
const { PageProjection } = store;

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

function saidHere(projection: InstanceType<typeof PageProjection>, key: string): string {
	return store.historyOf(projection, key)
		.flatMap((item) => item.kind === "sys" ? [item.text] : [])
		.join("\n");
}

Deno.test("a tab command in a room runs without a live session", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const room = store.ensureRoom(page.projection, directory, "lobby");
	store.switchTo(page.projection, room.key);
	store.setDraft(page.projection, "/help");
	send(page);
	const said = saidHere(page.projection, room.key);
	assert(said.includes("You can use:"), "a room /help did not run while disconnected");
	assert(!said.includes(COMPOSER_NOT_CONNECTED), "a tab command was refused as unsent chat");
	assert(store.activeDraft(page.projection).text === "", "running /help left the field filled");
});

Deno.test("chat in a room still needs a live session", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const room = store.ensureRoom(page.projection, directory, "lobby");
	store.switchTo(page.projection, room.key);
	store.setDraft(page.projection, "hello");
	send(page);
	const said = saidHere(page.projection, room.key);
	assert(said.includes(COMPOSER_NOT_CONNECTED), "chat while disconnected did not say so");
	assert(store.activeDraft(page.projection).text === "hello", "unsent chat was cleared as if it had gone");
});

Deno.test("a refused line is delivered without emptying the composer", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const conv = store.ensureDirectory(page.projection, directory);
	store.switchTo(page.projection, conv.key);
	store.setDraft(page.projection, "hello");
	send(page);
	assert(
		saidHere(page.projection, conv.key).includes(DIRECTORY_NO_CHAT),
		"a directory chat line was not refused",
	);
	assert(store.activeDraft(page.projection).text === "hello", "a refused line emptied the composer");
});

Deno.test("a command that cannot act keeps the draft", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const conv = store.ensureDirectory(page.projection, directory);
	store.switchTo(page.projection, conv.key);
	store.setDraft(page.projection, "/msg alice");
	send(page);
	assert(
		saidHere(page.projection, conv.key).includes(notRegisteredForDirect("alice")),
		"a /msg with no introduction did not refuse",
	);
	assert(store.activeDraft(page.projection).text === "/msg alice", "a refused /msg emptied the composer");
});

Deno.test("local send empties the conversation that was composed", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const keep = store.ensureRoom(page.projection, directory, "keep");
	store.switchTo(page.projection, keep.key);
	store.setDraft(page.projection, "keep me");
	const leave = store.ensureRoom(page.projection, directory, "leave");
	store.switchTo(page.projection, leave.key);
	store.setDraft(page.projection, "/leave");
	send(page);
	assert(store.getConv(page.projection, leave.key) === null, "sending /leave left the room");
	assert(page.projection.get().activeKey === keep.key, "sending /leave did not return to the other room");
	assert(
		store.draftFor(page.projection, keep.key).text === "keep me",
		"local /leave emptied the next conversation's draft",
	);
});

Deno.test("attached send empties the conversation that was composed", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const keep = store.ensureRoom(page.projection, directory, "keep", { persistId: "keep-id" });
	store.switchTo(page.projection, keep.key);
	store.setDraft(page.projection, "keep me");
	const leave = store.ensureRoom(page.projection, directory, "leave", { persistId: "leave-id" });
	store.switchTo(page.projection, leave.key);
	const controller = {
		stageDraft: () => {},
		setDraft: () => Promise.resolve(),
		retireDraft: () => {},
		leaveConversation: () => {
			store.forgetConv(page.projection, leave.key);
			store.switchTo(page.projection, keep.key);
			return Promise.resolve();
		},
	};
	const powers = attachedCommandPowers(page.projection, controller as never, {} as never, () => {});
	const actions = attachedComposerActions(page.projection, controller as never, powers, () => {});
	actions.setDraft("/leave");
	actions.send();
	assert(
		store.draftFor(page.projection, keep.key).text === "keep me",
		"attached /leave emptied the next conversation's draft",
	);
});

Deno.test("attached send of a command that cannot act keeps the draft", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const conv = store.ensureDirectory(page.projection, directory);
	store.switchTo(page.projection, conv.key);
	const controller = {
		stageDraft: () => {},
		setDraft: () => Promise.resolve(),
		retireDraft: () => {},
	};
	const powers = attachedCommandPowers(page.projection, controller as never, {} as never, () => {});
	const actions = attachedComposerActions(page.projection, controller as never, powers, () => {});
	actions.setDraft("/msg alice");
	actions.send();
	assert(
		saidHere(page.projection, conv.key).includes(notRegisteredForDirect("alice")),
		"attached /msg with no introduction did not refuse",
	);
	assert(store.activeDraft(page.projection).text === "/msg alice", "a refused attached /msg emptied the composer");
});
