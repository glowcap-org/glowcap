/// <reference lib="dom" />

import { assertEquals } from "../assert.ts";
import {
	DEFAULT_ROOMS_VIEW_STATE,
	emptyRoomsSessionState,
	WORKSPACE_STATE_KEY,
	WORKSPACE_STATE_VERSION,
} from "../../lib/rooms_state.ts";
import type { RoomsBrowserController } from "../../web/ui/controller/browser.ts";
import { fixtureSturdyref } from "../support/workspace.ts";

const browserStorage = new Map<string, string>();
Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: {
		getItem: (key: string) => browserStorage.get(key) ?? null,
		setItem: (key: string, value: string) => browserStorage.set(key, value),
		removeItem: (key: string) => browserStorage.delete(key),
	},
});
Object.defineProperty(globalThis, "location", {
	configurable: true,
	value: { href: "https://rooms.test/", reload() {} },
});
Object.defineProperty(globalThis, "history", {
	configurable: true,
	value: { replaceState() {} },
});
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { importWorkspaceState } = await import("../../web/ui/workspace/bundle.ts");
const { createAttachedRoomsSession } = await import("../../web/ui/session/attached_session.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");

Deno.test("an attached export never substitutes browser state for a missing shared checkpoint", () => {
	const controller = {
		current: null,
		onOperationsInvalidated: () => () => {},
		onOperationsRead: () => () => {},
		onSnapshot: () => () => {},
	} as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController;
	const page = new RoomsPage();
	const session = createAttachedRoomsSession(
		page,
		{} as RoomsBrowserController,
		controller,
		{} as import("../../web/ui/session/attached_files.ts").AttachedSessionFiles,
	);
	let refusal = "";
	try {
		session.exportRoomsState();
	} catch (error) {
		refusal = error instanceof Error ? error.message : String(error);
	}
	assertEquals(refusal, "The shared session has not supplied its checkpoint yet.");
});

Deno.test("an attached state import replaces the remote checkpoint and preserves attachment", async () => {
	const page = new RoomsPage();
	const sturdyref = fixtureSturdyref("ocapn://session.example", "shared");
	const initial = {
		version: WORKSPACE_STATE_VERSION,
		controller: { kind: "attached" as const, sturdyref },
		session: emptyRoomsSessionState(),
		view: DEFAULT_ROOMS_VIEW_STATE,
	};
	assertEquals(importWorkspaceState(page, JSON.stringify(initial)), "");
	let checkpoint = emptyRoomsSessionState();
	const snapshot = () => ({
		revision: 0,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: [],
		memberLocator: null,
		roomViews: [],
	});
	const controller = {
		current: snapshot(),
		onSnapshot(listener: (value: ReturnType<typeof snapshot>) => void) {
			listener(snapshot());
			return () => {};
		},
		onOperationsInvalidated() {
			return () => {};
		},
		onOperationsRead() {
			return () => {};
		},
		replaceCheckpoint: (next: typeof checkpoint) => {
			checkpoint = next;
			return Promise.resolve({ ...snapshot(), revision: 1 });
		},
	} as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController;
	const session = createAttachedRoomsSession(
		page,
		{} as RoomsBrowserController,
		controller,
		{} as import("../../web/ui/session/attached_files.ts").AttachedSessionFiles,
	);
	const imported = { ...initial, session: { ...checkpoint, standing: "shared import" } };
	assertEquals(await session.importRoomsState(JSON.stringify(imported)), "");
	assertEquals(checkpoint.standing, "shared import");
	const saved = JSON.parse(browserStorage.get(WORKSPACE_STATE_KEY) ?? "null");
	assertEquals(saved.controller, { kind: "attached", sturdyref });
	assertEquals(saved.session.standing, "shared import");
});

Deno.test("clearing an attached state empties the remote checkpoint without clearing its archive", async () => {
	const page = new RoomsPage();
	const sturdyref = fixtureSturdyref("ocapn://session.example", "clear");
	const initial = {
		version: WORKSPACE_STATE_VERSION,
		controller: { kind: "attached" as const, sturdyref },
		session: { ...emptyRoomsSessionState(), standing: "before clear" },
		view: DEFAULT_ROOMS_VIEW_STATE,
	};
	assertEquals(importWorkspaceState(page, JSON.stringify(initial)), "");
	let checkpoint = initial.session;
	let archiveTouched = false;
	const controller = {
		current: {
			revision: 0,
			checkpoint,
			pendingEffects: [],
			pendingEffectDetails: [],
			issues: [],
			connectedDirectories: [],
			memberLocator: null,
			roomViews: [],
		},
		onSnapshot() {
			return () => {};
		},
		onOperationsInvalidated() {
			return () => {};
		},
		onOperationsRead() {
			return () => {};
		},
		replaceCheckpoint: (next: typeof checkpoint) => {
			checkpoint = next;
			return Promise.resolve({
				revision: 1,
				checkpoint,
				pendingEffects: [],
				pendingEffectDetails: [],
				issues: [],
				connectedDirectories: [],
				memberLocator: null,
				roomViews: [],
			});
		},
	} as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController;
	const session = createAttachedRoomsSession(
		page,
		{} as RoomsBrowserController,
		controller,
		{} as import("../../web/ui/session/attached_files.ts").AttachedSessionFiles,
	);
	browserStorage.set("rooms-history-sentinel", "kept");
	const originalSet = globalThis.localStorage.setItem;
	Object.defineProperty(globalThis.localStorage, "setItem", {
		value: (key: string, value: string) => {
			if (key === "rooms-history-sentinel") archiveTouched = true;
			browserStorage.set(key, value);
		},
	});
	try {
		assertEquals(await session.clearRoomsState(), "");
	} finally {
		Object.defineProperty(globalThis.localStorage, "setItem", { value: originalSet });
	}
	assertEquals(checkpoint, emptyRoomsSessionState());
	const saved = JSON.parse(browserStorage.get(WORKSPACE_STATE_KEY) ?? "null");
	assertEquals(saved.controller, { kind: "attached", sturdyref });
	assertEquals(saved.session.directories, []);
	assertEquals(browserStorage.get("rooms-history-sentinel"), "kept");
	assertEquals(archiveTouched, false);
});

function countReloads(work: () => Promise<void>): Promise<number> {
	const location = globalThis.location as { reload(): void };
	const original = location.reload;
	let reloads = 0;
	location.reload = () => {
		reloads += 1;
	};
	return work().finally(() => {
		location.reload = original;
	}).then(() => reloads);
}

function hostedEnvelope(sturdyref: string) {
	return {
		version: WORKSPACE_STATE_VERSION,
		controller: { kind: "hosted" as const, sturdyref },
		session: emptyRoomsSessionState(),
		view: DEFAULT_ROOMS_VIEW_STATE,
	};
}

Deno.test("a hosted state import replaces the checkpoint without reloading", async () => {
	const page = new RoomsPage();
	const sturdyref = fixtureSturdyref("ocapn://session.example", "hosted");
	const initial = hostedEnvelope(sturdyref);
	assertEquals(importWorkspaceState(page, JSON.stringify(initial)), "");
	let checkpoint = emptyRoomsSessionState();
	const snapshot = () => ({
		revision: 0,
		checkpoint,
		pendingEffects: [],
		pendingEffectDetails: [],
		issues: [],
		connectedDirectories: [],
		memberLocator: null,
		roomViews: [],
	});
	const controller = {
		current: snapshot(),
		onSnapshot(listener: (value: ReturnType<typeof snapshot>) => void) {
			listener(snapshot());
			return () => {};
		},
		onOperationsInvalidated() {
			return () => {};
		},
		onOperationsRead() {
			return () => {};
		},
		replaceCheckpoint: (next: typeof checkpoint) => {
			checkpoint = next;
			return Promise.resolve({ ...snapshot(), revision: 1 });
		},
	} as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController;
	const session = createAttachedRoomsSession(
		page,
		{} as RoomsBrowserController,
		controller,
		{} as import("../../web/ui/session/attached_files.ts").AttachedSessionFiles,
	);
	const imported = { ...initial, session: { ...checkpoint, standing: "hosted import" } };
	const reloads = await countReloads(async () => {
		assertEquals(await session.importRoomsState(JSON.stringify(imported)), "");
	});
	assertEquals(reloads, 0);
	assertEquals(checkpoint.standing, "hosted import");
	const saved = JSON.parse(browserStorage.get(WORKSPACE_STATE_KEY) ?? "null");
	assertEquals(saved.controller, { kind: "hosted", sturdyref });
	assertEquals(saved.session.standing, "hosted import");
});

Deno.test("a hosted connection choice does not reload this tab", async () => {
	const page = new RoomsPage();
	const sturdyref = fixtureSturdyref("ocapn://session.example", "hosted-dm");
	assertEquals(importWorkspaceState(page, JSON.stringify(hostedEnvelope(sturdyref))), "");
	let chosen: { dm: string; viz: string } | null = null;
	const checkpoint = emptyRoomsSessionState();
	const controller = {
		current: {
			revision: 0,
			checkpoint,
			pendingEffects: [],
			pendingEffectDetails: [],
			issues: [],
			connectedDirectories: [],
			memberLocator: null,
			roomViews: [],
		},
		onSnapshot() {
			return () => {};
		},
		onOperationsInvalidated() {
			return () => {};
		},
		onOperationsRead() {
			return () => {};
		},
		chooseConnection: (dm: string, viz: string) => {
			chosen = { dm, viz };
			return Promise.resolve({
				revision: 1,
				checkpoint: { ...checkpoint, dmMode: dm, vizOverride: viz },
				pendingEffects: [],
				pendingEffectDetails: [],
				issues: [],
				connectedDirectories: [],
				memberLocator: null,
				roomViews: [],
			});
		},
	} as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController;
	const session = createAttachedRoomsSession(
		page,
		{} as RoomsBrowserController,
		controller,
		{} as import("../../web/ui/session/attached_files.ts").AttachedSessionFiles,
	);
	const reloads = await countReloads(async () => {
		assertEquals(await session.applySettings({ dm: "relay" }), true);
	});
	assertEquals(reloads, 0);
	assertEquals(chosen, { dm: "relay", viz: checkpoint.vizOverride });
});
