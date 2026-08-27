/// <reference lib="dom" />

import { assertEquals } from "./assert.ts";
import {
	DEFAULT_ROOMS_VIEW_STATE,
	emptyRoomsSessionState,
	WORKSPACE_STATE_KEY,
	WORKSPACE_STATE_VERSION,
} from "../lib/rooms_state.ts";
import type { RoomsBrowserController } from "../web/ui/controller/browser.ts";

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
	value: { reload() {} },
});
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { importWorkspaceState } = await import("../web/ui/workspace_state.ts");
const { createAttachedRoomsSession } = await import("../web/ui/session/attached_session.ts");

Deno.test("an attached export never substitutes browser state for a missing shared checkpoint", () => {
	const controller = {
		current: null,
		onOperationsInvalidated: () => () => {},
		onSnapshot: () => () => {},
	} as unknown as import("../web/ui/session/attached.ts").AttachedRoomsController;
	const session = createAttachedRoomsSession(
		{} as RoomsBrowserController,
		controller,
		{} as import("../web/ui/session/attached_files.ts").AttachedSessionFiles,
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
	const sturdyref = "ocapn://session.example/s/shared";
	const initial = {
		version: WORKSPACE_STATE_VERSION,
		controller: { kind: "attached" as const, sturdyref },
		session: emptyRoomsSessionState(),
		view: DEFAULT_ROOMS_VIEW_STATE,
	};
	assertEquals(importWorkspaceState(JSON.stringify(initial)), "");
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
		replaceCheckpoint: (next: typeof checkpoint) => {
			checkpoint = next;
			return Promise.resolve({ ...snapshot(), revision: 1 });
		},
	} as unknown as import("../web/ui/session/attached.ts").AttachedRoomsController;
	const session = createAttachedRoomsSession(
		{} as RoomsBrowserController,
		controller,
		{} as import("../web/ui/session/attached_files.ts").AttachedSessionFiles,
	);
	const imported = { ...initial, session: { ...checkpoint, standing: "shared import" } };
	assertEquals(await session.importRoomsState(JSON.stringify(imported)), "");
	assertEquals(checkpoint.standing, "shared import");
	const saved = JSON.parse(browserStorage.get(WORKSPACE_STATE_KEY) ?? "null");
	assertEquals(saved.controller, { kind: "attached", sturdyref });
	assertEquals(saved.session.standing, "shared import");
});

Deno.test("clearing an attached state empties the remote checkpoint without clearing its archive", async () => {
	const sturdyref = "ocapn://session.example/s/clear";
	const initial = {
		version: WORKSPACE_STATE_VERSION,
		controller: { kind: "attached" as const, sturdyref },
		session: { ...emptyRoomsSessionState(), standing: "before clear" },
		view: DEFAULT_ROOMS_VIEW_STATE,
	};
	assertEquals(importWorkspaceState(JSON.stringify(initial)), "");
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
	} as unknown as import("../web/ui/session/attached.ts").AttachedRoomsController;
	const session = createAttachedRoomsSession(
		{} as RoomsBrowserController,
		controller,
		{} as import("../web/ui/session/attached_files.ts").AttachedSessionFiles,
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
