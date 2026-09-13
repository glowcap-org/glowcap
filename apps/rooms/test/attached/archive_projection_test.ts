// Attached archive projection preserves record identity, file custody, and bounded hydration across rereads.
/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const {
	AttachedSessionFiles,
	EARLIER_CONNECTION_BYTES_UNAVAILABLE,
} = await import("../../web/ui/session/attached_files.ts");
type AttachedRoomsController = import("../../web/ui/session/attached.ts").AttachedRoomsController;
const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
type ArchiveLine = import("../../lib/archive/protocol.ts").ArchiveLine;
type Attachment = import("../../lib/attachment.ts").Attachment;
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { assertEquals } = await import("../assert.ts");
const { roomsSessionSnapshot } = await import("../support/session_snapshot.ts");
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
		fetchArchivedAttachment(record: ArchiveLine, index: number) {
			fetched.push(record.attachments[index].blob!);
			return Promise.resolve(new Uint8Array([1]));
		},
	} as unknown as AttachedRoomsController, page.projection);
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
		fetchArchivedAttachment: () => {
			archivedFetches += 1;
			return Promise.resolve(new Uint8Array([2]));
		},
		releaseAttachment: () => {
			released += 1;
		},
	} as unknown as AttachedRoomsController, page.projection);
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

Deno.test("attached hydration exposes loading, empty, shown, and unavailable history states", async () => {
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
	const directory = dirId("history-directory");
	const rooms = ["shown", "empty", "unavailable"].map((name) => ({
		kind: "room" as const,
		id: `history-${name}`,
		directory: "history-directory",
		name,
		held: false,
		standing: null,
		draft: "",
	}));
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "history-directory", locator: "127.0.0.1:3", home: true, nick: "ada", standing: null }],
		conversations: rooms,
		active: null,
	};
	const line: ArchiveLine = {
		kind: "line",
		source: "archive",
		generation: "generation",
		id: "line",
		conversationKind: "room",
		directory: "history-directory",
		conversation: "shown",
		from: "bo",
		text: "earlier",
		mine: false,
		at: 1,
		order: 1,
		state: "present",
		previewUrls: [],
		attachments: [{ name: "earlier.png", mime: "image/png", size: 80, width: 4, height: 2, blob: null }],
	};
	type AttachedSessionControllerListener = (
		snapshot: import("../../lib/session/client.ts").RoomsSessionSnapshot,
	) => void;
	let onSnapshot: AttachedSessionControllerListener | null = null;
	const controller = {
		onSnapshot(listener: AttachedSessionControllerListener) {
			onSnapshot = listener;
			return () => {};
		},
		onHistoryInvalidated() {
			return () => {};
		},
		onLine() {
			return () => {};
		},
		ignoredNickname() {
			return undefined;
		},
		readHistory(_kind: "room" | "direct", _dir: string, conversation: string) {
			if (conversation === "history-shown") return Promise.resolve([line]);
			if (conversation === "history-empty") return Promise.resolve([]);
			return Promise.reject(new Error("archive unavailable"));
		},
		pendingDraft() {
			return undefined;
		},
	} as unknown as AttachedRoomsController;
	const stop = projection.bind(controller);
	onSnapshot!(roomsSessionSnapshot({
		revision: 1,
		checkpoint,
		connectedDirectories: ["history-directory"],
		roomViews: rooms.map((room) => ({
			conversationId: room.id,
			membershipKind: "participant" as const,
			policy: { visibility: "listed" as const, entry: "open" as const, speaking: "open" as const },
			members: [],
			topic: null,
			lineBytes: null,
		})),
	}));
	const byName = (name: string) =>
		[...page.projection.get().convs.values()].find((conv) =>
			conv.type !== "directory" && conv.persistId === `history-${name}`
		);
	const historyState = (name: string) => {
		const conversation = byName(name);
		return conversation?.type === "room" ? conversation.earlierHistory : null;
	};
	assertEquals(historyState("shown"), "loading");
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(historyState("shown"), "shown");
	assertEquals(historyState("empty"), "empty");
	assertEquals(historyState("unavailable"), "unavailable");
	const restored = store.historyOf(page.projection, byName("shown")?.key ?? "").find((item) => item.kind === "chat");
	assertEquals(restored?.kind === "chat" ? restored.attachments?.[0] : null, {
		id: restored?.kind === "chat" ? restored.attachments?.[0]?.id : 0,
		name: "earlier.png",
		mime: "image/png",
		size: 80,
		width: 4,
		height: 2,
		lost: true,
		error: "These archived file bytes are not available in this view.",
	});
	stop();
	for (const room of rooms) store.forgetConv(page.projection, `room:${directory}\u0000${room.name}`);
	store.forgetDir(page.projection, directory);
});

Deno.test("attached recovery reconciles missed rows and mutations into live history", async () => {
	const page = new RoomsPage();
	type Snapshot = import("../../lib/session/client.ts").RoomsSessionSnapshot;
	let onSnapshot: ((snapshot: Snapshot) => void) | null = null;
	let reads = 0;
	const recovered = Promise.withResolvers<ArchiveLine[]>();
	const archived = (id: string, text: string, at: number, state: ArchiveLine["state"] = "present"): ArchiveLine => ({
		kind: "line",
		source: "archive",
		generation: "generation",
		id,
		conversationKind: "room",
		directory: "directory",
		conversation: "room-id",
		from: "bo",
		text,
		mine: false,
		at,
		order: Number(id) || 1,
		state,
		previewUrls: [],
		attachments: [],
	});
	const controller = {
		onSnapshot(listener: (snapshot: Snapshot) => void) {
			onSnapshot = listener;
			return () => {};
		},
		onHistoryInvalidated() {
			return () => {};
		},
		onLine() {
			return () => {};
		},
		ignoredNickname() {
			return undefined;
		},
		readHistory() {
			reads += 1;
			return reads === 1 ? Promise.resolve([archived("initial", "retained before live", 10)]) : recovered.promise;
		},
		pendingDraft() {
			return undefined;
		},
	} as unknown as AttachedRoomsController;
	const projection = new AttachedSessionProjection(page);
	const stop = projection.bind(controller);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:3", home: true, nick: "ada", standing: null }],
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
	const view = (issues: Snapshot["issues"], connectedDirectories = ["directory"]): Snapshot =>
		roomsSessionSnapshot({ revision: 1, checkpoint, issues, connectedDirectories });
	onSnapshot!(view([]));
	await new Promise((resolve) => setTimeout(resolve, 0));
	const room = [...page.projection.get().convs.values()].find((conv) => conv.type === "room");
	if (room == null) throw new Error("the attached recovery fixture did not project its room");
	projection.line({
		source: "events",
		sequence: 1,
		conversationId: "room-id",
		from: "bo",
		text: "live before suspension",
		at: 20,
		lineId: 2,
		change: "said",
		editable: false,
		history: { source: "archive", generation: "generation", id: "live" },
		system: false,
		previewUrls: [],
		attachments: [],
	});
	projection.line({
		source: "events",
		sequence: 2,
		conversationId: "room-id",
		from: "bo",
		text: "live before withdrawal",
		at: 25,
		lineId: 3,
		change: "said",
		editable: false,
		history: { source: "archive", generation: "generation", id: "gone" },
		system: false,
		previewUrls: [],
		attachments: [],
	});
	onSnapshot!(view([{ subject: "session", reason: "the attached transport ended" }], []));
	onSnapshot!(view([]));
	await new Promise((resolve) => setTimeout(resolve, 0));
	let recorded = 0;
	page.projection.setLineRecorder(() => {
		recorded += 1;
	});
	recovered.resolve([
		archived("later", "missed while suspended", 30),
		archived("earlier", "retained before this view", 5),
		archived("live", "edited while suspended", 20, "edited"),
		archived("gone", "", 25, "withdrawn"),
	]);
	await new Promise((resolve) => setTimeout(resolve, 0));
	const chats = store.historyOf(page.projection, room.key)
		.filter((item) => item.kind === "chat");
	assertEquals(
		chats.map((item) => item.kind === "chat" ? item.text : ""),
		["retained before this view", "retained before live", "edited while suspended", "", "missed while suspended"],
	);
	assertEquals(chats[2]?.kind === "chat" ? chats[2].edited : false, true);
	assertEquals(chats[3]?.kind === "chat" ? chats[3].withdrawn : false, true);
	assertEquals(chats.map((item) => item.kind === "chat" ? item.at : -1), [5, 10, 20, 25, 30]);
	assertEquals(recorded, 0, "archive reconciliation must not become a new archive write");
	page.projection.setLineRecorder(null);
	stop();
});

Deno.test("a replaced conversation cannot receive history from its previous identity", async () => {
	const page = new RoomsPage();
	type Snapshot = import("../../lib/session/client.ts").RoomsSessionSnapshot;
	let onSnapshot: ((snapshot: Snapshot) => void) | null = null;
	const answers = new Map<string, (records: ArchiveLine[]) => void>();
	const controller = {
		onSnapshot(listener: (snapshot: Snapshot) => void) {
			onSnapshot = listener;
			return () => {};
		},
		onHistoryInvalidated() {
			return () => {};
		},
		onLine() {
			return () => {};
		},
		ignoredNickname() {
			return undefined;
		},
		readHistory(_kind: "room" | "direct", directory: string) {
			return new Promise<ArchiveLine[]>((resolve) => answers.set(directory, resolve));
		},
		pendingDraft() {
			return undefined;
		},
	} as unknown as AttachedRoomsController;
	const projection = new AttachedSessionProjection(page);
	const stop = projection.bind(controller);
	const checkpoint = (directory: string, name: string) => ({
		...emptyRoomsSessionState(),
		directories: [{
			id: directory,
			locator: `127.0.0.1:${directory === "old-directory" ? 8 : 9}`,
			home: true,
			nick: "ada",
			standing: null,
		}],
		conversations: [{
			kind: "room" as const,
			id: "reused-conversation",
			directory,
			name,
			held: false,
			standing: null,
			draft: "",
		}],
	});
	const snapshot = (revision: number, directory: string, name: string): Snapshot =>
		roomsSessionSnapshot({
			revision,
			checkpoint: checkpoint(directory, name),
			connectedDirectories: [directory],
			roomViews: [{
				conversationId: "reused-conversation",
				membershipKind: "participant",
				policy: { visibility: "listed", entry: "open", speaking: "open" },
				members: [],
				topic: null,
				lineBytes: null,
			}],
		});
	onSnapshot!(snapshot(1, "old-directory", "old-room"));
	onSnapshot!(snapshot(2, "new-directory", "new-room"));
	const archived = (directory: string, text: string): ArchiveLine => ({
		kind: "line",
		source: "archive",
		generation: directory,
		id: text,
		conversationKind: "room",
		directory,
		conversation: "reused-conversation",
		from: "bo",
		text,
		mine: false,
		at: 1,
		order: 1,
		state: "present",
		previewUrls: [],
		attachments: [],
	});
	answers.get("new-directory")?.([archived("new-directory", "new history")]);
	answers.get("old-directory")?.([archived("old-directory", "stale history")]);
	await new Promise((resolve) => setTimeout(resolve, 0));
	const current = [...page.projection.get().convs.values()][0];
	assertEquals(
		store.historyOf(page.projection, current?.key ?? "").filter((item) => item.kind === "chat").map((item) =>
			item.text
		),
		["new history"],
	);
	stop();
	if (current != null) store.forgetConv(page.projection, current.key);
	store.forgetDir(page.projection, dirId("old-directory"));
	store.forgetDir(page.projection, dirId("new-directory"));
});

Deno.test("attached live attachment views become lost when their controller is replaced", () => {
	const page = new RoomsPage();
	const directory = dirId("attachment-directory");
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "attachment-directory", locator: "127.0.0.1:4", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "attachment-room",
			directory: "attachment-directory",
			name: "files",
			held: false,
			standing: null,
			draft: "",
		}],
		active: null,
	};
	const projection = new AttachedSessionProjection(page);
	projection.apply(roomsSessionSnapshot({
		revision: 1,
		checkpoint,
		connectedDirectories: ["attachment-directory"],
		roomViews: [{
			conversationId: "attachment-room",
			membershipKind: "participant",
			policy: { visibility: "listed", entry: "open", speaking: "open" },
			members: [],
			topic: null,
			lineBytes: null,
		}],
	}));
	const room = [...page.projection.get().convs.values()][0];
	if (room?.type !== "room") throw new Error("attachment test did not create a room");
	let released = 0;
	const controller = {
		releaseAttachment() {
			released += 1;
		},
	} as unknown as AttachedRoomsController;
	const files = new AttachedSessionFiles(controller, page.projection);
	const attachment = {
		name: "note.txt",
		mime: "text/plain",
		size: 4,
		blob: null,
		width: 0,
		height: 0,
	} as unknown as Attachment;
	const view = files.hold(attachment);
	store.deliver(page.projection, room.key, store.chatItem(page.projection, "bo", "file", false, undefined, [view]));
	files.markLost("the attached session was replaced");
	const attachmentAfter = store.historyOf(page.projection, room.key)[0];
	assertEquals(attachmentAfter?.kind === "chat" ? attachmentAfter.attachments?.[0].lost : false, true);
	assertEquals(
		attachmentAfter?.kind === "chat" ? attachmentAfter.attachments?.[0].error : "",
		"the attached session was replaced",
	);
	assertEquals(released, 1);
	const orphaned = files.hold({ ...attachment, name: "orphaned.txt" });
	store.deliver(
		page.projection,
		room.key,
		store.chatItem(page.projection, "bo", "orphaned file", false, undefined, [orphaned]),
	);
	files.release([orphaned]);
	files.open(room.key, orphaned.id);
	const orphanedAfter = store.historyOf(page.projection, room.key)[1];
	assertEquals(
		orphanedAfter?.kind === "chat"
			? [orphanedAfter.attachments?.[0]?.lost, orphanedAfter.attachments?.[0]?.error]
			: null,
		[true, EARLIER_CONNECTION_BYTES_UNAVAILABLE],
		"a fetch intent with no surviving capability did not settle visibly",
	);
	assertEquals(released, 2);
	files.close();
	store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
});
