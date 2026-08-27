/// <reference lib="dom" />

import type { RoomsSessionSnapshot } from "../lib/rooms_session.ts";
import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import type { RoomsBrowserController } from "../web/ui/controller/browser.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";
import { roomsSessionSnapshot } from "./support/session_snapshot.ts";

Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: {
		getItem: () => null,
		setItem() {},
		removeItem() {},
	},
});
Object.defineProperty(globalThis, "location", {
	configurable: true,
	value: { reload() {} },
});
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const store = await import("../web/ui/store.ts");
const { attachedCommandPowers } = await import("../web/ui/session/attached_command_powers.ts");
const { createAttachedRoomsSession } = await import("../web/ui/session/attached_session.ts");
const { dirId } = await import("../web/ui/types.ts");

type Deferred<T> = { promise: Promise<T>; resolve(value: T): void; reject(error: unknown): void };

function deferred<T>(): Deferred<T> {
	let resolve!: (value: T) => void;
	let reject!: (error: unknown) => void;
	const promise = new Promise<T>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

function snapshot(checkpoint = emptyRoomsSessionState()): RoomsSessionSnapshot {
	return roomsSessionSnapshot({ checkpoint });
}

class FakeController {
	current: RoomsSessionSnapshot;
	readonly directIds: string[] = [];
	readonly removedConversationIds: string[] = [];
	readonly selectedIds: string[] = [];
	readonly commandNames: string[] = [];
	readonly moderatorRequests: Array<{ conversationId: string; sturdyref?: string }> = [];
	readonly joinedRooms: Array<{ room: { name: string }; directory?: { locator: string; nick: string } }> = [];
	readonly draftWrites: Deferred<RoomsSessionSnapshot>[] = [];
	readonly sends: Deferred<RoomsSessionSnapshot>[] = [];
	readonly stagedDrafts = new Map<string, string>();

	constructor(current = snapshot({
		...emptyRoomsSessionState(),
		directories: [{
			id: "directory",
			locator: "127.0.0.1:1",
			home: true,
			nick: "ada",
			standing: null,
		}],
	})) {
		this.current = current;
	}

	onSnapshot(_listener: (value: RoomsSessionSnapshot) => void): () => void {
		return () => {};
	}

	onOperationsInvalidated(_listener: (scope: string) => void): () => void {
		return () => {};
	}

	openDirect(direct: { id: string }): Promise<RoomsSessionSnapshot> {
		this.directIds.push(direct.id);
		return Promise.resolve(this.current);
	}

	leaveConversation(id: string): Promise<RoomsSessionSnapshot> {
		this.removedConversationIds.push(id);
		return Promise.resolve(this.current);
	}

	joinRoom(
		room: { name: string },
		directory?: { locator: string; nick: string },
	): Promise<RoomsSessionSnapshot> {
		this.joinedRooms.push({ room, directory });
		return Promise.resolve(this.current);
	}

	select(id: string): Promise<RoomsSessionSnapshot> {
		this.selectedIds.push(id);
		return Promise.resolve(this.current);
	}

	command(name: string, _args: string[]): Promise<RoomsSessionSnapshot> {
		this.commandNames.push(name);
		return Promise.resolve(this.current);
	}

	setIgnoredNames(_names: readonly string[]): Promise<RoomsSessionSnapshot> {
		return this.command("setIgnoredNames", []);
	}

	connectRoomIrc(): Promise<RoomsSessionSnapshot> {
		return Promise.resolve(this.current);
	}

	takeRoomModerator(conversationId: string, sturdyref?: string): Promise<RoomsSessionSnapshot> {
		this.moderatorRequests.push({ conversationId, sturdyref });
		return Promise.resolve(this.current);
	}

	refreshSnapshot(): Promise<RoomsSessionSnapshot> {
		return Promise.resolve(this.current);
	}

	setDraft(_conversation: string, _text: string): Promise<RoomsSessionSnapshot> {
		const result = deferred<RoomsSessionSnapshot>();
		this.draftWrites.push(result);
		return result.promise;
	}

	stageDraft(conversation: string, text: string): void {
		this.stagedDrafts.set(conversation, text);
	}

	say(_conversation: string, _text: string): Promise<RoomsSessionSnapshot> {
		const result = deferred<RoomsSessionSnapshot>();
		this.sends.push(result);
		return result.promise;
	}

	operationsSnapshot(): Promise<never> {
		return Promise.reject(new Error("no operations in this fake"));
	}

	operatorSnapshot(): Promise<never> {
		return Promise.reject(new Error("no operator in this fake"));
	}
}

class SelectionRaceController extends FakeController {
	readonly #newerActive: string;

	constructor(current: RoomsSessionSnapshot, newerActive: string) {
		super(current);
		this.#newerActive = newerActive;
	}

	override select(id: string): Promise<RoomsSessionSnapshot> {
		const selected = super.select(id);
		this.current = {
			...this.current,
			revision: this.current.revision + 1,
			checkpoint: { ...this.current.checkpoint, active: this.#newerActive },
		};
		return selected;
	}
}

class SettledSelectionController extends FakeController {
	override select(id: string): Promise<RoomsSessionSnapshot> {
		void super.select(id);
		this.current = {
			...this.current,
			revision: this.current.revision + 1,
			checkpoint: { ...this.current.checkpoint, active: id },
		};
		return Promise.resolve(this.current);
	}
}

function resetStore(): void {
	store.set({
		...store.initial,
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
		toasts: [],
	});
}

function addDmDirectory(): void {
	const directory = dirId("directory");
	store.set({
		dirs: new Map([[
			directory,
			{
				id: directory,
				locator: "127.0.0.1:1",
				liveRooms: new Map(),
				dmablePeers: new Map([["bo", { name: "bo", registrationId: registrationId(1) }]]),
				requestedNick: "ada",
				nick: "ada",
				slot: 1,
				reached: true,
				session: "connected",
				statusText: "",
				dmUnreachable: "",
				standing: null,
			},
		]]),
		homeDir: directory,
	});
}

function addActiveDm(): void {
	const directory = dirId("directory");
	addDmDirectory();
	const conversation = store.ensureDm(directory, "bo", registrationId(1));
	if (conversation == null) throw new Error("the fake DM was not created");
	store.showConv(conversation.key);
}

function sessionFor(controller: FakeController): ReturnType<typeof createAttachedRoomsSession> {
	return createAttachedRoomsSession(
		{} as RoomsBrowserController,
		controller as unknown as import("../web/ui/session/attached.ts").AttachedRoomsController,
		{} as import("../web/ui/session/attached_files.ts").AttachedSessionFiles,
	);
}

function waitForDraftSave(): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, 180));
}

Deno.test("attached DM creation opens the conversation in one command", async () => {
	resetStore();
	addDmDirectory();
	const controller = new FakeController();
	sessionFor(controller).startDm("bo");
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(controller.directIds.length, 1);
	assertEquals(controller.selectedIds, []);
});

Deno.test("attached command DM creation opens the conversation in one command", async () => {
	resetStore();
	addDmDirectory();
	const controller = new FakeController();
	const powers = attachedCommandPowers(
		controller as unknown as import("../web/ui/session/attached.ts").AttachedRoomsController,
		{} as RoomsBrowserController,
		() => {},
	);
	powers.directMessage("bo");
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(controller.directIds.length, 1);
	assertEquals(controller.selectedIds, []);
});

Deno.test("attached DM creation reuses an existing open conversation", async () => {
	resetStore();
	addDmDirectory();
	const controller = new FakeController(snapshot({
		...emptyRoomsSessionState(),
		directories: [{
			id: "directory",
			locator: "127.0.0.1:1",
			home: true,
			nick: "ada",
			standing: null,
		}],
		conversations: [{
			kind: "direct",
			id: "existing-direct",
			directory: "directory",
			peer: "bo",
			peerRegistrationId: registrationId(1),
			closed: false,
			draft: "",
		}],
		active: null,
	}));
	sessionFor(controller).startDm("BO");
	const powers = attachedCommandPowers(
		controller as unknown as import("../web/ui/session/attached.ts").AttachedRoomsController,
		{} as RoomsBrowserController,
		() => {},
	);
	powers.directMessage("bo");
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(controller.directIds, []);
	assertEquals(controller.selectedIds, ["existing-direct", "existing-direct"]);
});

Deno.test("attached DM removal forgets live and closed conversations in one act", async () => {
	resetStore();
	const controller = new FakeController();
	const session = sessionFor(controller);
	const directory = dirId("directory");
	const live = store.ensureDm(directory, "bo", registrationId(1));
	const closed = store.restoreDm(directory, "cy", registrationId(2), "closed-direct", true);
	if (live == null || closed == null) throw new Error("the direct fixtures were not created");
	session.closeDm(live);
	session.closeDm(closed);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(controller.removedConversationIds, [live.persistId, closed.persistId]);
});

Deno.test("attached ignore and unignore wait for the shared snapshot", () => {
	resetStore();
	const controller = new FakeController();
	const powers = attachedCommandPowers(
		controller as unknown as import("../web/ui/session/attached.ts").AttachedRoomsController,
		{} as RoomsBrowserController,
		() => {},
	);
	store.set({ ignored: new Set(["bo"]) });
	powers.ignore("cy");
	assertEquals([...store.get().ignored], ["bo"]);
	powers.unignore("bo");
	assertEquals([...store.get().ignored], ["bo"]);
	assertEquals(controller.commandNames, ["setIgnoredNames", "setIgnoredNames"]);
});

Deno.test("attached public join submits one complete room intent", async () => {
	resetStore();
	const controller = new FakeController(snapshot());
	const session = createAttachedRoomsSession(
		{} as RoomsBrowserController,
		controller as unknown as import("../web/ui/session/attached.ts").AttachedRoomsController,
		{} as import("../web/ui/session/attached_files.ts").AttachedSessionFiles,
		{ defaultDirectoryLocator: "127.0.0.1:1" },
	);
	assertEquals(await session.join({ room: "general", locator: "", hidden: false }, "ada"), "");
	assertEquals(controller.joinedRooms.length, 1);
	assertEquals(controller.joinedRooms[0].room.name, "general");
	assertEquals(controller.joinedRooms[0].directory, { locator: "127.0.0.1:1", nick: "ada" });
	assertEquals(controller.commandNames, []);
});

Deno.test("attached rail presses leave route-level screens after an idempotent shared selection", async () => {
	resetStore();
	const directory = dirId("directory");
	const direct = {
		kind: "direct" as const,
		id: "direct-id",
		directory: "directory",
		peer: "bo",
		peerRegistrationId: registrationId(1),
		closed: false,
		draft: "",
	};
	const room = {
		kind: "room" as const,
		id: "room-id",
		directory: "directory",
		name: "general",
		held: false,
		standing: null,
		draft: "",
	};
	const initial = snapshot({
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [room, direct],
		active: room.id,
	});
	const controller = new SettledSelectionController(initial);
	const roomView = store.ensureRoom(directory, room.name, { persistId: room.id });
	const directView = store.restoreDm(directory, direct.peer, direct.peerRegistrationId, direct.id, false);
	if (directView == null) throw new Error("the attached rail fixture created no direct conversation");
	const session = sessionFor(controller);
	store.clearConv();
	session.pickRoom(directory, room.name, roomView.key);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.get().activeKey, roomView.key);
	store.clearConv();
	session.openConv(directView.key);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.get().activeKey, directView.key);
	assertEquals(controller.selectedIds, [room.id, direct.id]);

	const raced = new SelectionRaceController(initial, direct.id);
	store.clearConv();
	sessionFor(raced).pickRoom(directory, room.name, roomView.key);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.get().activeKey, null);
});

Deno.test("attached IRC identity answers from committed intent while live state remains reactive", async () => {
	resetStore();
	const directory = dirId("directory");
	store.set({
		dirs: new Map([[
			directory,
			{
				id: directory,
				locator: "127.0.0.1:1",
				liveRooms: new Map(),
				dmablePeers: new Map(),
				requestedNick: "ada",
				nick: "ada",
				slot: 1,
				reached: true,
				session: "connected",
				statusText: "",
				dmUnreachable: "",
				standing: null,
			},
		]]),
		homeDir: directory,
	});
	const room = store.ensureRoom(directory, "bridge", { persistId: "room-id" });
	const controller = new FakeController(roomsSessionSnapshot({
		issues: [{ subject: "room-irc:directory:room-id", reason: "IRC refused the registered nickname" }],
	}));
	assertEquals(await sessionFor(controller).connectIrcIdentity(room.key, "ada", "", ""), "");
});

Deno.test("attached room moderation passes the pasted sturdyref unchanged", async () => {
	resetStore();
	const directory = dirId("directory");
	const room = store.ensureRoom(directory, "general", { persistId: "room-id" });
	const controller = new FakeController();
	const sturdyref = "ocapn://moderator.example/s/room-authority";
	await sessionFor(controller).stewardRoom(room.key, sturdyref);
	assertEquals(controller.moderatorRequests, [{ conversationId: "room-id", sturdyref }]);
});

Deno.test("attached mention edits pass through shared draft persistence", async () => {
	resetStore();
	addActiveDm();
	store.setDraft("hello");
	const controller = new FakeController();
	const session = sessionFor(controller);
	session.mention("bo");
	const conversation = store.activeConv();
	if (conversation == null) throw new Error("the fake DM was not active");
	assertEquals(store.activeDraft().text, "hello @bo ");
	assertEquals(controller.stagedDrafts.get(conversation.persistId), "hello @bo ");
	await waitForDraftSave();
	assertEquals(controller.draftWrites.length, 1);
	controller.draftWrites[0].resolve(controller.current);
});

Deno.test("attached recall edits pass through shared draft persistence", async () => {
	resetStore();
	addActiveDm();
	const conversation = store.activeConv();
	if (conversation == null) throw new Error("the fake DM was not active");
	store.rememberLastSent(conversation.key, "say it again");
	const controller = new FakeController();
	const session = sessionFor(controller);
	assertEquals(session.recallLastSent(), "say it again");
	assertEquals(store.activeDraft().text, "say it again");
	assertEquals(controller.stagedDrafts.get(conversation.persistId), "say it again");
	await waitForDraftSave();
	assertEquals(controller.draftWrites.length, 1);
	controller.draftWrites[0].resolve(controller.current);
});

Deno.test("a failed draft write cannot roll back a newer same-text draft", async () => {
	resetStore();
	addActiveDm();
	const controller = new FakeController();
	const session = sessionFor(controller);
	session.setDraft("one");
	await waitForDraftSave();
	session.setDraft("two");
	session.setDraft("one");
	controller.draftWrites[0].reject(new Error("first write failed"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.activeDraft().text, "one");
	await waitForDraftSave();
	assertEquals(controller.draftWrites.length, 2);
	controller.draftWrites[1].resolve(controller.current);
});

Deno.test("a failed send does not restore text after a newer local clear", async () => {
	resetStore();
	addActiveDm();
	store.setDraft("sent text");
	const controller = new FakeController();
	const session = sessionFor(controller);
	session.send();
	session.setDraft("");
	controller.sends[0].reject(new Error("send failed"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.activeDraft().text, "");
	await waitForDraftSave();
	controller.draftWrites[0].resolve(controller.current);
});

Deno.test("a failed send restores text when its clear is still current", async () => {
	resetStore();
	addActiveDm();
	store.setDraft("sent text");
	const controller = new FakeController();
	const session = sessionFor(controller);
	session.send();
	controller.sends[0].reject(new Error("send failed"));
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.activeDraft().text, "sent text");
	await waitForDraftSave();
	controller.draftWrites[0].resolve(controller.current);
});
