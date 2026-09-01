// A held directory has a conversation of its own: a view, not a room and not a
// workspace row. Pressing the directory selects that view; the card still opens
// from the title. The title's close mark asks to leave, in that card. An empty
// directory's rail row stays while only that view is open, because empty means
// no rooms and no direct lines. The composer is a command line for that
// directory: commands run, their results stay here, and there is no chat.

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
const { workspaceStateOf } = await import("../web/ui/workspace_state.ts");
const { leaveDirectory, send } = await import("../web/ui/net.ts");
const { finishComposerSend } = await import("../web/ui/composer/commit.ts");
const { attachedCommandPowers } = await import("../web/ui/session/attached_command_powers.ts");
const { attachedComposerActions } = await import("../web/ui/session/attached_composer.ts");
const { AttachedSessionProjection } = await import("../web/ui/session/projection.ts");
const { emptyRoomsSessionState } = await import("../lib/rooms_state.ts");
const { adminSessionView } = await import("./support/session_snapshot.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("a directory conversation does not fill a directory's empty rail row", () => {
	const projection = new store.PageProjection();
	const home = dirId("home-dir");
	const other = dirId("other-dir");
	store.openDir(projection, home, "home-dir");
	store.openDir(projection, other, "other-dir");
	store.setHomeDir(projection, home);
	store.ensureDirectory(projection, other);
	const empty = store.emptyDirs(projection.get());
	assert(empty.some((dir) => dir.id === other), "a directory with only its view hid its empty row");
	assert(!empty.some((dir) => dir.id === home), "this page's directory wore an empty row");
	store.ensureRoom(projection, other, "lobby");
	assert(
		!store.emptyDirs(projection.get()).some((dir) => dir.id === other),
		"a directory with a room still looked empty",
	);
});

Deno.test("a directory view is selected without opening its card, and putting it away forgets it", () => {
	const projection = new store.PageProjection();
	const directory = dirId("shown-dir");
	store.openDir(projection, directory, "shown-dir");
	const conv = store.ensureDirectory(projection, directory);
	store.switchTo(projection, conv.key);
	assert(projection.get().activeKey === conv.key, "the directory view was not selected");
	assert(projection.get().aboutDir === null, "selecting a directory opened its card");
	store.showAboutDir(projection, directory);
	assert(projection.get().aboutDir === directory, "the directory card did not open from about");
	store.dismissDirectoryView(projection, conv.key);
	assert(projection.get().activeKey === null, "closing the directory view did not put the join card up");
	assert(store.getConv(projection, conv.key) === null, "closing the directory view left its row");
});

Deno.test("the title's close mark asks to leave the directory without leaving yet", () => {
	const projection = new store.PageProjection();
	const directory = dirId("shown-dir");
	store.openDir(projection, directory, "shown-dir");
	const conv = store.ensureDirectory(projection, directory);
	store.switchTo(projection, conv.key);
	store.showAboutDir(projection, directory, true);
	assert(projection.get().aboutDir === directory, "asking to leave did not open the directory card");
	assert(projection.get().aboutDirLeave === true, "the directory card did not open already asking");
	assert(store.getConv(projection, conv.key)?.type === "directory", "asking to leave dropped the directory view");
	assert(projection.get().dirs.has(directory), "asking to leave dropped the directory");
	store.showAboutDir(projection, directory);
	assert(projection.get().aboutDirLeave === false, "opening the card about the directory left it asking to leave");
});

Deno.test("the title's close mark asks to leave a room without leaving yet", () => {
	const projection = new store.PageProjection();
	const directory = dirId("home-dir");
	store.openDir(projection, directory, "home-dir");
	const conv = store.ensureRoom(projection, directory, "lobby");
	store.switchTo(projection, conv.key);
	store.showAboutConv(projection, "irc", true);
	assert(projection.get().aboutConv, "asking to leave did not open the conversation card");
	assert(projection.get().aboutConvLeave === true, "the conversation card did not open already asking");
	assert(projection.get().aboutConvPane === "about", "asking to leave opened a pane other than about");
	assert(store.getConv(projection, conv.key)?.type === "room", "asking to leave dropped the room");
	store.showAboutConv(projection);
	assert(projection.get().aboutConvLeave === false, "opening the card about the room left it asking to leave");
});

Deno.test("leaving a room does not return to a directory view that was only looked at", () => {
	const projection = new store.PageProjection();
	const directory = dirId("home-dir");
	store.openDir(projection, directory, "home-dir");
	store.setHomeDir(projection, directory);
	const view = store.ensureDirectory(projection, directory);
	const lobby = store.ensureRoom(projection, directory, "lobby");
	const aside = store.ensureRoom(projection, directory, "aside");
	store.switchTo(projection, view.key);
	store.switchTo(projection, aside.key);
	store.forgetConv(projection, aside.key);
	const next = store.nextStandingKey(projection.get().convs);
	assert(next === lobby.key, "leaving a room returned to a directory view instead of the room behind it");
	assert(store.getConv(projection, view.key)?.type === "directory", "leaving a room dropped the directory view");
});

Deno.test("leaving a directory you are viewing lands on a room still held", () => {
	const page = new RoomsPage();
	const home = dirId("home-dir");
	const other = dirId("other-dir");
	store.openDir(page.projection, home, "home-dir");
	store.openDir(page.projection, other, "other-dir");
	store.setHomeDir(page.projection, home);
	const lobby = store.ensureRoom(page.projection, home, "lobby");
	store.ensureRoom(page.projection, other, "elsewhere");
	const view = store.ensureDirectory(page.projection, other);
	store.switchTo(page.projection, view.key);
	leaveDirectory(page, other);
	assert(
		page.projection.get().activeKey === lobby.key,
		"leaving a directory dumped the join card while a room remained",
	);
	assert(store.getConv(page.projection, view.key) === null, "leaving a directory left its view");
});

Deno.test("a directory conversation is a view, not a workspace row", () => {
	const page = new RoomsPage();
	const directory = dirId("ocapn://directory.id");
	store.openDir(page.projection, directory, directory);
	store.setHomeDir(page.projection, directory);
	store.ensureRoom(page.projection, directory, "general");
	const view = store.ensureDirectory(page.projection, directory);
	store.switchTo(page.projection, view.key);
	const document = workspaceStateOf(page, page.projection.get());
	assert(
		!document.session.conversations.some((conversation) => conversation.id === view.key),
		"the directory view was written into the workspace",
	);
	assert(document.session.active === null, "a directory view was remembered as the active conversation");
	assert(
		document.session.conversations.some((conversation) =>
			conversation.kind === "room" && conversation.name === "general"
		),
		"serializing a directory view dropped the room beside it",
	);
});

Deno.test("attached /leave on a directory view puts the view away without a session leave", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const conv = store.ensureDirectory(page.projection, directory);
	store.switchTo(page.projection, conv.key);
	const removed: string[] = [];
	const powers = attachedCommandPowers(
		page.projection,
		{
			leaveConversation: (id: string) => {
				removed.push(id);
				return Promise.resolve();
			},
		} as never,
		{} as never,
		() => {},
	);
	powers.leaveHere();
	assert(removed.length === 0, "leaveHere asked the session to leave a directory view");
	assert(store.getConv(page.projection, conv.key) === null, "leaveHere did not put the directory view away");
});

Deno.test("sending /leave on a directory view does not empty another conversation's draft", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const lobby = store.ensureRoom(page.projection, directory, "lobby", { persistId: "lobby-id" });
	store.switchTo(page.projection, lobby.key);
	store.setDraft(page.projection, "keep me");
	const conv = store.ensureDirectory(page.projection, directory);
	store.switchTo(page.projection, conv.key);
	const controller = {
		stageDraft: () => {},
		setDraft: () => Promise.resolve(),
		retireDraft: () => {},
	};
	const powers = attachedCommandPowers(page.projection, controller as never, {} as never, () => {});
	const actions = attachedComposerActions(page.projection, controller as never, powers, () => {});
	actions.setDraft("/leave");
	actions.send();
	assert(store.getConv(page.projection, conv.key) === null, "sending /leave left the directory view");
	assert(page.projection.get().activeKey === lobby.key, "sending /leave did not return to the room");
	assert(
		store.draftFor(page.projection, lobby.key).text === "keep me",
		"sending /leave emptied the room's draft",
	);
});

Deno.test("clearing the composer after a conversation has left does not empty the next one's draft", () => {
	const projection = new store.PageProjection();
	const directory = dirId("shown-dir");
	store.openDir(projection, directory, "shown-dir");
	const keep = store.ensureRoom(projection, directory, "keep");
	const leave = store.ensureRoom(projection, directory, "leave");
	store.switchTo(projection, keep.key);
	store.setDraft(projection, "keep me");
	store.switchTo(projection, leave.key);
	store.forgetConv(projection, leave.key);
	store.switchTo(projection, keep.key);
	finishComposerSend(projection, leave.key, "/leave");
	assert(
		store.draftFor(projection, keep.key).text === "keep me",
		"clearing a conversation that had left emptied the next one's draft",
	);
	assert(
		store.lastSentFor(projection, leave.key) === undefined,
		"last sent was revived on a conversation that had left",
	);
});

Deno.test("a directory command runs without a live directory session", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const conv = store.ensureDirectory(page.projection, directory);
	store.switchTo(page.projection, conv.key);
	store.setDraft(page.projection, "/help");
	send(page);
	const said = store.historyOf(page.projection, conv.key)
		.flatMap((item) => item.kind === "sys" ? [item.text] : [])
		.join("\n");
	assert(said.includes("You can use:"), "a directory /help did not run while disconnected");
	assert(said.includes("/join:"), "/help on a directory omitted a tab command");
	assert(!said.includes("/me:"), "/help on a directory listed a chat command");
	assert(store.activeDraft(page.projection).text === "", "running /help left the field filled");
});

Deno.test("attached drafts on a directory view stay in this tab", () => {
	const page = new RoomsPage();
	const directory = dirId("shown-dir");
	store.openDir(page.projection, directory, "shown-dir");
	const conv = store.ensureDirectory(page.projection, directory);
	store.switchTo(page.projection, conv.key);
	const staged = new Map<string, string>();
	const draftWrites: Array<{ id: string; text: string }> = [];
	const controller = {
		stageDraft: (id: string, text: string) => {
			staged.set(id, text);
		},
		setDraft: (id: string, text: string) => {
			draftWrites.push({ id, text });
			return Promise.resolve();
		},
		retireDraft: () => {},
	};
	const powers = attachedCommandPowers(page.projection, controller as never, {} as never, () => {});
	const actions = attachedComposerActions(page.projection, controller as never, powers, () => {});
	actions.setDraft("/help");
	assert(staged.size === 0, "staging a directory draft wrote it into the session");
	assert(store.activeDraft(page.projection).text === "/help", "the directory draft did not stay in this tab");
	actions.send();
	assert(draftWrites.length === 0, "running a directory command wrote a session draft");
	assert(store.activeDraft(page.projection).text === "", "running a directory command left the field filled");
});

Deno.test("an attached snapshot keeps a directory view this tab opened", () => {
	const page = new RoomsPage();
	const directory = dirId("directory");
	store.openDir(page.projection, directory, "127.0.0.1:1");
	store.setHomeDir(page.projection, directory);
	store.ensureRoom(page.projection, directory, "general", { persistId: "room-id" });
	const attached = new AttachedSessionProjection(page);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "room-id",
			directory: "directory",
			name: "general",
			held: false,
			standing: null,
			draft: "",
		}],
		active: "room-id",
	};
	attached.apply({
		revision: 1,
		...adminSessionView(),
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: ["directory"],
		memberLocator: null,
		roomViews: [],
	});
	const view = store.ensureDirectory(page.projection, directory);
	store.switchTo(page.projection, view.key);
	attached.apply({
		revision: 2,
		...adminSessionView(),
		checkpoint: {
			...checkpoint,
			conversations: [
				checkpoint.conversations[0]!,
				{
					kind: "room" as const,
					id: "room-2",
					directory: "directory",
					name: "aside",
					held: false,
					standing: null,
					draft: "",
				},
			],
		},
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: ["directory"],
		memberLocator: null,
		roomViews: [],
	});
	assert(store.getConv(page.projection, view.key)?.type === "directory", "a snapshot forgot the directory view");
	assert(page.projection.get().activeKey === view.key, "a snapshot took the reader off the directory view");
});
