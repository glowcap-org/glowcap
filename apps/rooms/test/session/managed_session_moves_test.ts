// A move that changes which session this browser answers to commits when its
// selection or setting lands. After that the page must reload even if the
// session's teardown refuses. Reporting the refusal instead would leave a
// stopped session behind the button, and every retry would meet "This
// workspace is closed". The tab's own choice is recorded before the selection,
// because a browser that refuses it afterward could not take the selection back.
/// <reference lib="dom" />
import "../support/match_media.ts";
import { assert, assertEquals } from "../assert.ts";
import { snapshot } from "../support/managed_viewer.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
const { RoomsPage } = await import("../../web/ui/page.ts");
const { createRoomsBrowserController, workspaceChosen } = await import("../../web/ui/controller/create_browser.ts");
const { managedWorkspaceActions } = await import("../../web/ui/session/managed/workspace.ts");

/** A session whose selection and settings land, then whose teardown refuses:
 * what an attached session with an unreachable peer does. */
function brokenAttachedSession() {
	const calls: unknown[][] = [];
	const current = snapshot();
	const session = {
		refresh: () => Promise.resolve(current),
		selectWorkspace: (uri: string | null) => {
			calls.push(["selectWorkspace", uri]);
			return Promise.resolve();
		},
		actions: {
			run: (...args: unknown[]) => {
				calls.push(args);
				return Promise.resolve();
			},
		},
		close: () => {
			calls.push(["close"]);
			return Promise.reject(new Error("the attached peer is unreachable"));
		},
	} as unknown as ManagedRoomsSession;
	return { session, calls };
}

async function withPageGlobals(run: (reloads: () => number) => Promise<void>): Promise<void> {
	const prior = {
		location: Object.getOwnPropertyDescriptor(globalThis, "location"),
		history: Object.getOwnPropertyDescriptor(globalThis, "history"),
		document: Object.getOwnPropertyDescriptor(globalThis, "document"),
	};
	let reloads = 0;
	Object.defineProperty(globalThis, "location", {
		configurable: true,
		value: { pathname: "/", href: "https://rooms.test/", reload: () => reloads++ },
	});
	Object.defineProperty(globalThis, "history", { configurable: true, value: { replaceState() {} } });
	// A page a Rooms server sent: it carries no host mark, so it reloads in place.
	Object.defineProperty(globalThis, "document", {
		configurable: true,
		value: { baseURI: "https://rooms.test/", querySelector: () => null },
	});
	try {
		await run(() => reloads);
	} finally {
		for (const [name, descriptor] of Object.entries(prior)) {
			if (descriptor != null) Object.defineProperty(globalThis, name, descriptor);
			else Reflect.deleteProperty(globalThis, name);
		}
	}
}

for (const move of ["leaveRoomsSession", "useLocalRoomsSession", "attachRoomsSession"] as const) {
	Deno.test(`a committed ${move} reloads even when the session's teardown refuses`, async () => {
		await withPageGlobals(async (reloads) => {
			const page = new RoomsPage();
			const { session, calls } = brokenAttachedSession();
			page.managedSession = session;
			const browser = createRoomsBrowserController(
				page,
				() => {},
				() => "/",
				() => Promise.reject(new Error("unexpected workspace open")),
			);
			const uri = move === "attachRoomsSession" ? "ocapn://other" : null;
			const why = move === "attachRoomsSession"
				? await browser.attachRoomsSession("ocapn://other")
				: await browser[move]();
			assertEquals(why, "");
			assertEquals(calls, [["selectWorkspace", uri], ["close"]]);
			assertEquals(reloads(), 1);
		});
	});
}

/** Replace the browser's two storage areas for one test. */
async function withStorage(local: Partial<Storage>, run: () => Promise<void>): Promise<void> {
	const kept = new Map<string, string>();
	const memory = {
		getItem: (key: string) => kept.get(key) ?? null,
		setItem: (key: string, value: string) => void kept.set(key, value),
		removeItem: (key: string) => void kept.delete(key),
	};
	const prior = ["localStorage", "sessionStorage"].map((name) =>
		[name, Object.getOwnPropertyDescriptor(globalThis, name)] as const
	);
	Object.defineProperty(globalThis, "sessionStorage", { configurable: true, value: memory });
	Object.defineProperty(globalThis, "localStorage", { configurable: true, value: { ...memory, ...local } });
	try {
		await run();
	} finally {
		for (const [name, descriptor] of prior) {
			if (descriptor != null) Object.defineProperty(globalThis, name, descriptor);
			else Reflect.deleteProperty(globalThis, name);
		}
	}
}

Deno.test("a move whose choice the browser refuses to keep selects nothing", async () => {
	const refusing = {
		setItem: () => {
			throw new DOMException("Quota exceeded.", "QuotaExceededError");
		},
	};
	await withStorage(refusing, () =>
		withPageGlobals(async (reloads) => {
			const page = new RoomsPage();
			const { session, calls } = brokenAttachedSession();
			page.managedSession = session;
			const browser = createRoomsBrowserController(page, () => {}, () =>
				"/", () =>
				Promise.reject(new Error("unused")));
			const why = await browser.attachRoomsSession("ocapn://other");
			assert(why.includes("local-storage-blocked"), why);
			assertEquals(calls, [], "the selection stays where the tab's choice says it is");
			assertEquals(reloads(), 0);
		}));
});

Deno.test("a selection that does not land puts the tab's choice back", async () => {
	await withStorage({}, () =>
		withPageGlobals(async (reloads) => {
			const page = new RoomsPage();
			const { session } = brokenAttachedSession();
			page.managedSession = session;
			const browser = createRoomsBrowserController(page, () => {}, () =>
				"/", () =>
				Promise.reject(new Error("unused")));
			assertEquals(await browser.useLocalRoomsSession(), "");
			assertEquals(workspaceChosen(), true);
			session.selectWorkspace = () =>
				Promise.reject(new Error("the session refused"));
			assert((await browser.leaveRoomsSession()) !== "", "the refusal is the move's own");
			assertEquals(workspaceChosen(), true, "the next load opens the session this tab still holds");
			assertEquals(reloads(), 1, "only the first move left the page");
		}));
});

Deno.test("applied settings reload even when the session's teardown refuses", async () => {
	await withPageGlobals(async (reloads) => {
		const page = new RoomsPage();
		const { session, calls } = brokenAttachedSession();
		const actions = managedWorkspaceActions(page, session, () => Promise.resolve());
		assertEquals(await actions.applySettings({ dm: "webrtc" }), true);
		assert(calls.some((call) => call[0] === "chooseConnection"), "the setting was committed before the reload");
		assertEquals(reloads(), 1);
	});
});

Deno.test("unreadable import is refused before session actions", async () => {
	const page = new RoomsPage();
	const { session, calls } = brokenAttachedSession();
	const actions = managedWorkspaceActions(page, session, () => Promise.resolve());
	for (const raw of ["not JSON", "null", "{}", "[]"]) {
		const why = await actions.importRoomsState(raw);
		assert(why.startsWith("This file isn't a Rooms session export."), "invalid import escaped its catalog refusal");
		if (raw === "not JSON") assert(why.includes("local-not-export"), "syntax detail retains its refusal code");
	}
	assertEquals(calls, []);
});
