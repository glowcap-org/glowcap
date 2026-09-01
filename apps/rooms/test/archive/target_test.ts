/// <reference lib="dom" />
// The browser history seam changes archive custody without moving an in-flight
// write, closing a target under an active read, or silently falling back when a
// remembered peer is unavailable. No DOM or network is needed for these
// lifecycle invariants.

import type { ArchiveLine, ArchiveRecord } from "../../lib/archive/protocol.ts";
import type { ArchivePeerTarget } from "../../web/ui/net/archive_target.ts";
import { Ref, type Session } from "@pancake/runtime";
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
} from "../../web/ui/history.ts";
import { assertEquals } from "../assert.ts";
import { registrationId } from "../support/registration.ts";

Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: { getItem: () => null, setItem() {}, removeItem() {} },
});
Object.defineProperty(globalThis, "location", { configurable: true, value: { reload() {} } });
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { ArchiveTargetController, RemoteHistoryArchive } = await import("../../web/ui/net/archive_target.ts");
const store = await import("../../web/ui/store.ts");
const { closeArchiveGeneration, hydrateConversation } = await import("../../web/ui/net/history.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { dirId } = await import("../../web/ui/types.ts");

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

class FakeTarget implements HistoryArchiveTarget, ArchivePeerTarget {
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

	facet(): Promise<never> {
		return Promise.reject(new Error("this archive-target fixture does not mint facets"));
	}

	issueShare(): Promise<never> {
		return Promise.reject(new Error("this archive cannot mint a durable share"));
	}

	revokeShare(): Promise<boolean> {
		return Promise.resolve(false);
	}

	listShares(): Promise<[]> {
		return Promise.resolve([]);
	}

	watchFailures(): void {}
}

class RefusingTarget extends FakeTarget {
	override put(): Promise<void> {
		return Promise.reject(new Error("archive write refused"));
	}

	override read(): Promise<ArchiveRecord[]> {
		return Promise.reject(new Error("archive read refused"));
	}
}

class RefusingRetirementTarget extends FakeTarget {
	override retire(): Promise<void> {
		this.retired = true;
		return Promise.reject(new Error("retirement refused"));
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

Deno.test("archive peer selections serialize capability, metadata, and retirement", async () => {
	const page = new RoomsPage();
	const first = new FakeTarget("first peer");
	const second = new FakeTarget("second peer");
	const firstGate = Promise.withResolvers<void>();
	const opened: string[] = [];
	const selection = new ArchiveTargetController(page, async (sturdyref) => {
		opened.push(sturdyref);
		if (sturdyref === "first") await firstGate.promise;
		return {
			target: sturdyref === "first" ? first : second,
			label: sturdyref === "first" ? first.keeper : second.keeper,
		};
	});
	const selectingFirst = selection.takeArchivePeer("first");
	const selectingSecond = selection.takeArchivePeer("second");
	await Promise.resolve();
	assertEquals(opened, ["first"]);
	firstGate.resolve();
	assertEquals(await selectingFirst, "");
	assertEquals(await selectingSecond, "");
	assertEquals(opened, ["first", "second"]);
	const selected = holdHistoryArchiveTarget(page);
	assertEquals(selected.target, second);
	selected.release();
	assertEquals(first.retired, true);
	assertEquals(second.retired, false);
	await selection.close();
	assertEquals(second.retired, true);
});

Deno.test("an archive operation refusal does not declare its live peer unavailable", async () => {
	const transportState = {
		sessionOpen: true,
		send: () => Promise.reject(new Error("record refused")),
	};
	const page = new RoomsPage();
	const transport = transportState as unknown as Session;
	const target = new RemoteHistoryArchive(page, transport, Object.create(Ref.prototype) as Ref, "live peer");
	let unavailable = "";
	target.watchFailures((why) => unavailable = why);
	await target.read("direct", "directory", "conversation").catch(() => {});
	assertEquals(unavailable, "");
	transportState.sessionOpen = false;
	await target.read("direct", "directory", "conversation").catch(() => {});
	assertEquals(unavailable, "record refused");
});

Deno.test("archive target swap drains the write already assigned to its old peer", async () => {
	const page = new RoomsPage();
	const old = new FakeTarget("old archive");
	const release = old.holdPut();
	const next = new FakeTarget("new archive");
	await activateHistoryArchiveTarget(page, old);
	recordHistoryLine(page, coordinates, { from: "alice", text: "in flight", mine: false, at: 1, attachments: [] });
	await old.putStarted;
	let swapped = false;
	const swapping = activateHistoryArchiveTarget(page, next).then(() => swapped = true);
	await Promise.resolve();
	assertEquals(swapped, false, "the old target retired while its write was active");
	release();
	await swapping;
	assertEquals(old.records.map((record) => record.text), ["in flight"]);
	assertEquals(old.retired, true);
	assertEquals(next.records.length, 0);
	await useDeviceHistoryArchive(page);
});

Deno.test("archive target retirement failure cannot undo the committed selection", async () => {
	const page = new RoomsPage();
	const old = new RefusingRetirementTarget("old archive");
	const next = new FakeTarget("new archive");
	const trouble: { source: string; reason: string }[] = [];
	setHistoryTroubleReporter(page, (source, reason) => trouble.push({ source, reason }));
	try {
		await activateHistoryArchiveTarget(page, old);
		await activateHistoryArchiveTarget(page, next);
		const selected = holdHistoryArchiveTarget(page);
		assertEquals(selected.target, next);
		selected.release();
		assertEquals(old.retired, true);
		assertEquals(trouble, [{ source: "archive target retirement", reason: "retirement refused" }]);
	} finally {
		setHistoryTroubleReporter(page, () => {});
		await useDeviceHistoryArchive(page);
	}
});

Deno.test("a write admitted during target retirement belongs to the new target", async () => {
	const page = new RoomsPage();
	const old = new FakeTarget("old archive");
	const release = old.holdPut();
	const next = new FakeTarget("new archive");
	await activateHistoryArchiveTarget(page, old);
	recordHistoryLine(page, coordinates, { from: "alice", text: "old write", mine: false, at: 1, attachments: [] });
	await old.putStarted;
	const swapping = activateHistoryArchiveTarget(page, next);
	recordHistoryLine(page, { ...coordinates, id: "new-write" }, {
		from: "alice",
		text: "new write",
		mine: false,
		at: 2,
		attachments: [],
	});
	release();
	await swapping;
	await settleHistoryWrites(page);
	assertEquals(old.records.map((record) => record.text), ["old write"]);
	assertEquals(next.records.map((record) => record.text), ["new write"]);
	await useDeviceHistoryArchive(page);
});

Deno.test("prepared passable authority defers old-target retirement without blocking selection", async () => {
	const page = new RoomsPage();
	const old = new FakeTarget("old archive");
	const next = new FakeTarget("new archive");
	await activateHistoryArchiveTarget(page, old);
	const prepared = holdHistoryArchiveTarget(page);
	assertEquals(prepared.target, old);
	await activateHistoryArchiveTarget(page, next);
	assertEquals(old.retired, false, "the old target retired before its prepared authority was handed or abandoned");
	prepared.release();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(old.retired, true);
	await useDeviceHistoryArchive(page);
});

Deno.test("archive reads retain the selected peer as their visible keeper", async () => {
	const page = new RoomsPage();
	const peer = new FakeTarget("iroh peer abcdef");
	peer.readRecords = [archived("remembered", "from peer")];
	await activateHistoryArchiveTarget(page, peer);
	const groups = await readHistoryLines(page, "directory-id", "alice");
	assertEquals(groups.map((group) => [group.keeper, group.lines.map((line) => line.text)]), [
		["iroh peer abcdef", ["from peer"]],
	]);
	for (const group of groups) group.release();
	await useDeviceHistoryArchive(page);
});

Deno.test("an archived file remains bound to the archive that supplied its record", async () => {
	const page = new RoomsPage();
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
	await activateHistoryArchiveTarget(page, old);
	const groups = await readHistoryLines(page, "directory-id", "alice");
	await activateHistoryArchiveTarget(page, next);
	assertEquals(old.retired, false);
	const record = groups[0]?.lines[0]?.archive;
	if (record == null) throw new Error("archive target test did not return its record");
	assertEquals(new TextDecoder().decode(await groups[0].readAttachment(record, 0)), "old archive");
	assertEquals(old.attachmentReads, 1);
	assertEquals(next.attachmentReads, 0);
	for (const group of groups) group.release();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(old.retired, true);
	await useDeviceHistoryArchive(page);
});

Deno.test("a target switch during an archive read transfers its lease to the returned generation", async () => {
	const page = new RoomsPage();
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
	await activateHistoryArchiveTarget(page, old);
	const reading = readHistoryLines(page, "directory-id", "alice");
	await old.readStarted;
	await activateHistoryArchiveTarget(page, next);
	assertEquals(old.retired, false);
	old.finishRead();
	const groups = await reading;
	const record = groups[0]?.lines[0]?.archive;
	if (record == null) throw new Error("the delayed archive read returned no record");
	assertEquals(new TextDecoder().decode(await groups[0].readAttachment(record, 0)), "delayed old archive");
	for (const group of groups) group.release();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(old.retired, true);
	await useDeviceHistoryArchive(page);
});

Deno.test("an unavailable selected peer yields no device-history fallback", async () => {
	const page = new RoomsPage();
	await activateHistoryArchiveTarget(page, unavailableHistoryArchiveTarget("remembered peer"));
	assertEquals(await readHistoryLines(page, "directory-id", "alice"), []);
	recordHistoryLine(page, coordinates, {
		from: "alice",
		text: "must not fall back",
		mine: false,
		at: 1,
		attachments: [],
	});
	// Switching waits for the refused queued write, proving it cannot surface
	// later in the device target after reconnect policy changes.
	await useDeviceHistoryArchive(page);
});

Deno.test("archive write and read failures reach their presentation owners", async () => {
	const page = new RoomsPage();
	const target = new RefusingTarget("refusing archive");
	const trouble: { source: string; reason: string }[] = [];
	setHistoryTroubleReporter(page, (source, reason) => trouble.push({ source, reason }));
	await activateHistoryArchiveTarget(page, target);
	try {
		recordHistoryLine(page, coordinates, {
			from: "alice",
			text: "not retained",
			mine: false,
			at: 1,
			attachments: [],
		});
		await settleHistoryWrites(page);
		assertEquals(trouble, [{ source: "message history write", reason: "archive write refused" }]);

		let readFailure = "";
		try {
			await readHistoryLines(page, "directory-id", "alice");
		} catch (error) {
			readFailure = error instanceof Error ? error.message : String(error);
		}
		assertEquals(readFailure, "archive read refused");
	} finally {
		setHistoryTroubleReporter(page, () => {});
		await useDeviceHistoryArchive(page);
	}
});

Deno.test("history from a closed conversation cannot hydrate its replacement", async () => {
	const page = new RoomsPage();
	const directory = dirId("directory");
	page.projection.set({
		...store.initialState(),
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
	const first = store.ensureRoom(page.projection, directory, "general", { persistId: "first-conversation" });
	const target = new DelayedReadTarget("delayed archive");
	target.readRecords = [archived("stale", "stale history")];
	await activateHistoryArchiveTarget(page, target);
	hydrateConversation(page, first);
	await target.readStarted;
	store.forgetConv(page.projection, first.key);
	closeArchiveGeneration(page, first.key);
	const replacement = store.ensureRoom(page.projection, directory, "general", {
		persistId: "replacement-conversation",
	});
	assertEquals(replacement.key, first.key);
	target.finishRead();
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(store.historyOf(page.projection, replacement.key).some((item) => item.kind === "chat"), false);
	await useDeviceHistoryArchive(page);
	assertEquals(target.retired, true);
});

Deno.test("a reused nickname cannot hydrate its prior registration's direct history", async () => {
	const page = new RoomsPage();
	const directory = dirId("directory-id");
	page.projection.set({
		...store.initialState(),
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
	await activateHistoryArchiveTarget(page, target);
	const first = store.restoreDm(page.projection, directory, "bo", registrationId(1), "first-direct", false);
	if (first == null) throw new Error("the first direct conversation was not restored");
	hydrateConversation(page, first);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(
		store.historyOf(page.projection, first.key).some((item) =>
			item.kind === "chat" && item.text === "old holder history"
		),
		true,
	);
	store.forgetConv(page.projection, first.key);
	closeArchiveGeneration(page, first.key);
	const replacement = store.restoreDm(
		page.projection,
		directory,
		"bo",
		registrationId(2),
		"replacement-direct",
		false,
	);
	if (replacement == null) throw new Error("the replacement direct conversation was not restored");
	hydrateConversation(page, replacement);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(target.conversations, ["first-direct", "replacement-direct"]);
	assertEquals(store.historyOf(page.projection, replacement.key).some((item) => item.kind === "chat"), false);
	await useDeviceHistoryArchive(page);
});
