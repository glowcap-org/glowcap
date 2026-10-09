// Awaited archive replies retain the selected offer and receiving conversation.
/// <reference lib="dom" />
import { assert, assertEquals } from "../assert.ts";
import { initializeApplication } from "../support/application.ts";
import type { ArchiveLine } from "../../lib/archive/protocol.ts";
import type { ManagedRoomsSession } from "../../web/ui/session/managed/session.ts";
import type { ReceivedArchive, WorkspaceSnapshot } from "../../web/ui/session/managed/model.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { managedArchiveReading } = await import("../../web/ui/session/managed/archive_shares.ts");
const { presentationFiles } = await import("../../web/ui/session/managed/files.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/types.ts");
await initializeApplication();
type ArchivePage = { next: string; more: boolean; records: { record: ArchiveLine }[] };
function deferred<T>() {
	let resolve!: (value: T) => void;
	const promise = new Promise<T>((done) => resolve = done);
	return { promise, resolve };
}
function fixture(read: () => Promise<ArchivePage>) {
	const page = new RoomsPage();
	const dir = dirId("directory");
	store.openDir(page.projection, dir, "");
	const receiving = store.restoreDm(page.projection, dir, "bo", "registration", "dm", false)!;
	const offer: ReceivedArchive = {
		id: "offer",
		channel: "dm",
		directory: "directory",
		kind: "room",
		conversation: "garden",
		from: "bo",
		access: "exact",
		source: "origin",
		durable: false,
	};
	const current: WorkspaceSnapshot = {
		revision: "1",
		intent: {
			version: 1,
			directories: [],
			conversations: [{
				kind: "direct",
				id: "dm",
				directory: "directory",
				peer: "bo",
				access: "direct",
				closed: false,
				draft: "",
			}],
			invitations: [],
			archiveShares: [offer],
			active: "dm",
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
	let freed = 0;
	let dropFailure = false;
	let candidate: (() => void) | null = null;
	const opened: string[] = [];
	const shares: unknown[][] = [];
	const files = presentationFiles(page.projection, () => null);
	const session = {
		current,
		permits: () => true,
		workspace: {
			archiveReader: () =>
				Promise.resolve({
					read,
					free() {
						freed++;
					},
					openAttachment: (record: string) => {
						opened.push(record);
						return Promise.resolve(new Uint8Array([7]));
					},
				}),
		},
		candidate: () => {
			candidate?.();
			return Promise.resolve(structuredClone(current));
		},
		actions: {
			replace: (next: WorkspaceSnapshot) => {
				if (dropFailure) return Promise.reject(new Error("dismissal not committed"));
				current.intent = next.intent;
				return Promise.resolve();
			},
			direct: (...args: unknown[]) => {
				shares.push(args);
				return Promise.resolve("recipient");
			},
			run: (...args: unknown[]) => {
				shares.push(args);
				return Promise.resolve();
			},
		},
	} as unknown as ManagedRoomsSession;
	const reading = managedArchiveReading(page, session, files);
	const line: ArchiveLine = {
		kind: "line",
		source: "account",
		generation: "generation",
		id: "line",
		conversationKind: "room",
		directory: "directory",
		conversation: "garden",
		from: "ada",
		text: "shared history",
		mine: false,
		at: 1,
		order: 1,
		state: "present",
		previewUrls: [],
		attachments: [],
	};
	return {
		page,
		current,
		offer,
		receiving,
		reading,
		line,
		shares,
		files,
		opened,
		freed: () => freed,
		dropFailure: () => dropFailure = true,
		onCandidate: (callback: () => void) => candidate = callback,
		close: () => {
			files.close();
			for (const key of [...page.projection.get().convs.keys()]) store.forgetConv(page.projection, key);
		},
	};
}
for (const changed of ["from", "directory", "kind", "conversation", "channel", "access", "source"] as const) {
	Deno.test(`managed archive refuses a late reply after offer ${changed} changes`, async () => {
		const late = deferred<ArchivePage>();
		const f = fixture(() => late.promise);
		try {
			const task = f.reading.readArchiveShare("offer");
			await Promise.resolve();
			f.current.intent.archiveShares = [{ ...f.offer, [changed]: changed === "kind" ? "direct" : "replacement" }];
			late.resolve({ next: "1", more: false, records: [{ record: f.line }] });
			assert((await task).includes("changed"), "late archive selection must refuse");
			assertEquals(store.historyOf(f.page.projection, f.receiving.key), []);
			assertEquals(f.current.intent.archiveShares.length, 1);
			assertEquals(f.freed(), 1);
		} finally {
			f.close();
		}
	});
}
Deno.test("managed archive keeps reconciled history when dismissal refuses and cannot dismiss a reused offer", async () => {
	const f = fixture(() => Promise.resolve({ next: "1", more: false, records: [{ record: f.line }] }));
	try {
		f.dropFailure();
		assert(
			(await f.reading.readArchiveShare("offer")).includes("dismissal not committed"),
			"dismissal needs recovery",
		);
		assertEquals(
			store.historyOf(f.page.projection, f.receiving.key).filter((row) => row.kind === "chat").map((row) =>
				row.text
			),
			["shared history"],
		);
		f.onCandidate(() => f.current.intent.archiveShares = [{ ...f.offer, from: "replacement" }]);
		assert(
			(await f.reading.readArchiveShare("offer")).includes("changed before dismissal"),
			"replacement must survive",
		);
		assertEquals(f.current.intent.archiveShares?.[0].from, "replacement");
		assertEquals(f.freed(), 2);
	} finally {
		f.close();
	}
});
Deno.test("managed archive refuses a reply for replaced receiving authority", async () => {
	const late = deferred<ArchivePage>();
	const f = fixture(() => late.promise);
	try {
		const task = f.reading.readArchiveShare("offer");
		await Promise.resolve();
		const receiving = f.current.intent.conversations[0];
		if (receiving.kind !== "direct") throw new Error("direct fixture");
		receiving.access = "replacement";
		late.resolve({ next: "1", more: false, records: [{ record: f.line }] });
		assert((await task).includes("changed"), "replaced receiving authority must refuse the delayed reply");
		assertEquals(store.historyOf(f.page.projection, f.receiving.key), []);
		assertEquals(f.current.intent.archiveShares?.length, 1);
		assertEquals(f.freed(), 1);
	} finally {
		f.close();
	}
});
Deno.test("managed archive file retains its exact reader after offer dismissal and selection change", async () => {
	const f = fixture(() => Promise.resolve({ next: "1", more: false, records: [{ record }] }));
	const record: ArchiveLine = {
		...f.line,
		attachments: [{ name: "file.txt", mime: "text/plain", size: 1, width: 0, height: 0, blob: "a".repeat(64) }],
	};
	try {
		assertEquals(await f.reading.readArchiveShare("offer"), "");
		assertEquals(f.current.intent.archiveShares, []);
		assertEquals(f.freed(), 0);
		f.current.intent.archive = "another-archive";
		const line = store.historyOf(f.page.projection, f.receiving.key).find((row) => row.kind === "chat");
		if (line?.kind !== "chat" || line.attachments?.[0] == null) throw new Error("archived file view");
		f.files.open(f.receiving.key, line.attachments[0].id);
		await new Promise((resolve) => setTimeout(resolve, 0));
		assertEquals(f.opened, [JSON.stringify(record)]);
		assertEquals(f.freed(), 1);
		f.files.close();
		assertEquals(f.freed(), 1);
	} finally {
		f.close();
	}
});
Deno.test("managed archive refuses empty continuation without another read", async () => {
	let calls = 0;
	const f = fixture(() => {
		calls++;
		return Promise.resolve({ next: String(calls), more: true, records: [] });
	});
	try {
		assert(
			(await f.reading.readArchiveShare("offer")).includes("empty continuation"),
			"bounded empty continuation refusal",
		);
		assertEquals(calls, 1);
	} finally {
		f.close();
	}
});
Deno.test("managed room history opens a direct recipient without moving selection", async () => {
	const f = fixture(() => Promise.resolve({ next: "0", more: false, records: [] }));
	try {
		const room = store.ensureRoom(f.page.projection, dirId("directory"), "garden", { persistId: "room" });
		f.current.intent.conversations.push({
			kind: "room",
			id: "room",
			directory: "directory",
			name: "garden",
			access: "exact-room",
			control: null,
			reconnect: "requested",
			standing: null,
			draft: "",
		});
		f.page.projection.set({ activeKey: room.key });
		assertEquals(await f.reading.shareArchiveHistory(room.key, "bo"), "");
		assertEquals(f.shares[0], [dirId("directory"), "bo", false]);
		assertEquals(f.page.projection.get().activeKey, room.key);
	} finally {
		f.close();
	}
});

Deno.test("managed room history refuses changed source authority after recipient acquisition", async () => {
	const f = fixture(() => Promise.resolve({ next: "0", more: false, records: [] }));
	try {
		const room = store.ensureRoom(f.page.projection, dirId("directory"), "garden", { persistId: "room" });
		const source = {
			kind: "room" as const,
			id: "room",
			directory: "directory",
			name: "garden",
			access: "exact-room",
			control: null,
			reconnect: "requested" as const,
			standing: null,
			draft: "",
		};
		f.current.intent.conversations.push(source);
		const sharing = f.reading.shareArchiveHistory(room.key, "bo");
		source.access = "replacement-room";
		assert((await sharing).includes("changed"), "the original source must survive recipient acquisition");
		assertEquals(f.shares, [[dirId("directory"), "bo", false]]);
	} finally {
		f.close();
	}
});
