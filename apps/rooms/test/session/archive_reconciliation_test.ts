// Attached archive projection preserves record identity, file custody, and bounded hydration across rereads.
/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const {
	AttachedSessionFiles,
} = await import("../../web/ui/session/attached_files.ts");
type FileSources = import("../../web/ui/session/attached_files.ts").FileSources<Attachment>;
type ArchiveLine = import("../../lib/archive/protocol.ts").ArchiveLine;
type Attachment = import("../../lib/attachment.ts").Attachment;
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { assertEquals } = await import("../assert.ts");
const { reconcileAttachedHistory } = await import("../../web/ui/session/history_reconciliation.ts");

Deno.test("archive rereads reconcile the exact retained link-preview selection", () => {
	const page = new RoomsPage();
	const conv = store.restoreDm(page.projection, dirId("directory"), "alice", "reg", "direct", false);
	if (conv == null) throw new Error("the conversation was not restored");
	const first = "https://example.com/first";
	const second = "https://example.com/second";
	const record: ArchiveLine = {
		kind: "line",
		source: "source",
		generation: "generation",
		id: "preview",
		conversationKind: "direct",
		directory: "directory",
		conversation: "alice",
		from: "alice",
		text: `${first} ${second}`,
		mine: false,
		at: 1,
		order: 1,
		state: "present",
		previewUrls: [first, second],
		attachments: [],
	};
	const drawn = () => {
		const item = store.historyOf(page.projection, conv.key).find((candidate) => candidate.kind === "chat");
		if (item?.kind !== "chat") throw new Error("archive line missing");
		return item;
	};
	try {
		reconcileAttachedHistory(page, conv.key, [record], null);
		const identity = drawn().id;
		assertEquals(drawn().previewUrls, [first, second]);
		reconcileAttachedHistory(page, conv.key, [{ ...record, state: "edited", previewUrls: [second] }], null);
		assertEquals([drawn().id, drawn().edited, drawn().previewUrls], [identity, true, [second]]);
		reconcileAttachedHistory(page, conv.key, [{ ...record, state: "edited", previewUrls: [] }], null);
		assertEquals(drawn().previewUrls, undefined);
		reconcileAttachedHistory(page, conv.key, [{ ...record, state: "withdrawn", text: "", previewUrls: [] }], null);
		assertEquals([drawn().id, drawn().withdrawn, drawn().previewUrls], [identity, true, undefined]);
	} finally {
		store.forgetConv(page.projection, conv.key);
	}
});

Deno.test("archive rereads replace same-metadata files by digest and preserve unchanged custody", async () => {
	const page = new RoomsPage();
	const conv = store.restoreDm(page.projection, dirId("directory"), "alice", "reg", "direct", false);
	if (conv == null) throw new Error("the conversation was not restored");
	const fetched: string[] = [];
	const files = new AttachedSessionFiles({
		archiveSource(record: ArchiveLine, index: number) {
			return {
				mime: record.attachments[index].mime,
				durable: true,
				release() {},
				fetch() {
					fetched.push(record.attachments[index].blob!);
					return Promise.resolve(new Uint8Array([1]));
				},
			};
		},
	} as unknown as FileSources, page.projection);
	let recorded = 0;
	page.projection.setLineRecorder(() => recorded++);
	const record: ArchiveLine = {
		kind: "line",
		source: "source",
		generation: "generation",
		id: "file",
		conversationKind: "direct",
		directory: "directory",
		conversation: "alice",
		from: "alice",
		text: "file",
		mine: false,
		at: 1,
		order: 1,
		state: "edited",
		previewUrls: [],
		attachments: [{ name: "file.txt", mime: "text/plain", size: 1, width: 0, height: 0, blob: "a".repeat(64) }],
	};
	const drawn = () => {
		const item = store.historyOf(page.projection, conv.key).find((item) => item.kind === "chat");
		if (item?.kind !== "chat") throw new Error("archive line missing");
		return item;
	};
	try {
		reconcileAttachedHistory(page, conv.key, [record], files);
		const firstId = drawn().attachments![0].id;
		files.open(conv.key, firstId);
		await new Promise((resolve) => setTimeout(resolve, 0));
		const loaded = drawn();
		const oldUrl = loaded.attachments![0].url!;
		assertEquals(typeof oldUrl, "string");
		reconcileAttachedHistory(page, conv.key, [record], files);
		assertEquals(drawn() === loaded, true, "an unchanged read must not redraw or replace file custody");
		const replacement: ArchiveLine = {
			...record,
			from: "bob",
			mine: true,
			order: 2,
			attachments: [{ ...record.attachments[0], blob: "b".repeat(64) }],
		};
		reconcileAttachedHistory(page, conv.key, [replacement], files);
		const changed = drawn();
		assertEquals(changed.id, loaded.id, "the message keeps its identity");
		assertEquals([changed.from, changed.mine, changed.order], ["bob", true, 2]);
		assertEquals(changed.attachments![0].id === firstId, false, "a second edit must replace the file");
		assertEquals(await fetch(oldUrl).then(() => false, () => true), true, "the old object URL was not released");
		files.open(conv.key, changed.attachments![0].id);
		await new Promise((resolve) => setTimeout(resolve, 0));
		assertEquals(fetched, ["a".repeat(64), "b".repeat(64)]);
		reconcileAttachedHistory(page, conv.key, [{ ...replacement, state: "withdrawn", attachments: [] }], files);
		assertEquals(drawn().withdrawn, true);
		assertEquals(drawn().attachments, undefined);
		assertEquals(recorded, 0, "archive reads must never become archive writes");
	} finally {
		files.close();
		store.forgetConv(page.projection, conv.key);
	}
});

Deno.test("archive hydration adopts content identity without replacing live file custody", async () => {
	const page = new RoomsPage();
	const conv = store.restoreDm(page.projection, dirId("directory"), "alice", "reg", "direct", false);
	if (conv == null) throw new Error("the conversation was not restored");
	let released = 0;
	let archivedFetches = 0;
	const files = new AttachedSessionFiles({
		fetchAttachment: () => Promise.resolve(new Uint8Array([1])),
		archiveSource: () => {
			return {
				mime: "text/plain",
				durable: true,
				release() {},
				fetch() {
					archivedFetches += 1;
					return Promise.resolve(new Uint8Array([2]));
				},
			};
		},
		releaseAttachment: () => {
			released += 1;
		},
	} as unknown as FileSources, page.projection);
	const attachment = {
		name: "live.png",
		mime: "image/png",
		size: 1,
		width: 1,
		height: 1,
		blob: {},
	} as unknown as Attachment;
	const view = files.hold(attachment);
	const item = store.chatItem(page.projection, "alice", "live", false, undefined, [view], 1);
	store.deliver(page.projection, conv.key, {
		...item,
		history: { source: "source", generation: "generation", id: "live" },
	});
	files.open(conv.key, view.id);
	await new Promise((resolve) => setTimeout(resolve, 0));
	const loaded = store.historyOf(page.projection, conv.key)[0];
	if (loaded?.kind !== "chat") throw new Error("the live file was not projected");
	const url = loaded.attachments?.[0]?.url;
	const record: ArchiveLine = {
		kind: "line",
		source: "source",
		generation: "generation",
		id: "live",
		conversationKind: "direct",
		directory: "directory",
		conversation: "alice",
		from: "alice",
		text: "live",
		mine: false,
		at: 1,
		order: 1,
		state: "present",
		previewUrls: [],
		attachments: [{ name: "live.png", mime: "image/png", size: 1, width: 1, height: 1, blob: "a".repeat(64) }],
	};
	reconcileAttachedHistory(page, conv.key, [record], files);
	const adopted = store.historyOf(page.projection, conv.key)[0];
	assertEquals(adopted?.kind === "chat" ? adopted.attachments?.[0] : null, {
		...loaded.attachments?.[0],
		archiveDigest: "a".repeat(64),
	});
	assertEquals(adopted?.kind === "chat" ? adopted.attachments?.[0]?.url : null, url);
	assertEquals(released, 1, "digest adoption replaced already-settled live custody");

	const waiting = files.hold({
		...attachment,
		name: "waiting.txt",
		mime: "text/plain",
	} as unknown as Attachment);
	const waitingItem = store.chatItem(page.projection, "alice", "waiting", false, undefined, [waiting], 2);
	store.deliver(page.projection, conv.key, {
		...waitingItem,
		history: { source: "source", generation: "generation", id: "waiting" },
	});
	const waitingRecord: ArchiveLine = {
		...record,
		id: "waiting",
		text: "waiting",
		at: 2,
		attachments: [{
			name: "waiting.txt",
			mime: "text/plain",
			size: 1,
			width: 1,
			height: 1,
			blob: "b".repeat(64),
		}],
	};
	reconcileAttachedHistory(page, conv.key, [record, waitingRecord], files);
	files.markLost("the live connection ended");
	const durable = store.historyOf(page.projection, conv.key)[1];
	assertEquals(durable?.kind === "chat" ? durable.attachments?.[0]?.lost : true, undefined);
	files.open(conv.key, waiting.id);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(archivedFetches, 1, "the adopted view did not fetch from durable custody");
	files.close();
	store.forgetConv(page.projection, conv.key);
});
