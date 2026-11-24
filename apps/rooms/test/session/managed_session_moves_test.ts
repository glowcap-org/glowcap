// A move that changes which session this browser answers to commits when its
// selection or setting lands. After that the page must reload even if the
// session's teardown refuses. Reporting the refusal instead would leave a
// stopped session behind the button, and every retry would meet "This
// workspace is closed". The tab's own choice is recorded before the selection,
// because a browser that refuses it afterward could not take the selection back.
// Saved data this version can't read is said by setup's notice alone, whichever
// press first meets it.
/// <reference lib="dom" />
import "../support/match_media.ts";
import { assert, assertEquals } from "../assert.ts";
import { snapshot } from "../support/managed_viewer.ts";
import { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { RoomsBrowserController } from "../../web/ui/controller/browser.ts";
import { browserFailure } from "../support/browser_failure.ts";
import { ROOMS_FAILURES } from "../../lib/failure_data.ts";
import { SESSION_STATE_UNREADABLE, SESSION_UNREACHABLE } from "../../lib/error_codes.ts";
import { fakeHandle } from "../support/managed_link.ts";
import { withPageGlobals } from "../support/page_globals.ts";
import { ACTIVE_VIEW } from "../../web/ui/session/managed/model.ts";
import type { RoomsManagedApplication, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
import type { OpenOrigin } from "../../web/ui/session/managed/open.ts";
const { RoomsPage } = await import("../../web/ui/page.ts");
const { createRoomsBrowserController, workspaceChosen } = await import("../../web/ui/controller/create_browser.ts");
const { managedWorkspaceActions } = await import("../../web/ui/session/managed/workspace.ts");
const { noteSessionOpenFailure } = await import("../../web/ui/store/chrome.ts");
const { openOn } = await import("../../web/ui/session/managed/open.ts");

/** A session whose selection and settings land, then whose teardown refuses:
 * what an attached session with an unreachable peer does. */
function brokenAttachedSession() {
	const calls: unknown[][] = [];
	const current = snapshot();
	const session = {
		readBeforeSending: () => Promise.resolve(current),
		readNow: () => Promise.resolve(current),
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

const unreadable = () => browserFailure(-12, "unreadable", SESSION_STATE_UNREADABLE);
/** Each setup press that opens this browser's saved session. */
const opening: Record<string, (browser: RoomsBrowserController) => Promise<string>> = {
	"Use this browser": (browser) => browser.useLocalRoomsSession(),
	"Attach": (browser) => browser.attachRoomsSession("ocapn://other"),
	"Forget rooms and settings": (browser) => browser.resetBrowserWorkspace(),
};
for (const [press, run] of Object.entries(opening)) {
	Deno.test(`${press}, the first to meet saved data this version can't read, leaves it to setup's notice`, async () => {
		await withPageGlobals(async (reloads) => {
			const page = new RoomsPage();
			// Opening the saved session keeps the fact of its failure, as the page's
			// own opening does.
			const browser = createRoomsBrowserController(page, () => {}, () => "/", () => {
				const error = unreadable();
				noteSessionOpenFailure(page.projection, error, "this-browser");
				return Promise.reject(error);
			});
			assertEquals(await run(browser), "");
			assertEquals(page.projection.get().savedSessionUnreadable, true);
			assertEquals(reloads(), 0);
		});
	});
}

Deno.test("an attached session that cannot read its own saved data is said beside the link", async () => {
	await withPageGlobals(async (reloads) => {
		const page = new RoomsPage();
		const { session } = brokenAttachedSession();
		session.selectWorkspace = () => Promise.reject(unreadable());
		page.managedSession = session;
		const browser = createRoomsBrowserController(
			page,
			() => {},
			() => "/",
			() => Promise.reject(new Error("unused")),
		);
		assert(
			(await browser.attachRoomsSession("ocapn://other")).includes(SESSION_STATE_UNREADABLE),
			"the attach names the session's own unreadable data",
		);
		assertEquals(page.projection.get().savedSessionUnreadable, false);
		assertEquals(reloads(), 0);
	});
});

Deno.test("an attach whose session cannot be reached says so beside the link", async () => {
	await withPageGlobals(async (reloads) => {
		const page = new RoomsPage();
		// `attachWorkspace` dials through `dial_session`, which names a dial that
		// ran out of time `session-unreachable` with no binding status.
		const application = fakeHandle<RoomsManagedApplication>({
			attachWorkspace: () =>
				Promise.reject(browserFailure(null, "Workspace connection timed out", SESSION_UNREACHABLE)),
			close: () => Promise.resolve(),
			free() {},
		});
		const custody = fakeHandle<RoomsManagedWorkspace>({ free() {} });
		const session = new ManagedRoomsSession(application, custody, custody, () => {});
		page.managedSession = session;
		const browser = createRoomsBrowserController(
			page,
			() => {},
			() => "/",
			() => Promise.reject(new Error("unused")),
		);
		try {
			assertEquals(
				await browser.attachRoomsSession("ocapn://other"),
				`${ROOMS_FAILURES["session-unreachable"].summary} ${ROOMS_FAILURES["session-unreachable"].action} ` +
					"(session-unreachable: Workspace connection timed out)",
			);
			assertEquals(reloads(), 0);
		} finally {
			await session.close();
		}
	});
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

/** An application whose own saved session refuses to open when `fails` is
 * "this-browser", and otherwise opens and names an attached session, which
 * refuses to open. Each refuses as saved data this version can't read. */
function failingApplication(fails: OpenOrigin): RoomsManagedApplication {
	const home = snapshot();
	home.intent.accesses = [{ id: ACTIVE_VIEW, access: "attached" }];
	const custody = fakeHandle<RoomsManagedWorkspace>({ snapshot: () => Promise.resolve(home), free: () => {} });
	return fakeHandle<RoomsManagedApplication>({
		workspace: () => fails === "this-browser" ? Promise.reject(unreadable()) : Promise.resolve(custody),
		savedWorkspace: () => Promise.reject(unreadable()),
		close: () => Promise.resolve(),
		free: () => {},
	});
}
const origins: OpenOrigin[] = ["this-browser", "attached"];
for (const origin of origins) {
	Deno.test(`an opening that fails in the ${origin} session keeps the unreadable fact only for this browser's own`, async () => {
		const page = new RoomsPage();
		const heard: OpenOrigin[] = [];
		const failed = (error: unknown, where: OpenOrigin) => {
			heard.push(where);
			noteSessionOpenFailure(page.projection, error, where);
		};
		const report = () => {};
		const refused = await openOn(failingApplication(origin), report, "saved", failed).then(
			() => null,
			(error) => error,
		);
		assert(refused != null, "the opening fails");
		assertEquals(heard, [origin], "the failure is heard once, with where it arose");
		assertEquals(page.projection.get().savedSessionUnreadable, origin === "this-browser");
	});
}
