// History feedback and late replies follow the exact managed conversation.
/// <reference lib="dom" />
import { assertEquals } from "../assert.ts";
import { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";
import type { RoomsManagedApplication, RoomsManagedWorkspace } from "../../../../zig-out/wasm/rooms/rooms_browser.js";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { ManagedHistory } = await import("../../web/ui/session/managed/history.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/types.ts");
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
				allowed.includes("readArchive") ? "connected" : "unavailable",
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
		blocked.reject(new Error("original archive refusal"));
		await tick();
		assertEquals([f.phase("failed"), f.phase("empty")], ["unavailable", "empty"]);
		assertEquals(f.failures.length, 1);
		fail = false;
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

Deno.test("managed history refuses a nonadvancing cursor and leaves explicit retry available", async () => {
	let malformed = true;
	const f = await fixture(() => Promise.resolve(malformed ? { next: "0", more: true, records: [] } : empty));
	f.add("cursor");
	await f.session.refresh();
	f.history.start();
	try {
		await tick();
		assertEquals(f.phase("cursor"), "unavailable");
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
		assertEquals(target(), { kind: "owned" });
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
	Object.defineProperty(globalThis, "matchMedia", {
		configurable: true,
		value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
	});
	const [{ ManagedHistory }, { RoomsPage }, store, { dirId }] = await Promise.all([
		import("../../web/ui/session/managed/history.ts"),
		import("../../web/ui/page.ts"),
		import("../../web/ui/store.ts"),
		import("../../web/ui/types.ts"),
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
