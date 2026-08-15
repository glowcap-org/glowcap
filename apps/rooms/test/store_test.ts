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
const { canRetry, dirId, isUnsent } = await import("../web/ui/types.ts");

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

	store.openViewer(room.key, second.id);
	assert(store.stepViewer("previous") === first, "Left did not cross from a gallery to the standalone image");
	assert(store.stepViewer("previous") === null, "Left wrapped past the first image");
	assert(store.viewedAttachment(store.get()) === first, "the viewer moved at its leading edge");
	assert(store.stepViewer("next") === second, "Right did not return to the gallery image");
	assert(store.stepViewer("next") === third, "Right did not skip non-image attachments");
	assert(store.stepViewer("next") === null, "Right wrapped past the last image");
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
