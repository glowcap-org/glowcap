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

Deno.test("forgetting a directory settles the card that was viewing its authority", () => {
	const projection = new store.PageProjection();
	const directory = dirId("departing-dir");
	store.openDir(projection, directory, "departing-dir");
	store.showAboutDir(projection, directory, true);

	store.forgetDir(projection, directory);

	assert(projection.get().aboutDir === null, "the removed directory left its card intent standing");
	assert(projection.get().aboutDirLeave === false, "the removed directory left its confirmation intent standing");
	store.openDir(projection, directory, "departing-dir");
	assert(projection.get().aboutDir === null, "reacquiring the directory reopened its old card");
});

Deno.test("the title's close mark asks to leave a room without leaving yet", () => {
	const projection = new store.PageProjection();
	const directory = dirId("home-dir");
	store.openDir(projection, directory, "home-dir");
	const conv = store.ensureRoom(projection, directory, "lobby");
	store.switchTo(projection, conv.key);
	store.showAboutConv(projection, "bridge", true);
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

Deno.test("remembering a submission after its conversation left preserves the next draft", () => {
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
	store.rememberLastSent(projection, leave.key, "/leave");
	assert(
		store.draftFor(projection, keep.key).text === "keep me",
		"clearing a conversation that had left emptied the next one's draft",
	);
	assert(
		store.lastSentFor(projection, leave.key) === undefined,
		"last sent was revived on a conversation that had left",
	);
});
