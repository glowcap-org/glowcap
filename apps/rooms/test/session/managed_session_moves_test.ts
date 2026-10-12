// A move that changes which session this browser answers to commits when its
// selection or setting lands. After that the page must reload even if the
// session's teardown refuses. Reporting the refusal instead would leave a
// stopped session behind the button, and every retry would meet "This
// workspace is closed".
/// <reference lib="dom" />
import { assert, assertEquals } from "../assert.ts";
import { snapshot } from "../support/managed_viewer.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { RoomsPage } = await import("../../web/ui/page.ts");
const { createRoomsBrowserController } = await import("../../web/ui/controller/create_browser.ts");
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
	};
	let reloads = 0;
	Object.defineProperty(globalThis, "location", {
		configurable: true,
		value: { pathname: "/", href: "https://rooms.test/", reload: () => reloads++ },
	});
	Object.defineProperty(globalThis, "history", { configurable: true, value: { replaceState() {} } });
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
