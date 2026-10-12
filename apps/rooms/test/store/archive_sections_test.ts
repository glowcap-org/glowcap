// The combined archive view's store seam (ADR-0144): re-reading one shared
// account revises what it showed, edits replace, withdrawals empty, new lines
// join their section, and never prepends a second copy. A section that only
// grew keeps its one divider. The reader's own live traffic is untouched.

/// <reference lib="dom" />

import { assertEquals } from "../assert.ts";
import type { ArchiveLine } from "../../lib/archive/protocol.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: { getItem: () => null, setItem() {}, removeItem() {} },
});

const store = await import("../../web/ui/store.ts");
const { reconcileSharedArchive } = await import("../../web/ui/session/shared_archive_projection.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { dirId } = await import("../../web/ui/types.ts");

function shared(id: string, order: number, text: string, over: Partial<ArchiveLine> = {}): ArchiveLine {
	return {
		kind: "line",
		source: "alice-source",
		generation: "alice-generation",
		id,
		conversationKind: "direct",
		directory: "directory",
		conversation: "alice",
		from: "alice",
		text,
		mine: true,
		at: order,
		order,
		state: "present",
		previewUrls: [],
		attachments: [],
		...over,
	};
}

function chatRows(page: InstanceType<typeof RoomsPage>, key: string) {
	return store.historyOf(page.projection, key).map((item) =>
		item.kind === "chat"
			? { kind: item.kind, text: item.text, edited: item.edited === true, withdrawn: item.withdrawn === true }
			: { kind: item.kind, text: item.text }
	);
}

Deno.test("re-reading a shared account revises in place and never doubles a line", () => {
	const page = new RoomsPage();
	const conv = store.restoreDm(page.projection, dirId("directory"), "alice", "reg-1", "direct-1", false);
	if (conv == null) throw new Error("the direct conversation was not restored");

	reconcileSharedArchive(page, conv.key, [shared("one", 1, "first"), shared("two", 2, "second")], "alice");
	const once = chatRows(page, conv.key);
	assertEquals(once.map((row) => row.kind), ["chat", "chat", "sys"], "two lines under one divider");
	assertEquals(once[1].text, "second");

	// The second read of the same account carries an edit, a withdrawal, and a
	// line the first read predates.
	reconcileSharedArchive(page, conv.key, [
		shared("one", 1, "first, reconsidered", { state: "edited" }),
		shared("two", 2, "", { state: "withdrawn" }),
		shared("three", 3, "third"),
	], "alice");
	const twice = chatRows(page, conv.key);
	assertEquals(twice.map((row) => row.kind), ["chat", "chat", "chat", "sys"], "no line or divider doubled");
	assertEquals(twice[0], { kind: "chat", text: "first, reconsidered", edited: true, withdrawn: false });
	assertEquals(twice[1], { kind: "chat", text: "", edited: false, withdrawn: true });
	assertEquals(twice[2].text, "third");

	// A reader's own live line survives beside the account, unattributed to it.
	store.deliver(page.projection, conv.key, store.chatItem(page.projection, "me", "live words", true));
	reconcileSharedArchive(page, conv.key, [shared("three", 3, "third")], "alice");
	const afterLive = chatRows(page, conv.key);
	assertEquals(
		afterLive.map((row) => row.text),
		[
			"first, reconsidered",
			"",
			"third",
			"Earlier messages shared by alice, recorded by archive source alice-so, conversation alice-ge. This is alice's archive account, not live traffic.",
			"live words",
		],
		"the account keeps its section; the live line never joins it",
	);
	// And a silent re-read (the account shrank by eviction elsewhere) removes
	// nothing: absence is not a withdrawal.
	assertEquals(afterLive.filter((row) => row.kind === "chat").length, 4);
	store.forgetConv(page.projection, conv.key);
});

Deno.test("shared archive rereads refresh file metadata without recording or borrowing byte authority", () => {
	const page = new RoomsPage();
	const conv = store.restoreDm(page.projection, dirId("directory"), "alice", "reg", "direct", false);
	if (conv == null) throw new Error("the conversation was not restored");
	let recorded = 0;
	page.projection.setLineRecorder(() => recorded++);
	const first = shared("file", 1, "caption", {
		state: "edited",
		attachments: [{ name: "first.txt", mime: "text/plain", size: 1, width: 0, height: 0, blob: "a".repeat(64) }],
	});
	const drawn = () => {
		const item = store.historyOf(page.projection, conv.key).find((item) => item.kind === "chat");
		if (item?.kind !== "chat") throw new Error("archive line missing");
		return item;
	};
	try {
		reconcileSharedArchive(page, conv.key, [first], "alice");
		const original = drawn();
		assertEquals(original.edited, true, "the first read preserves edit state");
		const replacement = {
			...first,
			from: "bob",
			at: 2,
			order: 2,
			attachments: [{
				name: "second.png",
				mime: "image/png",
				size: 2,
				width: 2,
				height: 1,
				blob: "b".repeat(64),
			}],
		};
		reconcileSharedArchive(page, conv.key, [replacement], "alice");
		const changed = drawn();
		assertEquals(changed.id, original.id);
		assertEquals([changed.from, changed.at, changed.order, changed.mine], ["bob", 2, 2, false]);
		assertEquals(changed.attachments?.[0], {
			id: changed.attachments![0].id,
			name: "second.png",
			mime: "image/png",
			size: 2,
			width: 2,
			height: 1,
			archiveDigest: "b".repeat(64),
			lost: true,
			error: "These archived file bytes are not available in this view.",
		});
		reconcileSharedArchive(page, conv.key, [replacement], "alice");
		assertEquals(drawn() === changed, true, "an unchanged shared read does not redraw");
		reconcileSharedArchive(page, conv.key, [{ ...replacement, attachments: [] }], "alice");
		assertEquals(drawn().attachments, undefined, "removed files leave the view");
		assertEquals(recorded, 0, "reading a share cannot write it into the reader's archive");
	} finally {
		store.forgetConv(page.projection, conv.key);
	}
});

Deno.test("shared sections keep exact identity and chronology as rows and standing change", () => {
	const page = new RoomsPage();
	const conv = store.restoreDm(page.projection, dirId("directory"), "alice", "reg", "direct", false);
	if (conv == null) throw new Error("the conversation was not restored");
	try {
		reconcileSharedArchive(page, conv.key, [shared("middle", 2, "middle")], "alice");
		reconcileSharedArchive(page, conv.key, [shared("early", 1, "early"), shared("late", 3, "late")], "alice");
		assertEquals(chatRows(page, conv.key).filter((row) => row.kind === "chat").map((row) => row.text), [
			"early",
			"middle",
			"late",
		]);
		const standing = {
			kind: "standing" as const,
			source: "alice-source",
			generation: "alice-generation",
			id: "standing",
			conversationKind: "room" as const,
			directory: "directory",
			conversation: "general",
			room: "general",
			nick: "alice",
			at: 1,
		};
		reconcileSharedArchive(page, conv.key, [standing], "alice");
		reconcileSharedArchive(page, conv.key, [standing], "alice renamed");
		assertEquals(chatRows(page, conv.key).filter((row) => row.kind === "sys").length, 1);
		// These recorder identities have identical display abbreviations.
		reconcileSharedArchive(
			page,
			conv.key,
			[shared("other", 4, "other", { source: "alice-source-2" })],
			"alice renamed",
		);
		assertEquals(chatRows(page, conv.key).filter((row) => row.kind === "sys").length, 2);
	} finally {
		store.forgetConv(page.projection, conv.key);
	}
});
