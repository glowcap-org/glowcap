/// <reference lib="dom" />
// The browser history seam changes archive custody without moving an in-flight
// write, closing a target under an active read, or silently falling back when a
// remembered peer is unavailable. No DOM or network is needed for these
// lifecycle invariants.

import type { ArchiveLine, ArchiveRecord } from "../lib/archive.ts";
import {
	activateHistoryArchiveTarget,
	type HistoryArchiveTarget,
	type HistoryCoordinates,
	holdHistoryArchiveTarget,
	readHistoryLines,
	recordHistoryLine,
	setHistoryTroubleReporter,
	settleHistoryWrites,
	unavailableHistoryArchiveTarget,
	useDeviceHistoryArchive,
} from "../web/ui/history.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";

Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: { getItem: () => null, setItem() {}, removeItem() {} },
});
Object.defineProperty(globalThis, "location", { configurable: true, value: { reload() {} } });
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const store = await import("../web/ui/store.ts");
const { closeArchiveGeneration, hydrateConversation } = await import("../web/ui/net/history.ts");
const { dirId } = await import("../web/ui/types.ts");

function archived(id: string, text = id): ArchiveLine {
	return {
		kind: "line",
		source: "browser-source",
		generation: "browser-generation",
		id,
		conversationKind: "direct",
		directory: "directory-id",
		conversation: "alice",
		from: "alice",
		text,
		mine: false,
		at: 1,
		state: "present",
		attachments: [],
	};
}

const coordinates: HistoryCoordinates = {
	generation: "browser-generation",
	id: "written",
	directory: "directory-id",
	conversation: "alice",
};

class FakeTarget implements HistoryArchiveTarget {
	readonly kind = "peer" as const;
	readonly keeper: string;
	readonly records: ArchiveLine[] = [];
	readRecords: ArchiveRecord[] = [];
	attachmentReads = 0;
	retired = false;
	putStarted: Promise<void>;
	#notePut!: () => void;
	#putGate: Promise<void> = Promise.resolve();

	constructor(keeper: string) {
		this.keeper = keeper;
		this.putStarted = new Promise((resolve) => this.#notePut = resolve);
	}

	holdPut(): () => void {
		let release!: () => void;
		this.#putGate = new Promise((resolve) => release = resolve);
		return release;
	}

	async put(record: ArchiveLine): Promise<void> {
		this.records.push(record);
		this.#notePut();
		await this.#putGate;
	}

	attachment(): Promise<Uint8Array> {
		this.attachmentReads += 1;
		if (this.retired) return Promise.reject(new Error(`${this.keeper} was retired`));
		return Promise.resolve(new TextEncoder().encode(this.keeper));
	}

	read(_kind: "room" | "direct", _directory: string, _conversation: string): Promise<ArchiveRecord[]> {
		return Promise.resolve(this.readRecords);
	}

	retire(): Promise<void> {
		this.retired = true;
		return Promise.resolve();
	}
}

class RefusingTarget extends FakeTarget {
	override put(): Promise<void> {
		return Promise.reject(new Error("archive write refused"));
	}

	override read(): Promise<ArchiveRecord[]> {
		return Promise.reject(new Error("archive read refused"));
	}
}

class DelayedReadTarget extends FakeTarget {
	readonly readStarted: Promise<void>;
	#noteRead!: () => void;
	#finishRead!: () => void;
	readonly #readGate: Promise<void>;

	constructor(keeper: string) {
		super(keeper);
		this.readStarted = new Promise((resolve) => this.#noteRead = resolve);
		this.#readGate = new Promise((resolve) => this.#finishRead = resolve);
	}

	finishRead(): void {
		this.#finishRead();
	}

	override async read(): Promise<ArchiveRecord[]> {
		this.#noteRead();
		await this.#readGate;
		return this.readRecords;
	}
}

class FilteringTarget extends FakeTarget {
	readonly conversations: string[] = [];

	override read(kind: "room" | "direct", directory: string, conversation: string): Promise<ArchiveRecord[]> {
		this.conversations.push(conversation);
		return Promise.resolve(this.readRecords.filter((record) =>
			record.kind !== "line" ||
			(record.conversationKind === kind && record.directory === directory && record.conversation === conversation)
		));
	}
}

Deno.test("archive target swap drains the write already assigned to its old peer", async () => {
	const old = new FakeTarget("old archive");
	const release = old.holdPut();
	const next = new FakeTarget("new archive");
	await activateHistoryArchiveTarget(old);
	recordHistoryLine(coordinates, { from: "alice", text: "in flight", mine: false, at: 1, attachments: [] });
	await old.putStarted;
	let swapped = false;
	const swapping = activateHistoryArchiveTarget(next).then(() => swapped = true);
	await Promise.resolve();
	assertEquals(swapped, false, "the old target retired while its write was active");
	release();
	await swapping;
	assertEquals(old.records.map((record) => record.text), ["in flight"]);
	assertEquals(old.retired, true);
	assertEquals(next.records.length, 0);
	await useDeviceHistoryArchive();
});

Deno.test("a write admitted during target retirement belongs to the new target", async () => {
	const old = new FakeTarget("old archive");
	const release = old.holdPut();
	const next = new FakeTarget("new archive");
	await activateHistoryArchiveTarget(old);
	recordHistoryLine(coordinates, { from: "alice", text: "old write", mine: false, at: 1, attachments: [] });
	await old.putStarted;
	const swapping = activateHistoryArchiveTarget(next);
	recordHistoryLine(
		{ ...coordinates, id: "new-write" },
		{ from: "alice", text: "new write", mine: false, at: 2, attachments: [] },
	);
	release();
	await swapping;
	await settleHistoryWrites();
	assertEquals(old.records.map((record) => record.text), ["old write"]);
	assertEquals(next.records.map((record) => record.text), ["new write"]);
	await useDeviceHistoryArchive();
});

Deno.test("prepared passable authority defers old-target retirement without blocking selection", async () => {
	const old = new FakeTarget("old archive");
	const next = new FakeTarget("new archive");
	await activateHistoryArchiveTarget(old);
	const prepared = holdHistoryArchiveTarget();
	assertEquals(prepared.target, old);
	await activateHistoryArchiveTarget(next);
	assertEquals(old.retired, false, "the old target retired before its prepared authority was handed or abandoned");
	prepared.release();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(old.retired, true);
	await useDeviceHistoryArchive();
});

Deno.test("archive reads retain the selected peer as their visible keeper", async () => {
	const peer = new FakeTarget("iroh peer abcdef");
	peer.readRecords = [archived("remembered", "from peer")];
	await activateHistoryArchiveTarget(peer);
	const groups = await readHistoryLines("directory-id", "alice");
	assertEquals(groups.map((group) => [group.keeper, group.lines.map((line) => line.text)]), [
		["iroh peer abcdef", ["from peer"]],
	]);
	for (const group of groups) group.release();
	await useDeviceHistoryArchive();
});

Deno.test("an archived file remains bound to the archive that supplied its record", async () => {
	const old = new FakeTarget("old archive");
	const next = new FakeTarget("new archive");
	old.readRecords = [{
		...archived("file", "from old"),
		attachments: [{
			name: "old.txt",
			mime: "text/plain",
			size: 11,
			width: 0,
			height: 0,
			blob: "00".repeat(32),
		}],
	}];
	await activateHistoryArchiveTarget(old);
	const groups = await readHistoryLines("directory-id", "alice");
	await activateHistoryArchiveTarget(next);
	assertEquals(old.retired, false);
	const record = groups[0]?.lines[0]?.archive;
	if (record == null) throw new Error("archive target test did not return its record");
	assertEquals(new TextDecoder().decode(await groups[0].readAttachment(record, 0)), "old archive");
	assertEquals(old.attachmentReads, 1);
	assertEquals(next.attachmentReads, 0);
	for (const group of groups) group.release();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(old.retired, true);
	await useDeviceHistoryArchive();
});

Deno.test("a target switch during an archive read transfers its lease to the returned generation", async () => {
	const old = new DelayedReadTarget("delayed old archive");
	const next = new FakeTarget("new archive");
	old.readRecords = [{
		...archived("delayed-file", "from delayed old"),
		attachments: [{
			name: "old.txt",
			mime: "text/plain",
			size: 19,
			width: 0,
			height: 0,
			blob: "00".repeat(32),
		}],
	}];
	await activateHistoryArchiveTarget(old);
	const reading = readHistoryLines("directory-id", "alice");
	await old.readStarted;
	await activateHistoryArchiveTarget(next);
	assertEquals(old.retired, false);
	old.finishRead();
	const groups = await reading;
	const record = groups[0]?.lines[0]?.archive;
	if (record == null) throw new Error("the delayed archive read returned no record");
	assertEquals(new TextDecoder().decode(await groups[0].readAttachment(record, 0)), "delayed old archive");
	for (const group of groups) group.release();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(old.retired, true);
	await useDeviceHistoryArchive();
});

Deno.test("an unavailable selected peer yields no device-history fallback", async () => {
	await activateHistoryArchiveTarget(unavailableHistoryArchiveTarget("remembered peer"));
	assertEquals(await readHistoryLines("directory-id", "alice"), []);
	recordHistoryLine(coordinates, {
		from: "alice",
		text: "must not fall back",
		mine: false,
		at: 1,
		attachments: [],
	});
	// Switching waits for the refused queued write, proving it cannot surface
	// later in the device target after reconnect policy changes.
	await useDeviceHistoryArchive();
});

Deno.test("archive write and read failures reach their presentation owners", async () => {
	const target = new RefusingTarget("refusing archive");
	const trouble: { source: string; reason: string }[] = [];
	setHistoryTroubleReporter((source, reason) => trouble.push({ source, reason }));
	await activateHistoryArchiveTarget(target);
	try {
		recordHistoryLine(coordinates, {
			from: "alice",
			text: "not retained",
			mine: false,
			at: 1,
			attachments: [],
		});
		await settleHistoryWrites();
		assertEquals(trouble, [{ source: "message history write", reason: "archive write refused" }]);

		let readFailure = "";
		try {
			await readHistoryLines("directory-id", "alice");
		} catch (error) {
			readFailure = error instanceof Error ? error.message : String(error);
		}
		assertEquals(readFailure, "archive read refused");
	} finally {
		setHistoryTroubleReporter(() => {});
		await useDeviceHistoryArchive();
	}
});

Deno.test("history from a closed conversation cannot hydrate its replacement", async () => {
	const directory = dirId("directory");
	store.set({
		...store.initial,
		dirs: new Map([[
			directory,
			{
				id: directory,
				locator: "127.0.0.1:1",
				liveRooms: new Map(),
				dmablePeers: new Map(),
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
		convs: new Map(),
		drafts: new Map(),
	});
	const first = store.ensureRoom(directory, "general", { persistId: "first-conversation" });
	const target = new DelayedReadTarget("delayed archive");
	target.readRecords = [archived("stale", "stale history")];
	await activateHistoryArchiveTarget(target);
	hydrateConversation(first);
	await target.readStarted;
	store.forgetConv(first.key);
	closeArchiveGeneration(first.key);
	const replacement = store.ensureRoom(directory, "general", { persistId: "replacement-conversation" });
	assertEquals(replacement.key, first.key);
	target.finishRead();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.getConv(replacement.key)?.history.some((item) => item.kind === "chat"), false);
	await useDeviceHistoryArchive();
	assertEquals(target.retired, true);
});

Deno.test("a reused nickname cannot hydrate its prior registration's direct history", async () => {
	const directory = dirId("directory-id");
	store.set({
		...store.initial,
		dirs: new Map([[
			directory,
			{
				id: directory,
				locator: "127.0.0.1:1",
				liveRooms: new Map(),
				dmablePeers: new Map(),
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
		convs: new Map(),
		drafts: new Map(),
	});
	const target = new FilteringTarget("filtered archive");
	target.readRecords = [{ ...archived("old", "old holder history"), conversation: "first-direct" }];
	await activateHistoryArchiveTarget(target);
	const first = store.restoreDm(directory, "bo", registrationId(1), "first-direct", false);
	if (first == null) throw new Error("the first direct conversation was not restored");
	hydrateConversation(first);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(
		store.getConv(first.key)?.history.some((item) => item.kind === "chat" && item.text === "old holder history"),
		true,
	);
	store.forgetConv(first.key);
	closeArchiveGeneration(first.key);
	const replacement = store.restoreDm(directory, "bo", registrationId(2), "replacement-direct", false);
	if (replacement == null) throw new Error("the replacement direct conversation was not restored");
	hydrateConversation(replacement);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(target.conversations, ["first-direct", "replacement-direct"]);
	assertEquals(store.getConv(replacement.key)?.history.some((item) => item.kind === "chat"), false);
	await useDeviceHistoryArchive();
});
