// The attached-session semantics harness: a fake controller recording what
// the page routed to the durable session, and the page fixtures the
// semantics and draft suites both stand on.

/// <reference lib="dom" />

import type { RoomsSessionSnapshot } from "../../lib/session/client.ts";
import { emptyRoomsSessionState, type RoomsSessionState } from "../../lib/rooms_state.ts";
import type { RoomsBrowserController } from "../../web/ui/controller/browser.ts";
import { registrationId } from "../support/registration.ts";
import { roomsSessionSnapshot } from "../support/session_snapshot.ts";

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

export const store = await import("../../web/ui/store.ts");
export const { attachedCommandPowers } = await import("../../web/ui/session/attached_command_powers.ts");
export const { createAttachedRoomsSession } = await import("../../web/ui/session/attached_session.ts");
export const { RoomsPage } = await import("../../web/ui/page.ts");
export const { dirId } = await import("../../web/ui/types.ts");

export type Deferred<T> = { promise: Promise<T>; resolve(value: T): void; reject(error: unknown): void };

export function deferred<T>(): Deferred<T> {
	let resolve!: (value: T) => void;
	let reject!: (error: unknown) => void;
	const promise = new Promise<T>((res, rej) => {
		resolve = res;
		reject = rej;
	});
	return { promise, resolve, reject };
}

export function snapshot(checkpoint = emptyRoomsSessionState()): RoomsSessionSnapshot {
	return roomsSessionSnapshot({ checkpoint });
}

export class FakeController {
	current: RoomsSessionSnapshot;
	readonly directIds: string[] = [];
	readonly removedConversationIds: string[] = [];
	readonly removedDirectoryIds: string[] = [];
	readonly selectedIds: string[] = [];
	readonly commandNames: string[] = [];
	readonly moderatorRequests: Array<{ conversationId: string; sturdyref?: string }> = [];
	readonly bridgeForms: Array<{ scope: string; action: string }> = [];
	readonly joinedRooms: Array<{
		room: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>;
		directory?: { locator: string; nick: string };
	}> = [];
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

	leaveDirectory(id: string): Promise<RoomsSessionSnapshot> {
		this.removedDirectoryIds.push(id);
		return Promise.resolve(this.current);
	}

	joinRoom(
		room: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>,
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

	submitRoomBridgeForm(
		_conversationId: string,
		scope: string,
		action: string,
	): Promise<RoomsSessionSnapshot> {
		this.bridgeForms.push({ scope, action });
		return Promise.resolve(this.current);
	}

	roomBridgeForm(): Promise<null> {
		return Promise.resolve(null);
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

	retireDraft(conversation: string): void {
		this.stagedDrafts.delete(conversation);
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

export function resetStore(page: InstanceType<typeof RoomsPage>): void {
	page.projection.reset();
}

export function addDmDirectory(page: InstanceType<typeof RoomsPage>): void {
	const directory = dirId("directory");
	page.projection.set({
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

export function addActiveDm(page: InstanceType<typeof RoomsPage>): void {
	const directory = dirId("directory");
	addDmDirectory(page);
	const conversation = store.ensureDm(page.projection, directory, "bo", registrationId(1));
	if (conversation == null) throw new Error("the fake DM was not created");
	store.showConv(page.projection, conversation.key);
}

export function sessionFor(
	page: InstanceType<typeof RoomsPage>,
	controller: FakeController,
): ReturnType<typeof createAttachedRoomsSession> {
	return createAttachedRoomsSession(
		page,
		{} as RoomsBrowserController,
		controller as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController,
		{} as import("../../web/ui/session/attached_files.ts").AttachedSessionFiles,
	);
}

export function waitForDraftSave(): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, 180));
}
