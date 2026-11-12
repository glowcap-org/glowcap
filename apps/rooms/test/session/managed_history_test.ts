// History feedback and late replies follow the exact managed conversation.
/// <reference lib="dom" />
import "../support/match_media.ts";
import { failureView, LocalRefusal } from "../../lib/text/failure.ts";
import { assert, assertEquals } from "../assert.ts";
import { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";
import type { RoomsManagedApplication, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
const { ManagedHistory } = await import("../../web/ui/session/managed/history.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/directory.ts");
type ArchivePage = {
	next: string;
	more: boolean;
	records: { record: import("../../lib/archive/protocol.ts").ArchiveRecord }[];
};
const empty: ArchivePage = { next: "0", more: false, records: [] };
const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
function deferred<T>() {
	let resolve!: (value: T) => void;
	let reject!: (error: unknown) => void;
	const promise = new Promise<T>((done, fail) => {
		resolve = done;
		reject = fail;
	});
	return { promise, resolve, reject };
}
function fixture(read: (filter: { conversation: string }) => Promise<ArchivePage>) {
	const page = new RoomsPage();
	const current: WorkspaceSnapshot = {
		revision: "1",
		intent: {
			version: 1,
			directories: [],
			conversations: [],
			invitations: [],
			active: null,
			standing: "",
			ignored: [],
			keepHistory: true,
			connection: "relay",
			archive: null,
			archiveControl: null,
			operators: [],
			peering: [],
		},
		addresses: [],
	};
	const failures: unknown[] = [];
	const admissions: string[] = [];
	let freed = 0;
	function reader(kind: string) {
		admissions.push(kind);
		return Promise.resolve({
			read: (filter: string) => read(JSON.parse(filter)),
			readTogether: (_device: unknown, filter: string) => read(JSON.parse(filter)),
			free: () => {
				freed++;
			},
		});
	}
	const held = {
		snapshot: () => Promise.resolve(current),
		free() {},
		deviceHistory: () => reader("device"),
		selectedArchive: () => reader("peer"),
	} as unknown as RoomsManagedWorkspace;
	const session = new ManagedRoomsSession(
		{ close: () => Promise.resolve(), free() {} } as unknown as RoomsManagedApplication,
		held,
		held,
		() => {},
	);
	session.permits = () => true;
	const history = new ManagedHistory(page, session, (_source, error) => failures.push(error));
	store.openDir(page.projection, dirId("directory"), "");
	function add(id: string, name = id) {
		current.intent.conversations.push({
			kind: "room",
			id,
			directory: "directory",
			name,
			access: null,
			control: null,
			reconnect: "manual",
			standing: null,
			draft: "",
		});
		return store.ensureRoom(page.projection, dirId("directory"), name, { persistId: id, key: `room:${id}` });
	}
	function phase(id: string) {
		const row = store.convByPersistId(page.projection, id);
		return row?.type === "room" ? row.earlierHistory : null;
	}
	async function close() {
		await history.close();
		await session.close();
		for (const key of [...page.projection.get().convs.keys()]) store.forgetConv(page.projection, key);
	}
	return { page, current, session, history, failures, admissions, add, phase, close, freed: () => freed };
}

for (const allowed of [[], ["history"], ["readArchive"], ["history", "readArchive"]]) {
	Deno.test(`managed selected archive respects independent reader permissions: ${allowed.join(",")}`, async () => {
		const f = fixture(() => Promise.resolve(empty));
		f.current.intent.archive = "selected-peer";
		f.session.permits = (permission) => allowed.includes(permission);
		f.add("room");
		await f.session.refresh();
		try {
			await f.history.refresh();
			assertEquals(
				f.admissions,
				allowed.includes("readArchive")
					? allowed.includes("history") ? ["peer", "device"] : ["peer"]
					: allowed.includes("history")
					? ["device"]
					: [],
			);
			const target = f.page.projection.get().archiveTarget;
			assertEquals(
				target.kind === "peer" ? target.status : null,
				allowed.includes("readArchive") ? "connected" : "denied",
			);
			assertEquals(f.phase("room"), allowed.length === 0 ? "unasked" : "empty");
			assertEquals(f.failures, []);
		} finally {
			await f.close();
		}
	});
}

Deno.test("managed empty peer archive settles without a conversation to hydrate", async () => {
	const f = fixture(() => Promise.resolve(empty));
	f.current.intent.archive = "selected-peer";
	await f.session.refresh();
	try {
		await f.history.refresh();
		const target = f.page.projection.get().archiveTarget;
		assertEquals(target.kind === "peer" ? target.status : null, "connected");
	} finally {
		await f.close();
	}
});

Deno.test("a stale archive read cannot report the replacement connected", async () => {
	const old = deferred<ArchivePage>();
	const replacement = deferred<ArchivePage>();
	let reads = 0;
	const f = await fixture(() => ++reads === 1 ? old.promise : replacement.promise);
	f.current.intent.archive = "old";
	f.add("room");
	await f.session.refresh();
	f.history.start();
	await tick();
	const statuses: string[] = [];
	const stop = f.page.projection.subscribe(() => {
		const target = f.page.projection.get().archiveTarget;
		if (target.kind === "peer") statuses.push(target.status);
	});
	try {
		f.current.intent.archive = "replacement";
		await f.session.refresh();
		old.resolve(empty);
		await tick();
		assertEquals(reads, 2);
		assertEquals(statuses.includes("connected"), false);
		replacement.resolve(empty);
		await f.history.refresh();
		assertEquals(statuses.at(-1), "connected");
	} finally {
		stop();
		replacement.resolve(empty);
		await f.close();
	}
});

Deno.test("managed history reports loading and refusal per conversation, continues siblings and retries", async () => {
	const blocked = deferred<ArchivePage>();
	let calls = 0;
	let fail = true;
	const f = await fixture((filter) => {
		if (filter.conversation !== "failed") return Promise.resolve(empty);
		calls++;
		return fail ? blocked.promise : Promise.resolve(empty);
	});
	f.add("failed");
	f.add("empty");
	await f.session.refresh();
	f.history.start();
	try {
		await tick();
		assertEquals(f.phase("failed"), "loading");
		const original = new Error("original archive refusal");
		blocked.reject(original);
		await tick();
		assertEquals([f.phase("failed"), f.phase("empty")], ["unavailable", "empty"]);
		assertEquals(f.failures.length, 1);
		const reported = f.failures[0];
		assertEquals(failureView(reported).code, "local-history-unavailable");
		assert(failureView(reported).summary.includes("Message history"), "history failure names its recovery surface");
		assert(
			failureView(reported).detail.includes("original archive refusal"),
			"history failure keeps the original diagnostic",
		);
		assert(
			reported instanceof LocalRefusal && Array.isArray(reported.cause) && reported.cause[0] === original,
			"history failure keeps the original errors",
		);
		// Session refresh republishes the same snapshot, not a history retry.
		await f.session.refresh();
		await tick();
		assertEquals(calls, 1, "an unchanged snapshot must not retry a refused history read");
		assertEquals(f.failures.length, 1, "an unchanged snapshot must not repeat the failure report");
		fail = false;
		// History refresh is the explicit read requested from Settings.
		await f.history.refresh();
		assertEquals([f.phase("failed"), calls], ["empty", 2]);
	} finally {
		await f.close();
	}
	assertEquals(f.freed(), 1);
});

for (const outcome of ["success", "refusal"] as const) {
	Deno.test(`managed late history ${outcome} cannot enter a replacement under the same store key`, async () => {
		const blocked = deferred<ArchivePage>();
		let calls = 0;
		const f = await fixture(() => ++calls === 1 ? blocked.promise : Promise.resolve(empty));
		const old = f.add("reused", "old room");
		await f.session.refresh();
		f.history.start();
		try {
			await tick();
			assertEquals(calls, 1);
			const row = f.current.intent.conversations[0];
			if (row.kind !== "room") throw new Error("room fixture");
			row.name = "replacement room";
			store.forgetConv(f.page.projection, old.key);
			store.ensureRoom(f.page.projection, dirId("directory"), row.name, { persistId: row.id, key: old.key });
			await f.session.refresh();
			if (outcome === "refusal") blocked.reject(new Error("old target refused"));
			else {blocked.resolve({
					...empty,
					records: [{
						record: {
							kind: "line",
							source: "source",
							generation: "generation",
							id: "old",
							conversationKind: "room",
							directory: "directory",
							conversation: row.id,
							from: "bo",
							text: "old target",
							mine: false,
							at: 1,
							order: 1,
							state: "present",
							previewUrls: [],
							attachments: [],
						},
					}],
				});}
			await tick();
			assertEquals(calls, 2);
			assertEquals(f.phase("reused"), "empty");
			assertEquals(store.historyOf(f.page.projection, old.key).filter((item) => item.kind === "chat"), []);
			assertEquals(f.failures, []);
		} finally {
			await f.close();
		}
	});
}

Deno.test("managed history refuses an empty continuation and leaves explicit retry available", async () => {
	let malformed = true;
	const f = await fixture(() => Promise.resolve(malformed ? { next: "0", more: true, records: [] } : empty));
	f.add("cursor");
	await f.session.refresh();
	f.history.start();
	try {
		await tick();
		assertEquals(f.phase("cursor"), "unavailable");
		const failure = f.failures[0];
		assert(failure instanceof LocalRefusal && Array.isArray(failure.cause), "own archive retains its failure");
		assertEquals(failureView(failure.cause[0]).code, "local-archive-invalid");
		assert(
			failureView(failure).detail.includes("empty continuation page"),
			"aggregate keeps the actual empty continuation diagnostic",
		);
		assertEquals(f.failures.length, 1);
		malformed = false;
		await f.history.refresh();
		assertEquals(f.phase("cursor"), "empty");
	} finally {
		await f.close();
	}
});

Deno.test("managed archive status belongs to the session and requires a successful read", async () => {
	const blocked = deferred<ArchivePage>();
	let first = true;
	const f = fixture(() => first ? blocked.promise : Promise.resolve(empty));
	f.add("room");
	f.current.intent.archive = "selected-peer";
	await f.session.refresh();
	f.history.start();
	const target = () => f.page.projection.get().archiveTarget;
	const status = () => {
		const view = target();
		return view.kind === "peer" ? view.status : null;
	};
	try {
		await tick();
		assertEquals(target(), {
			kind: "peer",
			status: "connecting",
			label: "Archive peer",
			error: "",
		});
		blocked.reject(new Error("archive refused the read"));
		await tick();
		assertEquals(status(), "unavailable");
		first = false;
		await f.history.refresh();
		assertEquals(status(), "connected");
		f.current.intent.archive = null;
		await f.session.refresh();
		await f.history.refresh();
		assertEquals(target(), { kind: "owned", status: "connected", error: "" });
	} finally {
		await f.close();
	}
});

Deno.test("archive shutdown fences late reads and ignores replaced or unpermitted selection", async () => {
	const old = deferred<ArchivePage>();
	const next = deferred<ArchivePage>();
	let reads = 0;
	const f = fixture(() => ++reads === 1 ? old.promise : next.promise);
	f.add("room");
	f.current.intent.archive = "selected-peer";
	await f.session.refresh();
	f.history.start();
	const status = () => {
		const target = f.page.projection.get().archiveTarget;
		return target.kind === "peer" ? target.status : null;
	};
	try {
		await tick();
		f.history.unavailable("replaced-peer");
		assertEquals(status(), "connecting");
		f.session.permits = (permission) => permission !== "readArchive";
		f.history.unavailable("selected-peer");
		assertEquals(status(), "connecting");
		f.session.permits = () => true;
		f.history.unavailable("selected-peer");
		f.history.unavailable("selected-peer");
		assertEquals(status(), "unavailable");
		assertEquals(f.page.projection.get().toasts.length, 1);
		old.resolve(empty);
		await tick();
		assertEquals(status(), "unavailable", "a read begun before shutdown cannot restore connected status");
		next.resolve(empty);
		await f.history.refresh();
		assertEquals(status(), "connected", "only a fresh successful read restores availability");
	} finally {
		old.resolve(empty);
		next.resolve(empty);
		await f.close();
	}
});

import { snapshot, viewer } from "../support/managed_viewer.ts";
Deno.test("managed history hydrates only changed exact conversations and archive selections", async () => {
	const { initializeApplication } = await import("../support/application.ts");
	await initializeApplication();
	const [{ ManagedHistory }, { RoomsPage }, store, { dirId }] = await Promise.all([
		import("../../web/ui/session/managed/history.ts"),
		import("../../web/ui/page.ts"),
		import("../../web/ui/store.ts"),
		import("../../web/ui/directory.ts"),
	]);
	const accepted = snapshot();
	const page = new RoomsPage();
	const reads: { archive: string | null; conversation: string }[] = [];
	let freed = 0;
	const failures: unknown[] = [];
	function reader(device: boolean) {
		const archive = device ? null : accepted.intent.archive;
		const read = (raw: string) => {
			const filter = JSON.parse(raw);
			assertEquals(filter.directory, "directory");
			assertEquals(filter.conversationKind, "room");
			reads.push({ archive, conversation: filter.conversation });
			return Promise.resolve({ next: "0", more: false, records: [] });
		};
		return Promise.resolve({
			read,
			readTogether: (_device: unknown, raw: string) => read(raw),
			free() {
				freed++;
			},
		});
	}
	const session = viewer({
		snapshot: () => Promise.resolve(accepted),
		selectedArchive: () => reader(false),
		deviceHistory: () => reader(true),
	});
	session.permits = () => true;
	const history = new ManagedHistory(page, session, (_source, error) => failures.push(error));
	const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
	function add(id: string) {
		accepted.intent.conversations.push({
			kind: "room",
			id,
			directory: "directory",
			name: id,
			access: null,
			control: null,
			reconnect: "manual",
			standing: null,
			draft: "",
		});
		store.ensureRoom(page.projection, dirId("directory"), id, { persistId: id, key: id });
	}
	store.openDir(page.projection, dirId("directory"), "");
	add("first");
	await session.refresh();
	history.start();
	try {
		await tick();
		assertEquals(reads, [{ archive: null, conversation: "first" }]);
		accepted.intent.conversations[0].draft = "new draft";
		await session.refresh();
		await tick();
		assertEquals(reads.length, 1, "draft revisions cannot restart archive hydration");
		add("second");
		await session.refresh();
		await tick();
		assertEquals(reads.map((row) => row.conversation), ["first", "second"]);
		const first = accepted.intent.conversations[0];
		if (first.kind === "room") first.seat = "new-generation";
		await session.refresh();
		await tick();
		assertEquals(reads.map((row) => row.conversation), ["first", "second", "first"]);
		accepted.intent.archive = "different-exact-archive";
		await session.refresh();
		await tick();
		assertEquals(reads.slice(3), [{ archive: "different-exact-archive", conversation: "first" }, {
			archive: "different-exact-archive",
			conversation: "second",
		}]);
		assertEquals(freed, 1);
		history.refresh();
		await tick();
		assertEquals(reads.length, 7, "an activity gap explicitly invalidates hydrated conversations");
		assertEquals(failures, []);
	} finally {
		await history.close();
		await session.close();
		for (const key of [...page.projection.get().convs.keys()]) store.forgetConv(page.projection, key);
	}
	assertEquals(freed, 3);
});

Deno.test("history refresh after close refuses with the session action", async () => {
	const f = fixture(() => Promise.resolve(empty));
	await f.close();
	const [result] = await Promise.allSettled([f.history.refresh()]);
	assert(result.status === "rejected", "closed history cannot read");
	assertEquals(failureView(result.reason).code, "local-session-closed");
});

Deno.test("a queued history selection is read after the previous selection fails", async () => {
	const pending = Promise.withResolvers<ArchivePage>();
	const reads: string[] = [];
	let first = true;
	let blocked = true;
	const f = fixture(({ conversation }) => {
		reads.push(conversation);
		if (conversation === "failed" && first) {
			first = false;
			return Promise.reject(new Error("temporary archive failure"));
		}
		if (conversation === "blocked" && blocked) {
			blocked = false;
			return pending.promise;
		}
		return Promise.resolve(empty);
	});
	f.add("failed");
	f.add("blocked");
	await f.session.refresh();
	f.history.start();
	try {
		await tick();
		assertEquals(reads, ["failed", "blocked"]);
		const changed = f.current.intent.conversations[1];
		assert(changed.kind === "room", "the delayed conversation is a room");
		changed.name = "changed selection";
		f.add("queued");
		await f.session.refresh();
		pending.resolve(empty);
		await tick();
		assert(reads.includes("queued"), "a failed older read must drain the queued selection");
		assertEquals(f.phase("queued"), "empty");
		assertEquals(f.failures.length, 1, "the older failure remains reported");
		const count = reads.length;
		await f.session.refresh();
		await tick();
		assertEquals(reads.length, count, "unchanged snapshots still cannot restart a read");
	} finally {
		pending.resolve(empty);
		await f.close();
	}
});

Deno.test("Settings keeps saved-history retry available when recording is off", async () => {
	const { createElement: h } = await import("react");
	const { renderToStaticMarkup } = await import("react-dom/server");
	const { fixture: controllerFixture } = await import("../support/managed_controller.ts");
	const { RoomsSessionProvider } = await import("../../web/ui/controller/session.ts");
	const { HistorySettings } = await import("../../web/ui/settings/History.tsx");
	const { RoomsBrowserProvider } = await import("../../web/ui/controller/browser.ts");
	const { createRoomsBrowserController } = await import("../../web/ui/controller/create_browser.ts");
	const { ModalProvider } = await import("../../web/ui/modal.ts");
	const f = controllerFixture();
	const session = f.page.managedSession;
	assert(session != null, "the fixture has a managed session");
	const browser = createRoomsBrowserController(
		f.page,
		() => {},
		() => "/",
		() => Promise.resolve({ session, local: true }),
	);
	try {
		const html = renderToStaticMarkup(h(
			RoomsBrowserProvider,
			{ value: browser },
			h(
				ModalProvider,
				null,
				h(
					RoomsSessionProvider,
					{ value: f.controller },
					h(HistorySettings, {
						canRead: true,
						canConfigure: false,
						keepHistory: false,
						archiveTarget: { kind: "owned", status: "unavailable", error: "failed" },
					}),
				),
			),
		));
		assert(!html.includes("keepHistoryToggle"), "read access cannot change recording policy");
		const button = html.match(/<button[^>]*id="historyReadAgain"[^>]*>/)?.[0];
		assert(button != null, "saved history has an explicit retry control");
		assert(!button.includes("disabled"), "reading saved history must not require recording new messages");
	} finally {
		f.close();
	}
});

for (let turns = 0; turns < 7; turns++) {
	Deno.test(`history drains refresh at completion microtask ${turns}`, async () => {
		const pending = Promise.withResolvers<ArchivePage>();
		let reads = 0;
		const f = fixture(() => ++reads === 1 ? pending.promise : Promise.resolve(empty));
		f.add("room");
		await f.session.refresh();
		try {
			const first = f.history.refresh();
			await tick();
			assertEquals(reads, 1);
			pending.resolve(empty);
			for (let turn = 0; turn < turns; turn++) await Promise.resolve();
			const retry = f.history.refresh();
			await Promise.all([first, retry]);
			assertEquals(reads, 2, "every explicit retry must settle after its read");
		} finally {
			pending.resolve(empty);
			await f.close();
		}
	});
}

for (const failedBeforeRemoval of [false, true]) {
	Deno.test(`empty owned history settles after failure=${failedBeforeRemoval}`, async () => {
		const f = fixture(() => Promise.reject(new Error("read failed")));
		if (failedBeforeRemoval) f.add("removed");
		await f.session.refresh();
		try {
			if (failedBeforeRemoval) {
				await Promise.allSettled([f.history.refresh()]);
				assertEquals(f.page.projection.get().archiveTarget.status, "unavailable");
				f.current.intent.conversations = [];
				await f.session.refresh();
			}
			await f.history.refresh();
			assertEquals(f.page.projection.get().archiveTarget, { kind: "owned", status: "connected", error: "" });
		} finally {
			await f.close();
		}
	});
}
