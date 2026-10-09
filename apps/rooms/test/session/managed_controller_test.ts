// Production join gestures reuse exact directory custody and classify room
// links before invoking any directory acquisition.
/// <reference lib="dom" />
import { assert, assertEquals } from "../assert.ts";
import { deferred, snapshot, viewer } from "../support/managed_viewer.ts";
import { ManagedNavigation } from "../../web/ui/session/managed/navigation.ts";
import { completeResult } from "../../web/ui/session/managed/completion.ts";
import { type ManagedOperation, WorkspaceConflict } from "../../web/ui/session/managed/operation.ts";
import { ResultRecipe } from "../../web/ui/session/managed/result_recipe.ts";
import { initializeApplication } from "../support/application.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { ManagedHistory } from "../../web/ui/session/managed/history.ts";
import type { RoomInfo } from "../../lib/directory_publications.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { RoomsPage } = await import("../../web/ui/page.ts");
const { createManagedController } = await import("../../web/ui/session/managed/controller.ts");
const { createRoomsBrowserController } = await import("../../web/ui/controller/create_browser.ts");
const { presentationFiles } = await import("../../web/ui/session/managed/files.ts");
const { directoryId } = await import("../../web/ui/application.ts");
const store = await import("../../web/ui/store.ts");
await initializeApplication();
function fixture(listed: RoomInfo[] = [], duringRead: () => void = () => {}) {
	const page = new RoomsPage();
	const current = snapshot();
	const route = "127.0.0.1:1234";
	const id = directoryId(route)!;
	current.intent.directories.push({
		id,
		access: "exact-directory",
		home: true,
		nick: "ada",
		nickAllocation: "exact",
		standing: null,
	});
	const calls: unknown[][] = [];
	const session = {
		current,
		refresh: () => Promise.resolve(current),
		directoryRegistered: () => Promise.resolve(),
		permits: () => true,
		command: (name: string, args: string[]) => {
			calls.push([name, args]);
			return Promise.resolve({});
		},
		completeResult: () => Promise.resolve(),
		workspace: {
			directoryReader: (directory: string) => {
				calls.push(["directoryReader", directory]);
				return Promise.resolve({
					namedRooms: () => {
						duringRead();
						return Promise.resolve(listed);
					},
					free: () => calls.push(["freeReader"]),
				});
			},
		},
		actions: {
			publicRoom: (...args: unknown[]) => {
				calls.push(["publicRoom", ...args]);
				return Promise.resolve("room");
			},
			directory: (...args: unknown[]) => {
				calls.push(["directory", ...args]);
				return Promise.resolve();
			},
			run: (...args: unknown[]) => {
				calls.push(args);
				return Promise.resolve();
			},
			roomLink: (...args: unknown[]) => {
				calls.push(["roomLink", ...args]);
				return Promise.resolve("room");
			},
			createRoom: (...args: unknown[]) => {
				calls.push(["createRoom", ...args]);
				return Promise.resolve("room");
			},
		},
	} as unknown as ManagedRoomsSession;
	Object.assign(session, { navigation: new ManagedNavigation(session) });
	session.navigation.select = (id: string) => {
		session.navigation.dismissAcquisition();
		calls.push(["select", [id]]);
		return Promise.resolve();
	};
	page.managedSession = session;
	const files = presentationFiles(page.projection, () => null);
	const controller = createManagedController(
		page,
		{ setTheme() {}, showRoster() {}, aboutConversation() {} },
		session,
		files,
		route,
		{ refresh: () => Promise.resolve() } as unknown as ManagedHistory,
	);
	return {
		page,
		id,
		route,
		calls,
		current,
		controller,
		close: () => {
			files.close();
			for (const key of [...page.projection.get().convs.keys()]) store.forgetConv(page.projection, key);
		},
	};
}
for (const closed of [false, true]) {
	Deno.test(`direct rail close ${closed ? "dismisses saved entry" : "ends live connection"}`, async () => {
		const f = fixture();
		store.openDir(f.page.projection, f.id, f.route);
		const dm = store.restoreDm(f.page.projection, f.id, "guest-2", "peer-registration", "saved", closed)!;
		try {
			await f.controller.closeDm(dm);
			assertEquals(f.calls, [[closed ? "leaveConversation" : "closeDirect", ["saved"]]]);
		} finally {
			f.close();
		}
	});
}
for (const superseded of [false, true]) {
	Deno.test(`direct reconnect retains peer identity and respects newer navigation, superseded=${superseded}`, async () => {
		const f = fixture();
		store.openDir(f.page.projection, f.id, f.route);
		const dm = store.restoreDm(f.page.projection, f.id, "bob", "original-registration", "saved", true)!;
		const entered = deferred<void>();
		const registered = deferred<void>();
		const session = f.page.managedSession!;
		session.directoryRegistered = () => {
			entered.resolve();
			return registered.promise;
		};
		session.actions.direct = (...args) => {
			assertEquals(args, [f.id, "bob", false, "original-registration"]);
			return Promise.resolve("saved");
		};
		try {
			const reconnect = f.controller.recoverDm(dm.key);
			await entered.promise;
			if (superseded) session.navigation.dismissAcquisition();
			registered.resolve();
			assertEquals(await reconnect, "");
			assertEquals(f.calls.filter(([name]) => name === "select"), superseded ? [] : [["select", ["saved"]]]);
		} finally {
			registered.resolve();
			await session.navigation.close();
			f.close();
		}
	});
}
Deno.test("showing the current address preserves a pending room acquisition; leaving it supersedes selection", async () => {
	const f = fixture();
	const prior = Object.getOwnPropertyDescriptor(globalThis, "location");
	Object.defineProperty(globalThis, "location", {
		configurable: true,
		value: { pathname: "/directory", search: "?dir=held" },
	});
	let active = "/directory?dir=held";
	const navigated: string[] = [];
	const navigation = f.page.managedSession!.navigation;
	const release = deferred<void>();
	const selected: boolean[] = [];
	const pending = navigation.acquire(async (current) => {
		await release.promise;
		selected.push(current());
	});
	try {
		const browser = createRoomsBrowserController(
			f.page,
			(path) => {
				navigated.push(path);
				// A fresh arrival at the directory supersedes acquisition.
				navigation.dismissAcquisition();
			},
			() => active,
			() => Promise.reject(new Error("unexpected workspace open")),
		);
		await browser.showActiveConversation(Promise.resolve());
		assertEquals(navigated, []);
		release.resolve();
		await pending;
		assertEquals(selected, [true]);
		active = "/directory?dir=other";
		await browser.showActiveConversation(Promise.resolve());
		assertEquals(navigated, [active]);
	} finally {
		release.resolve();
		await pending;
		if (prior != null) Object.defineProperty(globalThis, "location", prior);
		else Reflect.deleteProperty(globalThis, "location");
		f.close();
	}
});
for (const verb of ["pickRoom", "openManagedRoom", "startDm"] as const) {
	Deno.test(`managed ${verb} returns completion of selection`, async () => {
		const f = fixture();
		const entered = deferred<void>();
		const release = deferred<void>();
		const session = f.page.managedSession!;
		session.actions.direct = () => Promise.resolve("direct");
		session.navigation.select = () => {
			entered.resolve();
			return release.promise;
		};
		const selecting = verb === "startDm"
			? f.controller.startDm("bo")
			: verb === "pickRoom"
			? f.controller.pickRoom(f.id, "created")
			: f.controller.openManagedRoom(f.id, "created", { entry: "open", visibility: "listed", speaking: "open" });
		try {
			assert(selecting instanceof Promise, `${verb} discarded selection completion`);
			let finished = false;
			void selecting.then(() => finished = true);
			await entered.promise;
			assertEquals(finished, false);
			release.resolve();
			await selecting;
			assertEquals(finished, true);
		} finally {
			release.resolve();
			await selecting;
			f.close();
		}
	});
}
for (const superseded of ["none", "conversation", "arrival"] as const) {
	Deno.test(`Operations waits for conversation selection and fences late acknowledgment, superseded=${superseded}`, async () => {
		const f = fixture();
		const priorLocation = Object.getOwnPropertyDescriptor(globalThis, "location");
		const priorHistory = Object.getOwnPropertyDescriptor(globalThis, "history");
		const history = { state: { key: "operations-arrival" } };
		Object.defineProperty(globalThis, "location", { configurable: true, value: { pathname: "/ops", search: "" } });
		Object.defineProperty(globalThis, "history", { configurable: true, value: history });
		let active = "/directory";
		const navigated: string[] = [];
		const release = deferred<void>();
		const browser = createRoomsBrowserController(
			f.page,
			(path) => navigated.push(path),
			() => active,
			() => Promise.reject(new Error("unexpected workspace open")),
		);
		const showing = browser.showActiveConversation(release.promise);
		try {
			assertEquals(navigated, []);
			if (superseded === "conversation") {
				active = "/room/newer";
				await browser.showActiveConversation(Promise.resolve());
			} else if (superseded === "arrival") history.state.key = "newer-operations-arrival";
			active = "/room/created";
			release.resolve();
			await showing;
			assertEquals(
				navigated,
				superseded === "none" ? [active] : superseded === "conversation" ? ["/room/newer"] : [],
			);
		} finally {
			release.resolve();
			await showing;
			if (priorLocation != null) Object.defineProperty(globalThis, "location", priorLocation);
			else Reflect.deleteProperty(globalThis, "location");
			if (priorHistory != null) Object.defineProperty(globalThis, "history", priorHistory);
			else Reflect.deleteProperty(globalThis, "history");
			f.close();
		}
	});
}
Deno.test("managed name join reads the directory and retains an existing local publication before discovery arrives", async () => {
	const f = fixture([{
		id: "exact-local-publication",
		name: "lobby",
		kind: "local",
		count: 1,
		origin: "",
		proof: "local",
		offers: "participant",
	}]);
	try {
		assertEquals(await f.controller.join({ locator: "", room: "lobby" }, { kind: "exact", name: "ada" }), {
			ok: true,
		});
		assertEquals(f.calls, [
			["directoryReader", f.id],
			["freeReader"],
			["publicRoom", f.id, "lobby", "exact-local-publication"],
			["select", ["room"]],
		]);
	} finally {
		f.close();
	}
});
Deno.test("managed rail naming creates an absent room through authoritative directory lookup", async () => {
	const f = fixture();
	try {
		f.controller.pickRoom(f.id, "new-room");
		await new Promise((resolve) => setTimeout(resolve, 0));
		assertEquals(f.calls.slice(0, 2), [["directoryReader", f.id], ["freeReader"]]);
		assertEquals(f.calls[2].slice(0, 3), ["createRoom", f.id, "new-room"]);
		assertEquals(f.calls[3], ["select", ["room"]]);
	} finally {
		f.close();
	}
});

for (const kind of ["name", "link", "creation"] as const) {
	Deno.test(`a late ${kind} acquisition settles without replacing a newer directory view`, async () => {
		const f = fixture();
		const entered = deferred<void>();
		const completed = deferred<string>();
		const acquire = () => {
			entered.resolve();
			return completed.promise;
		};
		f.page.managedSession!.actions.createRoom = acquire;
		f.page.managedSession!.actions.roomLink = acquire;
		try {
			const work = kind === "creation"
				? (f.controller.openManagedRoom(f.id, "new-room", {
					visibility: "listed",
					entry: "open",
					speaking: "open",
				}),
					null)
				: f.controller.join(
					kind === "link"
						? { locator: "ocapn://127.0.0.1%3A1234.tcp/s/ZXhhY3Qtcm9vbQ", room: "Room" }
						: { locator: "", room: "new-room" },
					{ kind: "exact", name: "ada" },
				);
			await entered.promise;
			store.openDir(f.page.projection, f.id, f.route);
			const directory = store.ensureDirectory(f.page.projection, f.id);
			const { showDirectory } = await import("../../web/ui/page_navigation.ts");
			showDirectory(f.page, f.id);
			completed.resolve("room");
			if (work != null) assertEquals(await work, { ok: true });
			else await new Promise((resolve) => setTimeout(resolve, 0));
			await f.page.managedSession!.navigation.close();
			assertEquals(f.page.projection.get().activeKey, directory.key);
			assertEquals(f.calls.filter(([name]) => name === "select"), []);
		} finally {
			f.close();
		}
	});
}
for (const savedPublication of ["held-publication", undefined, null]) {
	Deno.test(`managed name join with ${savedPublication === null ? "ambiguous entrances" : savedPublication == null ? "held authority" : "held publication"}`, async () => {
		const listed: RoomInfo = {
			id: "held-publication",
			name: "lobby",
			kind: "local",
			count: 1,
			origin: "",
			proof: "local",
			offers: null,
		};
		const f = fixture([listed]);
		try {
			f.current.intent.conversations.push({
				kind: "room",
				id: "held-room",
				directory: f.id,
				name: "lobby",
				publication: savedPublication ?? undefined,
				access: "saved-entry",
				control: null,
				reconnect: "requested",
				standing: null,
				draft: "",
			});
			if (savedPublication === null) {
				f.current.intent.conversations.push({ ...f.current.intent.conversations[0], id: "second-room" });
			}
			const joined = await f.controller.join({ locator: "", room: "lobby" }, { kind: "exact", name: "ada" });
			assertEquals(joined.ok, savedPublication !== null);
			if (savedPublication === null) {
				await f.controller.pickRoom(f.id, "lobby");
				assertEquals(f.page.projection.get().toasts.at(-1)?.text.includes("several saved rooms"), true);
			}
			assertEquals(
				f.calls,
				savedPublication === null
					? []
					: savedPublication == null
					? [["select", ["held-room"]]]
					: [["directoryReader", f.id], ["freeReader"], ["select", ["held-room"]]],
			);
		} finally {
			f.close();
		}
	});
}
Deno.test("managed name join does not reuse a namesake from another publication or directory", async () => {
	const f = fixture([{
		id: "current-publication",
		name: "lobby",
		kind: "local",
		count: 1,
		origin: "",
		proof: "local",
		offers: "participant",
	}]);
	try {
		for (const [directory, publication] of [[f.id, "old-publication"], ["elsewhere", "current-publication"]]) {
			f.current.intent.conversations.push({
				kind: "room",
				id: directory,
				directory,
				name: "lobby",
				publication,
				access: "saved-entry",
				control: null,
				reconnect: "requested",
				standing: null,
				draft: "",
			});
		}
		assertEquals(await f.controller.join({ locator: "", room: "lobby" }, { kind: "exact", name: "ada" }), {
			ok: true,
		});
		assertEquals(f.calls[2], ["publicRoom", f.id, "lobby", "current-publication"]);
	} finally {
		f.close();
	}
});
Deno.test("managed name join refuses an invitation-only publication without creating another room", async () => {
	const f = fixture([{
		id: "invite-only",
		name: "lobby",
		kind: "local",
		count: 1,
		origin: "",
		proof: "local",
		offers: null,
	}]);
	try {
		const result = await f.controller.join({ locator: "", room: "lobby" }, { kind: "exact", name: "ada" });
		assertEquals(result.ok, false);
		assertEquals(f.calls, [["directoryReader", f.id], ["freeReader"]]);
	} finally {
		f.close();
	}
});
Deno.test("managed name join refuses directory authority replaced during its read", async () => {
	const f = fixture([], () => {
		f.current.intent.directories[0] = { ...f.current.intent.directories[0], access: "replacement" };
	});
	try {
		const result = await f.controller.join({ locator: "", room: "lobby" }, { kind: "exact", name: "ada" });
		assertEquals(result.ok, false);
		assertEquals(f.calls, [["directoryReader", f.id], ["freeReader"]]);
	} finally {
		f.close();
	}
});
Deno.test("managed name join canceled during its read releases the reader without creating a room", async () => {
	const cancellation = new AbortController();
	const f = fixture([], () => cancellation.abort());
	try {
		const result = await f.controller.join(
			{ locator: "", room: "lobby" },
			{ kind: "exact", name: "ada" },
			cancellation.signal,
		);
		assertEquals(result, { ok: true });
		assertEquals(f.calls, [["directoryReader", f.id], ["freeReader"]]);
	} finally {
		f.close();
	}
});
Deno.test("managed moderator issuance selects the exact room through its command owner", async () => {
	const f = fixture();
	try {
		f.current.intent.conversations.push({
			kind: "room",
			id: "selected-room",
			directory: f.id,
			name: "garden",
			access: "room-access",
			source: "initiating-source",
			control: "room-manager",
			reconnect: "requested",
			standing: null,
			draft: "",
		});
		const room = store.ensureRoom(f.page.projection, f.id, "garden", { persistId: "selected-room" });
		assertEquals(await f.controller.stewardRoom(room.key), "");
		assertEquals(f.calls, [["issueRoomModerator", ["selected-room"]]]);
		assertEquals(f.current.intent.conversations[0], {
			kind: "room",
			id: "selected-room",
			directory: f.id,
			name: "garden",
			access: "room-access",
			source: "initiating-source",
			control: "room-manager",
			reconnect: "requested",
			standing: null,
			draft: "",
		});
	} finally {
		f.close();
	}
});
Deno.test("managed moderator result adopts its exact occurrence without changing room entrance", async () => {
	const f = fixture();
	const accepted = f.current;
	accepted.intent.conversations.push({
		kind: "room",
		id: "selected-room",
		directory: f.id,
		name: "garden",
		access: "room-access",
		source: "initiating-source",
		control: "room-manager",
		moderator: "room-access",
		reconnect: "requested",
		standing: null,
		draft: "",
	});
	const session = viewer({ snapshot: () => Promise.resolve(accepted) });
	let acquisitions = 0;
	const operation = {
		complete: (work: (recipe: ResultRecipe) => Promise<unknown>) => work(new ResultRecipe()),
		request: {
			originalIntent: () => ["issuance", 1, "issueRoomModerator", ["selected-room"]],
			adopted: () => Promise.resolve(false),
		},
		result: () => Promise.resolve({ moderator: "receipt-moderator" }),
		acquire: (next, mappings, releases) => {
			acquisitions++;
			const room = next.intent.conversations[0];
			assert(room.kind === "room", "The original room remains selected");
			assert(room.moderator !== "room-access", "The receipt supplies a new exact occurrence");
			assertEquals(room.access, "room-access");
			assertEquals(room.source, "initiating-source");
			assertEquals(room.control, "room-manager");
			assertEquals(mappings, [{
				result: { role: "roomAccess", key: "receipt-moderator" },
				destination: { role: "roomAccess", key: room.moderator },
			}]);
			assertEquals(releases, [], "Custody retirement preserves an entrance that aliases the old moderator");
			accepted.intent = next.intent;
			return Promise.resolve();
		},
	} as ManagedOperation;
	try {
		await completeResult(session, operation);
		assertEquals(acquisitions, 1);
	} finally {
		await session.close();
		f.close();
	}
});
Deno.test("managed directory revisit reuses custody and nickname choice is local intent", async () => {
	const f = fixture();
	try {
		assertEquals(await f.controller.reachDirectory(f.route, { kind: "exact", name: "ada" }), "");
		assertEquals(f.calls, []);
		assertEquals(await f.controller.reachDirectory(f.route, { kind: "automatic", base: "visitor" }), "");
		assertEquals(f.calls, [["chooseDirectoryNickname", [f.id, "visitor", "automatic"]]]);
		assertEquals(await f.controller.releaseNick(f.id), "");
		assertEquals(f.calls[1], ["chooseDirectoryNickname", [f.id, "", "exact"]]);
	} finally {
		f.close();
	}
});
Deno.test("managed room link joins the exact authority without fetching it as a directory", async () => {
	const f = fixture();
	try {
		const link = "ocapn://127.0.0.1%3A1234.tcp/s/ZXhhY3Qtcm9vbQ";
		assertEquals(await f.controller.join({ locator: link, room: "shared" }, { kind: "exact", name: "ada" }), {
			ok: true,
		});
		assertEquals(f.calls, [["roomLink", f.id, link, "shared", {
			route: f.route,
			nick: { kind: "exact", name: "ada" },
			home: true,
		}], ["select", ["room"]]]);
	} finally {
		f.close();
	}
});

for (const replaced of [false, true]) {
	Deno.test(`moderator admission conflict preserves exact manager, replaced=${replaced}`, async () => {
		const f = fixture();
		const selected = {
			kind: "room" as const,
			id: "selected",
			directory: f.id,
			name: "garden",
			source: "source",
			access: "entry",
			control: "manager",
			reconnect: "manual" as const,
			standing: null,
			draft: "",
		};
		f.current.intent.conversations.push(selected);
		const room = store.ensureRoom(f.page.projection, f.id, "garden", { persistId: selected.id });
		let attempts = 0;
		let completed = 0;
		const session = viewer({ snapshot: () => Promise.resolve(f.current) });
		await session.refresh();
		session.command = (_name, _args, _operation, validate) => {
			validate?.(f.current);
			if (++attempts === 1) {
				f.current.revision = "2";
				f.current.intent.standing = "away";
				if (replaced) selected.control = "another-manager";
				return Promise.reject(new WorkspaceConflict());
			}
			return Promise.resolve({} as ManagedOperation);
		};
		session.completeResult = () => {
			completed++;
			return Promise.resolve();
		};
		const files = presentationFiles(f.page.projection, () => null);
		const controller = createManagedController(
			f.page,
			{ setTheme() {}, showRoster() {}, aboutConversation() {} },
			session,
			files,
			f.route,
			{ refresh: () => Promise.resolve() } as unknown as ManagedHistory,
		);
		try {
			const refusal = await controller.stewardRoom(room.key);
			assertEquals(refusal === "", !replaced);
			assertEquals(completed, replaced ? 0 : 1);
			assertEquals(attempts, replaced ? 1 : 2);
		} finally {
			files.close();
			await session.close();
			f.close();
		}
	});
}
