// The rooms store's immutable attachment update boundary.
//
// Parallel transfers are coalesced before they arrive here. This proof holds
// the other half of that contract: one batch changes every named file with one
// history replacement and one reader notification, while untouched lines keep
// their identity.

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
const types = await import("../web/ui/types.ts");
const { canRetry, dirId, isUnsent } = types;
const { MAX_SCROLLBACK } = await import("../lib/limits.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("parallel attachment progress is one immutable store update", () => {
	const room = store.ensureRoom(dirId("test-dir"), "batch-progress");
	const untouched = store.chatItem("alice", "before the files", false);
	store.deliver(room.key, untouched);
	const first = store.attachmentView({ name: "first.bin", mime: "application/octet-stream", size: 100 });
	const second = store.attachmentView({ name: "second.bin", mime: "application/octet-stream", size: 200 });
	const files = store.chatItem("alice", "two files", false, undefined, [first, second]);
	store.deliver(room.key, files);

	const before = store.getConv(room.key)!;
	let notifications = 0;
	const unsubscribe = store.subscribe(() => notifications++);
	store.updateAttachments(
		room.key,
		new Map([
			[first.id, { got: 64 }],
			[second.id, { got: 128 }],
		]),
	);
	unsubscribe();

	const after = store.getConv(room.key)!;
	assert(notifications === 1, `one batch notified readers ${notifications} times`);
	assert(after.history !== before.history, "the changed history kept its old identity");
	assert(after.history[0] === before.history[0], "an untouched line was rebuilt");
	const changed = after.history[1];
	assert(changed.kind === "chat" && changed.attachments !== undefined, "the file line disappeared");
	assert(changed.attachments[0].got === 64, "the first file missed its progress");
	assert(changed.attachments[1].got === 128, "the second file missed its progress");
});

Deno.test("the viewer steps through conversation images in message order", () => {
	const room = store.ensureRoom(dirId("test-dir"), "viewer-order");
	const first = store.attachmentView({ name: "first.png", mime: "image/png", size: 1 });
	const documentFile = store.attachmentView({ name: "notes.txt", mime: "text/plain", size: 1 });
	const second = store.attachmentView({ name: "second.jpg", mime: "image/jpeg", size: 1 });
	const video = store.attachmentView({ name: "clip.mp4", mime: "video/mp4", size: 1 });
	const third = store.attachmentView({ name: "third.gif", mime: "image/gif", size: 1 });
	store.deliver(room.key, store.chatItem("alice", "standalone", false, undefined, [first]));
	store.deliver(
		room.key,
		store.chatItem("alice", "mixed gallery", false, undefined, [documentFile, second, video, third]),
	);

	// A withdrawn line past the gallery: its picture leaves the walk the way it
	// left the log, so the arrows cannot step onto a message that is gone.
	const gone = store.chatItem("alice", "taken back", false, undefined, [
		store.attachmentView({ name: "gone.png", mime: "image/png", size: 1 }),
	]);
	store.deliver(room.key, gone);
	store.nameLine(room.key, gone.id, 77);
	store.applyLineChange(room.key, 77, { withdrawn: true });

	store.openViewer(room.key, second.id);
	assert(store.stepViewer("previous") === first, "Left did not cross from a gallery to the standalone image");
	assert(store.stepViewer("previous") === null, "Left wrapped past the first image");
	assert(store.viewedAttachment(store.get()) === first, "the viewer moved at its leading edge");
	assert(store.stepViewer("next") === second, "Right did not return to the gallery image");
	assert(store.stepViewer("next") === third, "Right did not skip non-image attachments");
	assert(store.stepViewer("next") === null, "Right stepped onto a withdrawn line's picture");
	assert(store.viewedAttachment(store.get()) === third, "the viewer moved at its trailing edge");
	store.closeViewer();
});

Deno.test("a draft changing a line keeps hold of which line while it is emptied", () => {
	const room = store.ensureRoom(dirId("test-dir"), "changing-draft");
	store.switchTo(room.key);
	const mine = store.chatItem("me", "frist post", true);
	store.deliver(room.key, mine);
	store.startChange(mine.id, "frist post");
	assert(store.activeDraft().changing === mine.id, "the draft did not take the line it is changing");
	assert(store.activeDraft().text === "frist post", "the line's words did not reach the composer");
	// Selecting everything and retyping empties the box for a moment. A draft
	// dropped there would leave the words being retyped belonging to nothing,
	// and the next Enter would post them as a new message instead.
	store.setDraft("");
	assert(store.activeDraft().changing === mine.id, "emptying the box forgot which line was being changed");
	store.cancelChange();
	assert(store.activeDraft().changing === undefined, "cancelling left the line attached to the draft");
	assert(store.activeDraft().text === "", "cancelling left words in the composer");
});

Deno.test("an unsent message offers a retry only where one could work", () => {
	// The interface must never offer an action that cannot succeed. A line lost
	// with a session may go the moment one comes back; a line typed into a
	// conversation whose member has left never can, because the room has the name
	// back and the next holder is somebody else.
	assert(!isUnsent("sending"), "a line still going is not unsent");
	assert(!isUnsent(undefined), "a line that went is not unsent");
	assert(isUnsent("failed"), "a line that failed is unsent");
	assert(isUnsent("refused"), "a line that was refused is unsent");
	assert(canRetry("failed"), "a line that failed may be sent again");
	assert(!canRetry("refused"), "a line that can never go must offer no retry");
	assert(!canRetry("sending"), "a line still going needs no retry");
	assert(!canRetry(undefined), "a line that went needs no retry");
});

Deno.test("a connection ending takes what its lines could be told, not what they said", () => {
	const dir = dirId("test-dir-held");
	const room = store.ensureRoom(dir, "authority");
	store.switchTo(room.key);
	const mine = store.chatItem("alice", "said on a connection", true, undefined);
	store.deliver(room.key, mine);
	store.holdLine(room.key, mine.id);
	const held = () => {
		const conv = store.getConv(room.key);
		const line = conv?.history.find((item) => item.id === mine.id);
		return line?.kind === "chat" ? line.held : undefined;
	};
	assert(held() === true, "a line the room answered with a reference was not marked held");

	// Part way through rewriting it when the connection goes.
	store.startChange(mine.id, "said on a connection, better");
	assert(store.activeDraft().changing === mine.id, "the composer did not take the line being changed");

	const stopped = store.dropHeldLines(dir);
	assert(held() === false, "a line whose reference died with its connection is still drawn as ours to change");
	assert(stopped.includes(room.key), "the conversation whose pending change was let go was not named");
	assert(
		store.activeDraft().changing === undefined,
		"the composer is still aiming a change at a line that can no longer take one",
	);
	assert(
		store.activeDraft().text === "said on a connection, better",
		"the words being written were thrown away with the change they were aimed at",
	);

	// What was said is untouched: only what can still be done to it changed.
	const line = store.getConv(room.key)?.history.find((item) => item.id === mine.id);
	assert(line?.kind === "chat" && line.text === "said on a connection", "the line's own words were rewritten");
});

Deno.test("a conversation keeps its scrollback bounded, and says what left", () => {
	// How much a room says is the room's own choice, and the log grew with it for
	// as long as the tab was open, copying the whole of itself on every line. What
	// leaves is the oldest, and it leaves saying so: a picture's object URL and
	// the capability its bytes come from are held elsewhere, and nothing else
	// would ever tell that side the line is gone.
	const dir = dirId("test-dir-scrollback");
	const room = store.ensureRoom(dir, "long-running");
	store.switchTo(room.key);
	const dropped: number[] = [];
	store.onLinesDropped((key, gone) => {
		if (key === room.key) { for (const item of gone) dropped.push(item.id); }
	});

	const first = store.chatItem("alice", "the first thing said", false);
	store.deliver(room.key, first);
	for (let at = 1; at < MAX_SCROLLBACK; at++) {
		store.deliver(room.key, store.chatItem("alice", `line ${at}`, false));
	}
	const full = store.getConv(room.key);
	assert(full?.history.length === MAX_SCROLLBACK, `a full log holds ${full?.history.length}`);
	const earlyLosses = dropped.length;
	assert(earlyLosses === 0, "a log at its bound dropped a line it could still hold");

	const newest = store.chatItem("alice", "the newest thing said", false);
	store.deliver(room.key, newest);
	const after = store.getConv(room.key);
	assert(after?.history.length === MAX_SCROLLBACK, `one line past the bound left ${after?.history.length}`);
	const left = [...dropped];
	assert(left.length === 1 && left[0] === first.id, `what left was ${JSON.stringify(left)}`);
	assert(
		after?.history[after.history.length - 1]?.id === newest.id,
		"the newest line is not the one at the near end",
	);
	assert(
		!after?.history.some((item) => item.id === first.id),
		"the oldest line is still in a log that passed its bound",
	);

	// Nobody is left holding a rule against a line nobody can scroll to.
	const anchored = store.getConv(room.key)?.unread;
	if (anchored?.kind === "unread" || anchored?.kind === "rule-only") {
		assert(
			after?.history.some((item) => item.id === anchored.from),
			"the unread rule hangs on a line that has left the log",
		);
	}
	store.onLinesDropped(() => {});
});

Deno.test("an ignored line does not count at the reader, and their own always does", () => {
	// One rule, three consumers — the log's draw filter, the unread count, and
	// the notification gates — and the half that once failed silently: a reader
	// whose own current name sits on their ignore list. Ignoring is about not
	// hearing somebody else, so their own lines stay heard however the list
	// reads; a stranger's under an ignored name is silent everywhere at once,
	// because a badge lighting for a line that will never draw teaches a reader
	// to stop trusting the badge.
	const { silencedByIgnore } = types;
	const ignored = new Set(["jim"]);
	const theirs = store.chatItem("Jim", "from the other jim", false);
	const mine = store.chatItem("Jim", "my own line", true);
	assert(silencedByIgnore(theirs, ignored), "a stranger's line under an ignored name is heard");
	assert(!silencedByIgnore(mine, ignored), "the reader's own line is silenced by their own ignore");
	assert(
		!silencedByIgnore(store.sysItem("jim joined"), ignored),
		"a system line is silenced by an ignore",
	);

	// And the unread count follows the same answer. The conversation is not the
	// active one, so a counted line would light its badge.
	store.ignore("jim");
	const room = store.ensureRoom(dirId("test-dir"), "ignored-count");
	store.switchTo(store.ensureRoom(dirId("test-dir"), "elsewhere").key);
	store.deliver(room.key, store.chatItem("Jim", "never drawn", false));
	assert(
		store.getConv(room.key)?.unread.kind === "caught-up",
		"a line the reader will never see lit the unread badge",
	);
	store.deliver(room.key, store.chatItem("Jim", "my own, echoed back", true));
	assert(
		store.getConv(room.key)?.unread.kind === "unread",
		"the reader's own line stopped counting because their name is on their ignore list",
	);
	store.unignore("jim");
});

Deno.test("the ignore list survives a name with a comma in it across a reload", () => {
	// The list holds whatever names foreign directories grant, and a name may
	// contain the delimiter an older build joined on: `a,b` re-split into `a`
	// and `b`, silently un-ignoring the offender and ignoring two innocents —
	// the vanishing this list's own fix paid for, back through the encoding.
	const KEY = "rooms.ignored";
	localStorage.setItem(KEY, JSON.stringify(["a,b", "carol"]));
	const round = store.readPersistedIgnored();
	assert(round.has("a,b"), "a comma-bearing name did not round-trip");
	assert(round.has("carol") && round.size === 2, `the reload mangled the list: ${[...round].join("|")}`);
	// An older visit's comma-joined list is still read, so nobody's list is lost.
	localStorage.setItem(KEY, "dave,erin");
	const legacy = store.readPersistedIgnored();
	assert(legacy.has("dave") && legacy.has("erin"), "a legacy comma-joined list was dropped");
	localStorage.removeItem(KEY);
});

Deno.test("clearing a conversation hands back what its lines were holding", () => {
	// /clear is the third way lines leave the log, and it has to leave through
	// the same door: the release seam that the scrollback trim and a closing
	// conversation use to give back object URLs, blob capabilities, and the
	// references governing our own lines.
	const room = store.ensureRoom(dirId("test-dir"), "clear-release");
	let released: readonly unknown[] = [];
	store.onLinesDropped((key, gone) => {
		if (key === room.key) released = gone;
	});
	store.deliver(room.key, store.chatItem("alice", "one", false));
	store.deliver(room.key, store.chatItem("alice", "two", false));
	store.clearHistory(room.key);
	assert(released.length === 2, `clearing did not hand its lines to the release seam: ${released.length}`);
	assert(store.getConv(room.key)?.history.length === 0, "the history was not actually cleared");
});

Deno.test("the last submitted line is recalled per conversation, including a command", () => {
	const room = store.ensureRoom(dirId("test-dir"), "recall-here");
	const other = store.ensureRoom(dirId("test-dir"), "recall-there");
	store.rememberLastSent(room.key, "/ignore alice");
	store.rememberLastSent(other.key, "hello");
	assert(store.lastSentFor(room.key) === "/ignore alice", "a command was not kept to recall");
	assert(store.lastSentFor(other.key) === "hello", "a later room overwrote the first");
	store.forgetConv(room.key);
	assert(store.lastSentFor(room.key) === undefined, "leaving a room kept its last line");
	assert(store.lastSentFor(other.key) === "hello", "forgetting one room forgot another");
});

const joining = await import("../web/ui/joining.ts");

Deno.test("empty and this directory's locator are one destination", () => {
	const home = dirId("ocapn://abc.iroh");
	assert(joining.thisDirectoryLocator("", home) === "", "an empty locator was not this directory");
	assert(
		joining.thisDirectoryLocator("ocapn://abc.iroh", home) === "",
		"this directory's locator was kept as a distinct value",
	);
	assert(joining.thisDirectoryLocator(" ocapn://abc.iroh\n", home) === "", "a pasted home locator was not cleared");
	assert(
		joining.thisDirectoryLocator("ocapn://other.iroh", home) === "ocapn://other.iroh",
		"a foreign locator was treated as this directory",
	);
});

Deno.test("an empty locator field hints at this directory's shared address", () => {
	// The placeholder shortens the same route every share surface hands out
	// (`peer.dirAddress`), so the hint agrees with the Settings and directory
	// cards rather than showing the store's bare authority key.
	assert(
		joining.joinLocatorPlaceholder(null) === joining.JOIN_LOCATOR_SHAPE,
		"a page with no home invented an address",
	);
	assert(
		joining.joinLocatorPlaceholder("ocapn://abc.iroh") === "ocapn://abc.iroh",
		"a short locator was shortened",
	);
	assert(
		joining.joinLocatorPlaceholder(
			"ocapn://abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqr.iroh",
		) === "ocapn://abcd…mnopqr.iroh",
		"a long locator was not shown as head, tail, and transport",
	);
	assert(
		joining.joinLocatorPlaceholder(
			"ocapn://abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqr.iroh?direct-addresses=127.0.0.1:1",
		) === "ocapn://abcd…mnopqr.iroh",
		"the shared hinted route kept its query parameters in the hint",
	);
	assert(
		joining.joinLocatorPlaceholder("127.0.0.1:8000") === "127.0.0.1:8000",
		"a host locator was rewritten as an ocapn URI",
	);
});

Deno.test("this directory wears one mark across the page", () => {
	const home = dirId("ocapn://abc.iroh");
	const other = dirId("ocapn://other.iroh");
	assert(types.dirMark(home, home, 1) === "home", "this directory wore a ramp slot");
	assert(types.dirMark(other, home, 2) === "2", "a foreign directory did not wear its slot");
	assert(types.dirMark(home, null, 1) === "1", "with no home, a directory was treated as this page's");
});

Deno.test("a direct line is not opened with yourself", () => {
	const dir = dirId("self-dm");
	store.openDir(dir);
	store.setDirNick(dir, "alice");
	assert(store.isSelf(dir, "Alice"), "own nick is compared the way the directory grants it");
	assert(!store.isSelf(dir, "bo"), "somebody else counted as you");
	assert(store.ensureDm(dir, "alice") === null, "ensureDm minted a conversation with yourself");
	const other = store.ensureDm(dir, "bo");
	assert(other !== null && other.type === "dm", "a line to somebody else was not opened");
});

Deno.test("a direct row relays the rooms' word on who is away", () => {
	const dir = dirId("ocapn://abc.iroh");
	const other = dirId("ocapn://other.iroh");
	const room = (at: typeof dir, members: Record<string, { online: boolean; away: string }>) =>
		({
			type: "room",
			dir: at,
			members: new Map(Object.entries(members)),
		}) as unknown as import("../web/ui/types.ts").Conv;
	const convs = new Map([
		// Away in one room, present in another: present wins, because a direct
		// line reaches the person and the person is at their desk.
		["a", room(dir, { Bo: { online: true, away: "lunch" }, Cy: { online: true, away: "brb" } })],
		["b", room(dir, { Bo: { online: true, away: "" }, Dee: { online: false, away: "gone" } })],
		// The same nick on another directory is a different person.
		["c", room(other, { Cy: { online: true, away: "" } })],
	]);
	const words = types.awayByPeer(convs);
	assert(types.awayOf(words, dir, "bo") === null, "present in one room did not beat away in another");
	assert(types.awayOf(words, dir, "BO") === null, "the nick was not matched the way dmable names are");
	assert(types.awayOf(words, dir, "cy") === "brb", "away everywhere online did not carry its reason");
	assert(types.awayOf(words, dir, "dee") === null, "an offline member's stale reason was relayed");
	assert(types.awayOf(words, other, "cy") === null, "a directory read another directory's roster");
});
