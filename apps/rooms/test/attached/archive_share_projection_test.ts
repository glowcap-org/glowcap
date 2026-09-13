// Attached archive shares reconcile attributed history and cleanup into the exact conversation they name.
/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { attachedArchiveShareActions } = await import("../../web/ui/session/attached_archive_shares.ts");
type AttachedRoomsController = import("../../web/ui/session/attached.ts").AttachedRoomsController;
const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
type ArchiveLine = import("../../lib/archive/protocol.ts").ArchiveLine;
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { dirId } = await import("../../web/ui/types.ts");
const { assertEquals } = await import("../assert.ts");
const { roomsSessionSnapshot } = await import("../support/session_snapshot.ts");
const { registrationId } = await import("../support/registration.ts");

Deno.test("reading an attached archive share prepends attributed history to its direct conversation", async () => {
	const page = new RoomsPage();
	const directory = dirId("shared-archive-directory");
	store.openDir(page.projection, directory, "127.0.0.1:5");
	store.patchDir(page.projection, directory, { nick: "ada" });
	const conversation = store.restoreDm(page.projection, directory, "bo", registrationId(1), "shared-direct", false);
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
		order: 1,
		state: "present",
		previewUrls: [],
		attachments: [{ name: "shared.txt", mime: "text/plain", size: 12, width: 0, height: 0, blob: null }],
	};
	let released = false;
	const controller = {
		dropArchiveShare: () => {
			released = true;
			return Promise.resolve();
		},
		readArchiveShare: () =>
			Promise.resolve({
				view: {
					id: "share",
					directory: "shared-archive-directory",
					conversationId: "shared-direct",
					from: "bo",
					status: "reading" as const,
					error: "",
					kind: "direct" as const,
					scopeConversation: "sender-conversation",
					custody: "live" as const,
					sturdyref: "",
				},
				records: [record],
			}),
	} as unknown as AttachedRoomsController;
	const actions = attachedArchiveShareActions(page.projection, page, controller, () => {});
	assertEquals(await actions.readArchiveShare("share"), "");
	assertEquals(released, true);
	const history = store.historyOf(page.projection, conversation.key);
	assertEquals(history[0]?.kind === "chat" ? { text: history[0].text, mine: history[0].mine } : null, {
		text: "the earlier line",
		mine: false,
	});
	assertEquals(history[0]?.kind === "chat" ? history[0].attachments?.[0]?.lost : false, true);
	assertEquals(history[1]?.kind === "sys" && history[1].text.includes("shared by bo"), true);
	store.forgetConv(page.projection, conversation.key);
	store.forgetDir(page.projection, directory);
});

Deno.test("archive share cleanup failure preserves the reconciled outcome and names the remaining work", async () => {
	const page = new RoomsPage();
	const directory = dirId("shared-archive-cleanup-directory");
	store.openDir(page.projection, directory, "127.0.0.1:5");
	const conversation = store.restoreDm(page.projection, directory, "bo", registrationId(1), "shared-direct", false);
	if (conversation == null) throw new Error("archive cleanup test did not create its direct conversation");
	const controller = {
		closed: false,
		readArchiveShare: () =>
			Promise.resolve({
				view: {
					conversationId: "shared-direct",
					from: "bo",
				},
				records: [{
					kind: "standing" as const,
					source: "sender-archive",
					generation: "sender-generation",
					id: "sender-standing",
					conversationKind: "direct" as const,
					directory: "shared-archive-cleanup-directory",
					conversation: "sender-conversation",
					name: "bo",
					away: "back later",
					at: 2,
				}],
			}),
		dropArchiveShare: () => Promise.reject(new Error("session storage unavailable")),
	} as unknown as AttachedRoomsController;
	const actions = attachedArchiveShareActions(page.projection, page, controller, () => {});
	assertEquals(
		await actions.readArchiveShare("share"),
		"History was added, but the shared-history offer could not be dismissed: Rooms couldn't complete that action. Check the diagnostic before trying again. (session storage unavailable)",
	);
	assertEquals(
		store.historyOf(page.projection, conversation.key).some((item) =>
			item.kind === "sys" && item.text.includes("shared by bo")
		),
		true,
	);
	store.forgetConv(page.projection, conversation.key);
	store.forgetDir(page.projection, directory);
});

Deno.test("an attached room archive share starts a DM without selecting it", async () => {
	const page = new RoomsPage();
	const directory = dirId("share-directory");
	store.openDir(page.projection, directory, "127.0.0.1:6");
	store.patchDir(page.projection, directory, { nick: "ada" });
	store.setDmable(page.projection, directory, "bo", registrationId(1), true);
	const room = store.ensureRoom(page.projection, directory, "lobby", { persistId: "room-1" });
	const started: string[] = [];
	const shared: string[] = [];
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "share-directory", locator: "127.0.0.1:6", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "room-1",
			directory: "share-directory",
			name: "lobby",
			held: false,
			standing: null,
			draft: "",
		}],
	};
	const snapshot = roomsSessionSnapshot({ revision: 1, checkpoint });
	const controller = {
		current: snapshot,
		chooseDirect(directory: string, peer: string) {
			started.push(peer);
			return Promise.resolve({
				kind: "direct" as const,
				id: "shared-direct",
				directory,
				peer,
				peerRegistrationId: registrationId(1),
				closed: false,
				draft: "",
			});
		},
		shareArchiveHistory(kind: string, conversationId: string, peer: string) {
			shared.push(`${kind}:${conversationId}:${peer}`);
			return Promise.resolve();
		},
	} as unknown as AttachedRoomsController;
	const actions = attachedArchiveShareActions(page.projection, page, controller, () => {});
	assertEquals(await actions.shareArchiveHistory(room.key, "bo"), "");
	assertEquals(started, ["bo"]);
	assertEquals(shared, ["room:room-1:bo"]);
	assertEquals(snapshot.checkpoint.active, null);
	store.forgetConv(page.projection, room.key);
	store.forgetDir(page.projection, directory);
});
