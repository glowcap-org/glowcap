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

const store = await import("../../web/ui/store.ts");
const { authorityToken } = await import("../../web/ui/store/rooms.ts");
const projection = new store.PageProjection();
const types = await import("../../web/ui/types.ts");
const { canRetry, dirId, isUnsent, sendControlsFor } = types;
const { MAX_SCROLLBACK } = await import("../../lib/limits.ts");
const { registrationId } = await import("../support/registration.ts");
const { roomAuthorityToken } = await import("../../lib/room/authority.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("parallel attachment progress is one immutable store update", () => {
	const room = store.ensureRoom(projection, dirId("test-dir"), "batch-progress");
	const untouched = store.chatItem(projection, "alice", "before the files", false);
	store.deliver(projection, room.key, untouched);
	const first = store.attachmentView(projection, { name: "first.bin", mime: "application/octet-stream", size: 100 });
	const second = store.attachmentView(projection, {
		name: "second.bin",
		mime: "application/octet-stream",
		size: 200,
	});
	const files = store.chatItem(projection, "alice", "two files", false, undefined, [first, second]);
	store.deliver(projection, room.key, files);

	const beforeConv = store.getConv(projection, room.key)!;
	const before = store.historyOf(projection, room.key);
	let notifications = 0;
	const unsubscribe = projection.subscribe(() => notifications++);
	store.updateAttachments(
		projection,
		room.key,
		new Map([
			[first.id, { got: 64 }],
			[second.id, { got: 128 }],
		]),
	);
	unsubscribe();

	const afterConv = store.getConv(projection, room.key)!;
	const after = store.historyOf(projection, room.key);
	assert(notifications === 1, `one batch notified readers ${notifications} times`);
	assert(afterConv === beforeConv, "updating files replaced the conversation");
	assert(after !== before, "the changed history kept its old identity");
	assert(after[0] === before[0], "an untouched line was rebuilt");
	const changed = after[1];
	assert(changed.kind === "chat" && changed.attachments !== undefined, "the file line disappeared");
	assert(changed.attachments[0].got === 64, "the first file missed its progress");
	assert(changed.attachments[1].got === 128, "the second file missed its progress");
});

Deno.test("the viewer steps through conversation images in message order", () => {
	const room = store.ensureRoom(projection, dirId("test-dir"), "viewer-order");
	const first = store.attachmentView(projection, { name: "first.png", mime: "image/png", size: 1 });
	const documentFile = store.attachmentView(projection, { name: "notes.txt", mime: "text/plain", size: 1 });
	const second = store.attachmentView(projection, { name: "second.jpg", mime: "image/jpeg", size: 1 });
	const video = store.attachmentView(projection, { name: "clip.mp4", mime: "video/mp4", size: 1 });
	const third = store.attachmentView(projection, { name: "third.gif", mime: "image/gif", size: 1 });
	store.deliver(projection, room.key, store.chatItem(projection, "alice", "standalone", false, undefined, [first]));
	store.deliver(
		projection,
		room.key,
		store.chatItem(projection, "alice", "mixed gallery", false, undefined, [documentFile, second, video, third]),
	);

	// A withdrawn line past the gallery: its picture leaves the walk the way it
	// left the log, so the arrows cannot step onto a message that is gone.
	const gone = store.chatItem(projection, "alice", "taken back", false, undefined, [
		store.attachmentView(projection, { name: "gone.png", mime: "image/png", size: 1 }),
	]);
	store.deliver(projection, room.key, gone);
	store.updateItem(projection, room.key, gone.id, { lineId: 77 });
	store.applyLineChange(projection, room.key, 77, { withdrawn: true });

	store.openViewer(projection, room.key, second.id);
	assert(
		store.stepViewer(projection, "previous") === first,
		"Left did not cross from a gallery to the standalone image",
	);
	assert(store.stepViewer(projection, "previous") === null, "Left wrapped past the first image");
	assert(store.viewedAttachment(projection.get()) === first, "the viewer moved at its leading edge");
	assert(store.stepViewer(projection, "next") === second, "Right did not return to the gallery image");
	assert(store.stepViewer(projection, "next") === third, "Right did not skip non-image attachments");
	assert(store.stepViewer(projection, "next") === null, "Right stepped onto a withdrawn line's picture");
	assert(store.viewedAttachment(projection.get()) === third, "the viewer moved at its trailing edge");
	store.closeViewer(projection);
});

Deno.test("a draft changing a line keeps hold of which line while it is emptied", () => {
	const room = store.ensureRoom(projection, dirId("test-dir"), "changing-draft");
	store.switchTo(projection, room.key);
	const mine = store.chatItem(projection, "me", "frist post", true);
	store.deliver(projection, room.key, mine);
	store.startChange(projection, mine.id, "frist post");
	assert(store.activeDraft(projection).changing === mine.id, "the draft did not take the line it is changing");
	assert(store.activeDraft(projection).text === "frist post", "the line's words did not reach the composer");
	// Selecting everything and retyping empties the box for a moment. A draft
	// dropped there would leave the words being retyped belonging to nothing,
	// and the next Enter would post them as a new message instead.
	store.setDraft(projection, "");
	assert(store.activeDraft(projection).changing === mine.id, "emptying the box forgot which line was being changed");
	store.cancelChange(projection);
	assert(store.activeDraft(projection).changing === undefined, "cancelling left the line attached to the draft");
	assert(store.activeDraft(projection).text === "", "cancelling left words in the composer");
});

Deno.test("an authoritative withdrawal settles only the matching edit intent", () => {
	const room = store.ensureRoom(projection, dirId("test-dir"), "withdrawal-reconciliation");
	store.switchTo(projection, room.key);
	const mine = store.chatItem(projection, "me", "file caption", true);
	store.deliver(projection, room.key, mine);
	store.updateItem(projection, room.key, mine.id, { lineId: 91 });

	store.startRefile(projection, mine.id, "file caption", []);
	store.setDraft(projection, "");
	store.applyLineChange(projection, room.key, 91, { withdrawn: true });
	assert(
		store.activeDraft(projection).changing === undefined,
		"the completed withdrawal left its edit intent active",
	);

	const another = store.chatItem(projection, "me", "older line", true);
	store.deliver(projection, room.key, another);
	store.updateItem(projection, room.key, another.id, { lineId: 92 });
	store.startChange(projection, another.id, "new message after the race");
	store.applyLineChange(projection, room.key, 92, { withdrawn: true });
	assert(store.activeDraft(projection).changing === undefined, "a withdrawn target stayed attached to newer input");
	assert(
		store.activeDraft(projection).text === "new message after the race",
		"retiring the withdrawn target erased the reader's newer words",
	);
});

Deno.test("an unsent message offers a retry only where one could work", () => {
	// The interface must never offer an action that could do harm. A line lost
	// with a session may go the moment one comes back; a line the runtime could
	// not confirm may already have reached the other side, so sending it again
	// could land it twice, and the page offers no retry for it.
	assert(!isUnsent("sending"), "a line still going is not unsent");
	assert(!isUnsent(undefined), "a line that went is not unsent");
	assert(isUnsent("failed"), "a line that failed is unsent");
	assert(isUnsent("unconfirmed"), "a line nobody confirmed is drawn as unsent");
	assert(canRetry("failed"), "a line that failed may be sent again");
	assert(!canRetry("unconfirmed"), "a line that may have landed must offer no blind retry");
	assert(!canRetry("sending"), "a line still going needs no retry");
	assert(!canRetry(undefined), "a line that went needs no retry");
});

Deno.test("message retry belongs only to the controller that can repeat safely", () => {
	const local = sendControlsFor("local");
	assert(local.retry, "local sends lost their recovery control");
	const shared = sendControlsFor("attached");
	assert(!shared.retry, "attached sends exposed a retry they cannot own");
	const hosted = sendControlsFor("hosted");
	assert(!hosted.retry, "hosted sends exposed a retry they cannot own");
});

Deno.test("a connection ending takes what its lines could be told, not what they said", () => {
	const dir = dirId("test-dir-held");
	const room = store.ensureRoom(projection, dir, "authority");
	store.switchTo(projection, room.key);
	const mine = store.chatItem(projection, "alice", "said on a connection", true, undefined);
	store.deliver(projection, room.key, mine);
	store.updateItem(projection, room.key, mine.id, { lineId: 7 });
	store.updateItem(projection, room.key, mine.id, { held: true });
	const held = () => {
		const line = store.historyOf(projection, room.key).find((item) => item.id === mine.id);
		return line?.kind === "chat" ? line.held : undefined;
	};
	assert(held() === true, "a line the room answered with a reference was not marked held");

	// Part way through rewriting it when the connection goes.
	store.startChange(projection, mine.id, "said on a connection, better");
	assert(store.activeDraft(projection).changing === mine.id, "the composer did not take the line being changed");

	const stopped = store.dropHeldLines(projection, dir);
	assert(held() === false, "a line whose reference died with its connection is still drawn as ours to change");
	assert(stopped.includes(room.key), "the conversation whose pending change was let go was not named");
	assert(
		store.activeDraft(projection).changing === undefined,
		"the composer is still aiming a change at a line that can no longer take one",
	);
	assert(
		store.activeDraft(projection).text === "said on a connection, better",
		"the words being written were thrown away with the change they were aimed at",
	);

	// What was said is untouched: only what can still be done to it changed.
	const line = store.historyOf(projection, room.key).find((item) => item.id === mine.id);
	assert(line?.kind === "chat" && line.text === "said on a connection", "the line's own words were rewritten");
	assert(line?.kind === "chat" && line.lineId === undefined, "a dead connection left its room-local line name live");
});

Deno.test("room management is retained authority, never creator-connection state", () => {
	const dir = dirId("test-dir-room-manager");
	const manager = "ocapn://127.0.0.1%3A1.tcp/s/bWFuYWdlcg";
	const room = store.ensureRoom(projection, dir, "harbor", { manager });
	assert(room.managerToken === authorityToken(manager), "the room did not retain its manager capability");
	assert(
		store.ensureRoom(projection, dir, "harbor").managerToken === authorityToken(manager),
		"an ordinary room update erased management",
	);
	assert(
		store.dropRoomManager(projection, room.key, roomAuthorityToken(manager)),
		"the exact manager could not be discarded",
	);
	const dropped = store.getConv(projection, room.key);
	assert(dropped?.type === "room" && dropped.managerToken == null, "manager drop lingered");
});

Deno.test("a delayed authority retirement cannot clear a newer room grant", () => {
	const room = store.ensureRoom(projection, dirId("test-dir-authority-generation"), "harbor");
	const oldRoom = "ocapn://127.0.0.1%3A1.tcp/s/b2xkLXJvb20";
	const newRoom = "ocapn://127.0.0.1%3A1.tcp/s/bmV3LXJvb20";
	const moderator = "ocapn://127.0.0.1%3A1.tcp/s/bW9kZXJhdG9y";
	store.noteRoomSteward(projection, room.key, oldRoom, moderator);
	store.noteRoomSteward(projection, room.key, newRoom, moderator);
	assert(
		!store.clearRoomAuthority(projection, room.key, {
			kind: "room",
			token: "old-room",
			claimable: false,
		}),
		"a stale retirement claimed the current authority",
	);
	const retained = store.getConv(projection, room.key);
	assert(
		retained?.type === "room" && retained.linkToken === authorityToken(newRoom),
		"a delayed retirement erased the reissued link",
	);
});

Deno.test("room history progress says what the membership actually learned", () => {
	const room = store.ensureRoom(projection, dirId("test-dir-history-state"), "archive");
	assert(room.earlierHistory === "unasked", "a room invented a history answer before asking");
	store.setEarlierHistory(projection, room.key, "loading");
	const loading = store.getConv(projection, room.key);
	assert(loading?.type === "room" && loading.earlierHistory === "loading", "the history wait was not visible");
	store.setEarlierHistory(projection, room.key, "empty");
	const empty = store.getConv(projection, room.key);
	assert(empty?.type === "room" && empty.earlierHistory === "empty", "an empty answer stayed in progress");
});

Deno.test("a saved room remains distinct from its live membership", () => {
	const room = store.ensureRoom(projection, dirId("membership-directory"), "saved-room");
	assert(room.membership === "joining", "a new room intent claimed a live membership");
	store.setRoomMembership(projection, room.key, "joined");
	const joined = store.getConv(projection, room.key);
	assert(
		joined?.type === "room" && joined.membership === "joined",
		"join was lost",
	);
	store.setRoomMembership(projection, room.key, "unavailable");
	const unavailable = store.getConv(projection, room.key);
	assert(
		unavailable?.type === "room" && unavailable.membership === "unavailable",
		"a failed realization erased or stayed joined",
	);
	store.forgetConv(projection, room.key);
});

Deno.test("a conversation keeps its scrollback bounded, and says what left", () => {
	// How much a room says is the room's own choice, and the log grew with it for
	// as long as the tab was open, copying the whole of itself on every line. What
	// leaves is the oldest, and it leaves saying so: a picture's object URL and
	// the capability its bytes come from are held elsewhere, and nothing else
	// would ever tell that side the line is gone.
	const dir = dirId("test-dir-scrollback");
	const room = store.ensureRoom(projection, dir, "long-running");
	store.switchTo(projection, room.key);
	const dropped: number[] = [];
	projection.onLinesDropped((key, gone) => {
		if (key === room.key) { for (const item of gone) dropped.push(item.id); }
	});

	const first = store.chatItem(projection, "alice", "the first thing said", false);
	store.deliver(projection, room.key, first);
	for (let at = 1; at < MAX_SCROLLBACK; at++) {
		store.deliver(projection, room.key, store.chatItem(projection, "alice", `line ${at}`, false));
	}
	const full = store.historyOf(projection, room.key);
	assert(full.length === MAX_SCROLLBACK, `a full log holds ${full.length}`);
	const earlyLosses = dropped.length;
	assert(earlyLosses === 0, "a log at its bound dropped a line it could still hold");

	const newest = store.chatItem(projection, "alice", "the newest thing said", false);
	store.deliver(projection, room.key, newest);
	const after = store.historyOf(projection, room.key);
	assert(after.length === MAX_SCROLLBACK, `one line past the bound left ${after.length}`);
	const left = [...dropped];
	assert(left.length === 1 && left[0] === first.id, `what left was ${JSON.stringify(left)}`);
	assert(
		after[after.length - 1]?.id === newest.id,
		"the newest line is not the one at the near end",
	);
	assert(
		!after.some((item) => item.id === first.id),
		"the oldest line is still in a log that passed its bound",
	);

	// Nobody is left holding a rule against a line nobody can scroll to.
	const anchored = store.unreadOf(projection, room.key);
	if (anchored.kind === "unread" || anchored.kind === "rule-only") {
		assert(
			after.some((item) => item.id === anchored.from),
			"the unread rule hangs on a line that has left the log",
		);
	}
	projection.onLinesDropped(() => {});
});

Deno.test("an ignored line does not count at the reader, and their own always does", () => {
	// One rule, three consumers, the log's draw filter, the unread count, and
	// the notification gates, and the half that once failed silently: a reader
	// whose own current name sits on their ignore list. Ignoring is about not
	// hearing somebody else, so their own lines stay heard however the list
	// reads; a stranger's under an ignored name is silent everywhere at once,
	// because a badge lighting for a line that will never draw teaches a reader
	// to stop trusting the badge.
	const { silencedByIgnore } = types;
	const ignored = new Set(["alice"]);
	const theirs = store.chatItem(projection, "Alice", "from the other alice", false);
	const mine = store.chatItem(projection, "Alice", "my own line", true);
	assert(silencedByIgnore(theirs, ignored), "a stranger's line under an ignored name is heard");
	assert(!silencedByIgnore(mine, ignored), "the reader's own line is silenced by their own ignore");
	assert(
		!silencedByIgnore(store.sysItem(projection, "alice joined"), ignored),
		"a system line is silenced by an ignore",
	);

	// And the unread count follows the same answer. The conversation is not the
	// active one, so a counted line would light its badge.
	store.ignore(projection, "alice");
	const room = store.ensureRoom(projection, dirId("test-dir"), "ignored-count");
	store.switchTo(projection, store.ensureRoom(projection, dirId("test-dir"), "elsewhere").key);
	store.deliver(projection, room.key, store.chatItem(projection, "Alice", "never drawn", false));
	assert(
		store.unreadOf(projection, room.key).kind === "caught-up",
		"a line the reader will never see lit the unread badge",
	);
	store.deliver(projection, room.key, store.chatItem(projection, "Alice", "my own, echoed back", true));
	assert(
		store.unreadOf(projection, room.key).kind === "unread",
		"the reader's own line stopped counting because their name is on their ignore list",
	);
	store.unignore(projection, "alice");
});

Deno.test("clearing a conversation hands back what its lines were holding", () => {
	// /clear is the third way lines leave the log, and it has to leave through
	// the same door: the release seam that the scrollback trim and a closing
	// conversation use to give back object URLs, blob capabilities, and the
	// references governing our own lines.
	const room = store.ensureRoom(projection, dirId("test-dir"), "clear-release");
	let released: readonly unknown[] = [];
	projection.onLinesDropped((key, gone) => {
		if (key === room.key) released = gone;
	});
	store.deliver(projection, room.key, store.chatItem(projection, "alice", "one", false));
	store.deliver(projection, room.key, store.chatItem(projection, "alice", "two", false));
	store.clearHistory(projection, room.key);
	assert(released.length === 2, `clearing did not hand its lines to the release seam: ${released.length}`);
	assert(store.historyOf(projection, room.key).length === 0, "the history was not actually cleared");
});

Deno.test("forgetting a conversation hands its lines back, while it can still be found", () => {
	// Leaving a room and closing a direct line both drop the whole conversation,
	// and that is the third way lines leave. It goes through the same seam as
	// the other two, from inside the store rather than from each caller: an
	// invariant every caller has to remember is one caller away from being
	// wrong.
	//
	// It fires before the row goes, and that ordering is load-bearing. The side
	// that listens finds the session by asking the store which directory the
	// conversation was on, so a conversation deleted first is one whose lines
	// cannot be given back.
	const room = store.ensureRoom(projection, dirId("test-dir"), "forget-release");
	let released: readonly unknown[] = [];
	let foundWhileReleasing = false;
	projection.onLinesDropped((key, gone) => {
		if (key !== room.key) return;
		released = gone;
		foundWhileReleasing = store.getConv(projection, key) !== null;
	});
	store.deliver(projection, room.key, store.chatItem(projection, "alice", "one", false));
	store.deliver(projection, room.key, store.chatItem(projection, "alice", "two", false));
	store.forgetConv(projection, room.key);
	assert(released.length === 2, `forgetting did not hand its lines to the release seam: ${released.length}`);
	assert(foundWhileReleasing, "the conversation was already gone when its lines were handed back");
	assert(store.getConv(projection, room.key) === null, "the conversation was not actually forgotten");
});

Deno.test("the last submitted line is recalled per conversation, including a command", () => {
	const room = store.ensureRoom(projection, dirId("test-dir"), "recall-here");
	const other = store.ensureRoom(projection, dirId("test-dir"), "recall-there");
	store.rememberLastSent(projection, room.key, "/ignore alice");
	store.rememberLastSent(projection, other.key, "hello");
	assert(store.lastSentFor(projection, room.key) === "/ignore alice", "a command was not kept to recall");
	assert(store.lastSentFor(projection, other.key) === "hello", "a later room overwrote the first");
	store.forgetConv(projection, room.key);
	assert(store.lastSentFor(projection, room.key) === undefined, "leaving a room kept its last line");
	assert(store.lastSentFor(projection, other.key) === "hello", "forgetting one room forgot another");
});

Deno.test("a direct line is not opened with yourself", () => {
	const dir = dirId("self-dm");
	store.openDir(projection, dir, "self-dm-route");
	store.setDirNick(projection, dir, "alice");
	assert(store.isSelf(projection, dir, "Alice"), "own nick is compared the way the directory grants it");
	assert(!store.isSelf(projection, dir, "bo"), "somebody else counted as you");
	assert(
		store.ensureDm(projection, dir, "alice", registrationId(1)) == null,
		"ensureDm minted a conversation with yourself",
	);
	const other = store.ensureDm(projection, dir, "bo", registrationId(2));
	assert(other !== null && other.type === "dm", "a line to somebody else was not opened");
});

Deno.test("error detail stacks without discarding the modal that opened it", () => {
	projection.reset();
	const directory = dirId("stacked-directory");
	store.openDir(projection, directory, "stacked-directory-route");
	store.showAboutDir(projection, directory);
	store.showErrorDetail(projection, { title: "What went wrong", text: "the complete refusal" });
	assert(projection.get().aboutDir === directory, "opening error detail discarded its underlying directory card");
	assert(projection.get().errorDetail?.text === "the complete refusal", "the error detail did not open");
	store.closeErrorDetail(projection);
	assert(projection.get().aboutDir === directory, "closing error detail did not return to its underlying card");
	projection.reset();
});

Deno.test("a reused nickname cannot retarget its previous direct conversation", () => {
	const dir = dirId("direct-incarnation");
	store.openDir(projection, dir, "direct-incarnation-route");
	store.setDmable(projection, dir, "bo", registrationId(1), true);
	const old = store.ensureDm(projection, dir, "bo", registrationId(1));
	assert(old != null, "the original direct conversation was not created");
	store.forgetConv(projection, old.key);
	const reopened = store.ensureDm(projection, dir, "bo", registrationId(1));
	assert(reopened != null, "the same registration did not reopen a conversation");
	assert(reopened.persistId === old.persistId, "the same registration lost its device archive identity");
	assert(store.convByPersistId(projection, old.persistId) === reopened, "durable id lookup missed the reopened line");
	store.setDmable(projection, dir, "bo", registrationId(1), false);
	store.setDmable(projection, dir, "bo", registrationId(2), true);
	assert(
		store.liveDmWith(projection, dir, "bo", registrationId(2)) == null,
		"the replacement registration inherited the old line",
	);
	const replacement = store.ensureDm(projection, dir, "bo", registrationId(2));
	assert(
		replacement != null && replacement.key !== reopened.key && replacement.persistId !== reopened.persistId,
		"the replacement registration reused the old conversation",
	);
	store.closeDmsWith(projection, dir, "bo", registrationId(1));
	assert(replacement.line !== "closed", "retiring the old registration closed its replacement");
});

Deno.test("a direct row relays the rooms' word on who is away", () => {
	const dir = dirId("ocapn://abc.iroh");
	const other = dirId("ocapn://other.iroh");
	const room = (key: string, at: typeof dir) =>
		({ type: "room", dir: at, key }) as unknown as import("../../web/ui/types.ts").Conv;
	const roster = (members: Record<string, { online: boolean; away: string }>) => new Map(Object.entries(members));
	const convs = new Map([
		// Away in one room, present in another: present wins, because a direct
		// line reaches the person and the person is at their desk.
		["a", room("a", dir)],
		["b", room("b", dir)],
		// The same nick on another directory is a different person.
		["c", room("c", other)],
	]);
	const members = new Map([
		["a", roster({ Bo: { online: true, away: "lunch" }, Cy: { online: true, away: "brb" } })],
		["b", roster({ Bo: { online: true, away: "" }, Dee: { online: false, away: "gone" } })],
		["c", roster({ Cy: { online: true, away: "" } })],
	]);
	const words = types.awayByPeer(convs, members);
	assert(types.awayOf(words, dir, "bo") === null, "present in one room did not beat away in another");
	assert(types.awayOf(words, dir, "BO") === null, "the nick was not matched the way dmable names are");
	assert(types.awayOf(words, dir, "cy") === "brb", "away everywhere online did not carry its reason");
	assert(types.awayOf(words, dir, "dee") === null, "an offline member's stale reason was relayed");
	assert(types.awayOf(words, other, "cy") === null, "a directory read another directory's roster");
});

Deno.test("only a confirmed optimistic line reaches the history recorder", () => {
	const room = store.ensureRoom(projection, dirId("history-confirmation"), "moderated");
	const recorded: number[] = [];
	projection.setLineRecorder((_conv, item) => recorded.push(item.id));
	try {
		const unconfirmed = store.chatItem(projection, "ada", "not sent", true, "sending");
		store.deliver(projection, room.key, unconfirmed);
		store.updateItem(projection, room.key, unconfirmed.id, { state: "unconfirmed" });
		assert(recorded.length === 0, "an unconfirmed optimistic line reached history");
		const accepted = store.chatItem(projection, "ada", "sent", true, "sending");
		store.deliver(projection, room.key, accepted);
		store.updateItem(projection, room.key, accepted.id, { state: undefined });
		assert(
			Number(recorded.length) === 1 && recorded[0] === accepted.id,
			"a confirmed line was not recorded exactly once",
		);
	} finally {
		projection.setLineRecorder(null);
		store.forgetConv(projection, room.key);
	}
});

Deno.test("room listings preserve exact local, foreign and bridge publication identity", () => {
	const dir = dirId("test-dir-entered-pub");
	store.openDir(projection, dir, "test-dir-entered-pub-route");
	// Presentation preserves the directory's exact publication for every kind.
	store.setLiveRoom(projection, dir, {
		id: "gen-1",
		name: "lobby",
		kind: "local",
		count: 1,
		origin: "",
		proof: "local",
		offers: "participant",
	});
	store.setLiveRoom(projection, dir, {
		id: "gen-2",
		name: "annex",
		kind: "foreign",
		count: null,
		origin: "elsewhere",
		proof: "session",
		offers: "participant",
	});
	store.setLiveRoom(projection, dir, {
		id: "gen-3",
		name: "network-channel",
		kind: "bridge",
		count: null,
		origin: "irc.example:6697",
		proof: "bridge",
		offers: "participant",
	});
	assert(
		store.liveRoom(projection, dir, "lobby")?.id === "gen-1",
		"a local listing lost its publication identity",
	);
	assert(
		store.liveRoom(projection, dir, "unlisted") === null,
		"an unlisted name was offered a publication",
	);
	// Bridge presentation follows the exact publication, independently of entry.
	assert(
		store.liveRoom(projection, dir, "annex")?.id === "gen-2",
		"a foreign room did not enter by its publication",
	);
	assert(
		store.liveRoom(projection, dir, "network-channel")?.id === "gen-3",
		"a bridge room did not enter by its publication",
	);
	assert(
		store.bridgedOrigin(projection.get().dirs.get(dir), "gen-3") === "irc.example:6697",
		"the exact bridge publication lost its origin",
	);
	assert(
		store.bridgedOrigin(projection.get().dirs.get(dir), "gen-2") === null,
		"a foreign publication was presented as an IRC bridge",
	);
	assert(
		store.bridgedOrigin(projection.get().dirs.get(dir), undefined) === null,
		"a name-only room inherited IRC presentation",
	);
	store.forgetDir(projection, dir);
});
