/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../web/ui/session/projection.ts");
const { AttachedSessionFiles } = await import("../web/ui/session/attached_files.ts");
const { attachedArchiveShareActions } = await import("../web/ui/session/attached_archive_shares.ts");
type AttachedRoomsController = import("../web/ui/session/attached.ts").AttachedRoomsController;
const { emptyRoomsSessionState } = await import("../lib/rooms_state.ts");
type ArchiveLine = import("../lib/archive.ts").ArchiveLine;
type Attachment = import("../lib/attachment.ts").Attachment;
const store = await import("../web/ui/store.ts");
const { dirId } = await import("../web/ui/types.ts");
const { assertEquals } = await import("./assert.ts");
const { roomsSessionSnapshot } = await import("./support/session_snapshot.ts");
const { registrationId } = await import("./support/registration.ts");

Deno.test("attached hydration exposes loading, empty, shown, and unavailable history states", async () => {
	const projection = new AttachedSessionProjection();
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
		state: "present",
		attachments: [{ name: "earlier.png", mime: "image/png", size: 80, width: 4, height: 2, blob: null }],
	};
	type AttachedSessionControllerListener = (snapshot: import("../lib/rooms_session.ts").RoomsSessionSnapshot) => void;
	let onSnapshot: AttachedSessionControllerListener | null = null;
	const controller = {
		onSnapshot(listener: AttachedSessionControllerListener) {
			onSnapshot = listener;
			return () => {};
		},
		onLine() {
			return () => {};
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
		roomViews: rooms.map((room) => ({ conversationId: room.id, members: [], topic: null, lineBytes: null })),
	}));
	const byName = (name: string) =>
		[...store.get().convs.values()].find((conv) => conv.persistId === `history-${name}`);
	const historyState = (name: string) => {
		const conversation = byName(name);
		return conversation?.type === "room" ? conversation.earlierHistory : null;
	};
	assertEquals(historyState("shown"), "loading");
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(historyState("shown"), "shown");
	assertEquals(historyState("empty"), "empty");
	assertEquals(historyState("unavailable"), "unavailable");
	const restored = byName("shown")?.history.find((item) => item.kind === "chat");
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
	for (const room of rooms) store.forgetConv(`room:${directory}\u0000${room.name}`);
	store.forgetDir(directory);
});

Deno.test("a replaced conversation cannot receive history from its previous identity", async () => {
	type Snapshot = import("../lib/rooms_session.ts").RoomsSessionSnapshot;
	let onSnapshot: ((snapshot: Snapshot) => void) | null = null;
	const answers = new Map<string, (records: ArchiveLine[]) => void>();
	const controller = {
		onSnapshot(listener: (snapshot: Snapshot) => void) {
			onSnapshot = listener;
			return () => {};
		},
		onLine() {
			return () => {};
		},
		readHistory(_kind: "room" | "direct", directory: string) {
			return new Promise<ArchiveLine[]>((resolve) => answers.set(directory, resolve));
		},
		pendingDraft() {
			return undefined;
		},
	} as unknown as AttachedRoomsController;
	const projection = new AttachedSessionProjection();
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
			roomViews: [{ conversationId: "reused-conversation", members: [], topic: null, lineBytes: null }],
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
		state: "present",
		attachments: [],
	});
	answers.get("new-directory")?.([archived("new-directory", "new history")]);
	answers.get("old-directory")?.([archived("old-directory", "stale history")]);
	await new Promise((resolve) => setTimeout(resolve, 0));
	const current = [...store.get().convs.values()][0];
	assertEquals(
		current?.history.filter((item) => item.kind === "chat").map((item) => item.text),
		["new history"],
	);
	stop();
	if (current != null) store.forgetConv(current.key);
	store.forgetDir(dirId("old-directory"));
	store.forgetDir(dirId("new-directory"));
});

Deno.test("attached archive target follows the shared session snapshot", () => {
	const projection = new AttachedSessionProjection();
	const checkpoint = {
		...emptyRoomsSessionState(),
		capabilities: {
			operations: [],
			archivePeer: "ocapn://127.0.0.1.tcp/s/archive",
		},
	};
	const snapshot = (issues: { subject: string; reason: string }[]) =>
		roomsSessionSnapshot({
			revision: 1,
			checkpoint,
			issues,
		});
	projection.apply(snapshot([]));
	assertEquals(store.get().archiveTarget, {
		kind: "peer",
		status: "connected",
		label: "Shared session archive peer",
		remembered: true,
		error: "",
	});
	projection.apply(snapshot([{ subject: "archive", reason: "archive peer is down" }]));
	assertEquals(store.get().archiveTarget, {
		kind: "peer",
		status: "unavailable",
		label: "Shared session archive peer",
		remembered: true,
		error: "archive peer is down",
	});
	projection.apply(roomsSessionSnapshot({
		...snapshot([]),
		checkpoint: { ...checkpoint, capabilities: { operations: [], archivePeer: null } },
	}));
	assertEquals(store.get().archiveTarget, { kind: "device" });
});

Deno.test("attached live attachment views become lost when their controller is replaced", () => {
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
	const projection = new AttachedSessionProjection();
	projection.apply(roomsSessionSnapshot({
		revision: 1,
		checkpoint,
		connectedDirectories: ["attachment-directory"],
		roomViews: [{ conversationId: "attachment-room", members: [], topic: null, lineBytes: null }],
	}));
	const room = [...store.get().convs.values()][0];
	if (room?.type !== "room") throw new Error("attachment test did not create a room");
	let released = 0;
	const controller = {
		releaseAttachment() {
			released += 1;
		},
	} as unknown as AttachedRoomsController;
	const files = new AttachedSessionFiles(controller);
	const attachment = {
		name: "note.txt",
		mime: "text/plain",
		size: 4,
		blob: null,
		width: 0,
		height: 0,
	} as unknown as Attachment;
	const view = files.hold(attachment);
	store.deliver(room.key, store.chatItem("bo", "file", false, undefined, [view]));
	files.markLost("the attached session was replaced");
	const current = store.get().convs.get(room.key);
	const attachmentAfter = current?.history[0];
	assertEquals(attachmentAfter?.kind === "chat" ? attachmentAfter.attachments?.[0].lost : false, true);
	assertEquals(
		attachmentAfter?.kind === "chat" ? attachmentAfter.attachments?.[0].error : "",
		"the attached session was replaced",
	);
	assertEquals(released, 1);
	files.close();
	store.forgetConv(room.key);
	store.forgetDir(directory);
});

Deno.test("reading an attached archive share prepends attributed history to its direct conversation", async () => {
	const directory = dirId("shared-archive-directory");
	store.openDir(directory, "127.0.0.1:5");
	store.patchDir(directory, { nick: "ada" });
	const conversation = store.restoreDm(directory, "bo", registrationId(1), "shared-direct", false);
	if (conversation == null) throw new Error("archive-share test did not create its direct conversation");
	const record: ArchiveLine = {
		kind: "line",
		source: "sender-archive",
		generation: "sender-generation",
		id: "sender-line",
		conversationKind: "direct",
		directory: "shared-archive-directory",
		conversation: "sender-conversation",
		from: "ada",
		text: "the earlier line",
		mine: false,
		at: 2,
		state: "present",
		attachments: [{ name: "shared.txt", mime: "text/plain", size: 12, width: 0, height: 0, blob: null }],
	};
	const controller = {
		readArchiveShare: () =>
			Promise.resolve({
				view: {
					id: "share",
					directory: "shared-archive-directory",
					conversationId: "shared-direct",
					from: "bo",
					status: "reading" as const,
					error: "",
				},
				records: [record],
			}),
	} as unknown as AttachedRoomsController;
	const actions = attachedArchiveShareActions(controller, () => {});
	assertEquals(await actions.readArchiveShare("share"), "");
	const history = store.getConv(conversation.key)?.history ?? [];
	assertEquals(history[0]?.kind === "chat" ? { text: history[0].text, mine: history[0].mine } : null, {
		text: "the earlier line",
		mine: false,
	});
	assertEquals(history[0]?.kind === "chat" ? history[0].attachments?.[0]?.lost : false, true);
	assertEquals(history[1]?.kind === "sys" && history[1].text.includes("shared by bo"), true);
	store.forgetConv(conversation.key);
	store.forgetDir(directory);
});
