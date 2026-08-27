import type { RoomsSessionLineEvent, RoomsSessionSnapshot } from "../lib/rooms_session.ts";
import { AttachedRoomsController } from "../web/ui/session/attached.ts";
import type { AttachedRoomsRemote } from "../web/ui/session/remote.ts";
import { assertEquals } from "./assert.ts";
import type { OperatorPage, OperatorRetireBatch } from "../lib/operator.ts";
import type { Attachment, AttachmentSource } from "../lib/attachment.ts";
import type { RoomsOperationsSnapshot } from "../lib/rooms_session.ts";
import { attachedOperationsBundle, attachedOperationsCredentials } from "../web/ui/session/operations_bundle.ts";
import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { roomsSessionSnapshot } from "./support/session_snapshot.ts";

Object.defineProperty(globalThis, "localStorage", {
	configurable: true,
	value: {
		getItem: () => null,
		setItem() {},
		removeItem() {},
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
const { firstAttachedSnapshot, settleAttachedOpening } = await import("../web/ui/session/attached_connection.ts");

Deno.test("attached establishment requires a live connection after its first snapshot", async () => {
	const snapshot = new FakeRemote().snapshotValue;
	const open = new Promise<{ error: Error }>(() => {});
	assertEquals(await firstAttachedSnapshot(Promise.resolve(snapshot), open), snapshot);

	const ended = new Error("connection ended during establishment");
	let refused: unknown = null;
	try {
		await firstAttachedSnapshot(Promise.resolve(snapshot), Promise.resolve({ error: ended }));
	} catch (error) {
		refused = error;
	}
	assertEquals(refused, ended);
});

Deno.test("an attached opening deadline retires a connection that arrives late", async () => {
	const late = Promise.withResolvers<AttachedRoomsController>();
	let closes = 0;
	const refused = await settleAttachedOpening(late.promise, 5).then(() => "", (error) => String(error));
	assertEquals(refused.includes("attachment deadline"), true);
	late.resolve({
		close: () => {
			closes += 1;
			return Promise.resolve();
		},
	} as AttachedRoomsController);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(closes, 1);
});

class FakeRemote implements AttachedRoomsRemote {
	snapshotValue: RoomsSessionSnapshot = roomsSessionSnapshot();
	changed: ((snapshot: RoomsSessionSnapshot) => void) | null = null;
	event: ((event: RoomsSessionLineEvent) => void) | null = null;
	calls: { id: string; base: number; name: string; args: string[] }[] = [];
	conflict = true;
	snapshots = 0;

	snapshot(): Promise<RoomsSessionSnapshot> {
		this.snapshots += 1;
		return Promise.resolve(this.snapshotValue);
	}

	watch(changed: (snapshot: RoomsSessionSnapshot) => void, event: (event: RoomsSessionLineEvent) => void) {
		this.changed = changed;
		this.event = event;
		return Promise.resolve(this.snapshotValue);
	}

	command(id: string, base: number, name: string, args: string[]): Promise<number> {
		this.calls.push({ id, base, name, args });
		if (this.conflict) {
			this.conflict = false;
			this.snapshotValue = { ...this.snapshotValue, revision: 1 };
			return Promise.reject(new Error("session revision changed from 0 to 1"));
		}
		this.snapshotValue = {
			...this.snapshotValue,
			revision: base + 1,
			checkpoint: { ...this.snapshotValue.checkpoint, standing: args[0] ?? "" },
		};
		queueMicrotask(() => this.changed?.(this.snapshotValue));
		return Promise.resolve(base + 1);
	}

	publishPeeredRoom(id: string, base: number, intent: unknown): Promise<number> {
		return this.command(id, base, "publishPeeredRoom", [JSON.stringify(intent)]);
	}

	revokePeeredRoom(id: string, base: number, publication: string): Promise<number> {
		return this.command(id, base, "revokePeeredRoom", [publication]);
	}

	setTyping(): Promise<void> {
		return Promise.resolve();
	}

	editLine(id: string, base: number, conversation: string, lineId: number, text: string): Promise<number> {
		return this.command(id, base, "editLine", [conversation, String(lineId), text]);
	}

	withdrawLine(id: string, base: number, conversation: string, lineId: number): Promise<number> {
		return this.command(id, base, "withdrawLine", [conversation, String(lineId)]);
	}

	replace(id: string, base: number): Promise<number> {
		return this.command(id, base, "replace", []);
	}

	adoptWorkspace(id: string, base: number): Promise<number> {
		return this.command(id, base, "adoptWorkspace", []);
	}

	sendFiles(id: string, base: number, conversation: string, caption: string): Promise<number> {
		return this.command(id, base, "sendFiles", [conversation, caption]);
	}

	refileLine(
		id: string,
		base: number,
		conversation: string,
		lineId: number,
		caption: string,
		keep: readonly number[],
		_files: AttachmentSource[],
	): Promise<number> {
		return this.command(id, base, "refileLine", [conversation, String(lineId), caption, ...keep.map(String)]);
	}

	readHistory(): Promise<[]> {
		return Promise.resolve([]);
	}

	operatorSnapshot(): Promise<never> {
		return Promise.reject(new Error("no operator in this fake"));
	}

	operatorPage(): Promise<OperatorPage> {
		return Promise.reject(new Error("no operator in this fake"));
	}

	operatorRetireMatching(): Promise<OperatorRetireBatch> {
		return Promise.reject(new Error("no operator in this fake"));
	}

	operationsSnapshot(): Promise<RoomsOperationsSnapshot> {
		return Promise.reject(new Error("no operations in this fake"));
	}

	shareArchiveHistory(): Promise<void> {
		return Promise.resolve();
	}

	readArchiveShare(): ReturnType<AttachedRoomsRemote["readArchiveShare"]> {
		return Promise.reject(new Error("no archive shares in this fake"));
	}

	dropArchiveShare(): Promise<void> {
		return Promise.resolve();
	}

	fetchAttachment(): Promise<Uint8Array> {
		return Promise.resolve(new Uint8Array());
	}

	fetchArchivedAttachment(): Promise<Uint8Array> {
		return Promise.resolve(new Uint8Array());
	}

	releaseAttachment(_attachment: Attachment): void {}

	resolveEffect(): Promise<void> {
		return Promise.resolve();
	}

	resumeEffect(): Promise<number> {
		return Promise.resolve(this.snapshotValue.revision);
	}

	issueGrant(id: string, rights: "observe" | "interact" | "admin", label: string) {
		return Promise.resolve({ id, rights, label, sturdyref: `ocapn://session.id/s/${id}` });
	}

	revokeGrant(_id: string): Promise<void> {
		return Promise.resolve();
	}
}

Deno.test("attached workspace methods own positional command encoding", async () => {
	const remote = new FakeRemote();
	remote.conflict = false;
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	await controller.setDirectoryNick("directory", "ada");
	await controller.setDirectoryStanding("directory", null);
	await controller.setRoomStanding("room", "away");
	await controller.setIgnoredNames(["bo"]);
	await controller.chooseHistoryRetention(false);
	await controller.chooseConnection("relay", "wss://rooms.test/viz");
	await controller.selectArchive(null);
	assertEquals(remote.calls.map(({ name, args }) => ({ name, args })), [
		{ name: "setDirectoryNick", args: ["directory", "ada"] },
		{ name: "setDirectoryStanding", args: ["directory"] },
		{ name: "setRoomStanding", args: ["room", "away"] },
		{ name: "setIgnoredNames", args: ['["bo"]'] },
		{ name: "chooseHistoryRetention", args: ["false"] },
		{ name: "chooseConnection", args: ["relay", "wss://rooms.test/viz"] },
		{ name: "selectArchive", args: [] },
	]);
});

class DraftRemote extends FakeRemote {
	started!: () => void;
	finish!: () => void;
	readonly commandStarted = new Promise<void>((resolve) => this.started = resolve);
	readonly commandFinish = new Promise<void>((resolve) => this.finish = resolve);

	override async command(id: string, base: number, name: string, args: string[]): Promise<number> {
		this.started();
		await this.commandFinish;
		return await super.command(id, base, name, args);
	}
}

class StaleRevisionRemote extends FakeRemote {
	constructor() {
		super();
		this.conflict = false;
	}

	override command(id: string, base: number, name: string, args: string[]): Promise<number> {
		this.calls.push({ id, base, name, args });
		return Promise.resolve(base + 1);
	}
}

class GapSnapshotFailureRemote extends FakeRemote {
	override snapshot(): Promise<RoomsSessionSnapshot> {
		return Promise.reject(new Error("snapshot unavailable"));
	}
}

class LostRoomAuthorityRemote extends FakeRemote {
	readonly lost = new Set<string>();

	override command(id: string, base: number, name: string, args: string[]): Promise<number> {
		this.calls.push({ id, base, name, args });
		if (name !== "ensureRoomLink" && name !== "takeRoomModerator") return super.command(id, base, name, args);
		if (!this.lost.has(id)) {
			this.lost.add(id);
			const room = this.snapshotValue.checkpoint.conversations.find((entry) => entry.kind === "room");
			if (room?.kind === "room") {
				this.snapshotValue = {
					...this.snapshotValue,
					revision: base + 1,
					checkpoint: {
						...this.snapshotValue.checkpoint,
						conversations: this.snapshotValue.checkpoint.conversations.map((entry) =>
							entry.id !== room.id ? entry : {
								...entry,
								link: "ocapn://directory.example/s/room-link",
								...(name === "takeRoomModerator"
									? { steward: "ocapn://directory.example/s/steward-link" }
									: {}),
							}
						),
					},
				};
			}
			queueMicrotask(() => this.changed?.(this.snapshotValue));
			return Promise.reject(new Error("the result response was lost"));
		}
		return Promise.resolve(this.snapshotValue.revision);
	}
}

Deno.test("an attached controller retries one pure command unchanged after a revision race", async () => {
	const remote = new FakeRemote();
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	const settled = await controller.setStanding("away");
	assertEquals(settled.revision, 2);
	assertEquals(settled.checkpoint.standing, "away");
	assertEquals(remote.calls.length, 2);
	assertEquals(remote.calls[0].id, remote.calls[1].id);
	assertEquals(remote.calls.map((call) => call.base), [0, 1]);
	assertEquals(remote.calls[1].args, ["away"]);
	remote.event?.({
		source: "lines",
		sequence: 3,
		conversationId: "room",
		from: "bo",
		text: "gap",
		at: 1,
		lineId: null,
		change: null,
		editable: false,
		system: false,
		history: null,
		attachments: [],
	});
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(remote.snapshots, 2);
	await controller.close();
});

Deno.test("an attached controller protects a staged draft through debounce and acknowledgement", async () => {
	const remote = new DraftRemote();
	remote.conflict = false;
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	controller.stageDraft("room", "still typing");
	assertEquals(controller.pendingDraft("room"), "still typing");
	const writing = controller.setDraft("room", "still typing");
	await remote.commandStarted;
	assertEquals(controller.pendingDraft("room"), "still typing");
	remote.finish();
	await writing;
	assertEquals(controller.pendingDraft("room"), undefined);
	await controller.close();
});

Deno.test("an attached command refuses a snapshot that never reaches its acknowledged revision", async () => {
	const remote = new StaleRevisionRemote();
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	let reason = "";
	try {
		await controller.setStanding("away");
	} catch (error) {
		reason = error instanceof Error ? error.message : String(error);
	}
	assertEquals(reason, "the attached Rooms session snapshot stayed at revision 0 after revision 1");
	await controller.close();
});

Deno.test("an attached controller drops the event that exposes a sequence gap", async () => {
	const remote = new FakeRemote();
	const controller = new AttachedRoomsController(remote);
	const received: string[] = [];
	controller.onLine((event) => received.push(event.text));
	await controller.start();
	remote.event?.({
		source: "lines",
		sequence: 1,
		conversationId: "room",
		from: "bo",
		text: "first",
		at: 1,
		lineId: null,
		change: null,
		editable: false,
		system: false,
		history: null,
		attachments: [],
	});
	remote.event?.({
		source: "lines",
		sequence: 3,
		conversationId: "room",
		from: "bo",
		text: "gap-causing event",
		at: 2,
		lineId: null,
		change: null,
		editable: false,
		system: false,
		history: null,
		attachments: [],
	});
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(received, ["first"]);
	await controller.close();
});

Deno.test("an attached event gap keeps the failed reconciliation visible", async () => {
	const remote = new GapSnapshotFailureRemote();
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	remote.event?.({
		source: "lines",
		sequence: 2,
		conversationId: "room",
		from: "bo",
		text: "gap",
		at: 1,
		lineId: null,
		change: null,
		editable: false,
		system: false,
		history: null,
		attachments: [],
	});
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(
		controller.current?.issues.find((issue) => issue.subject === "event-gap")?.reason,
		"The shared event stream skipped a sequence; history is reconciling. Snapshot refresh failed: snapshot unavailable",
	);
	await controller.close();
});

Deno.test("the bounded initial event buffer reports rather than hiding overflow", async () => {
	const remote = new GapSnapshotFailureRemote();
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	for (let sequence = 1; sequence <= 257; sequence += 1) {
		remote.event?.({
			source: "lines",
			sequence,
			conversationId: "room",
			from: "bo",
			text: `line-${sequence}`,
			at: sequence,
			lineId: null,
			change: null,
			editable: false,
			system: false,
			history: null,
			attachments: [],
		});
	}
	const received: string[] = [];
	controller.onLine((event) => received.push(event.text));
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(received.length, 256);
	assertEquals(received[0], "line-2");
	assertEquals(
		controller.current?.issues.find((issue) => issue.subject === "event-gap")?.reason,
		"The shared event stream exceeded its initial buffer; history is reconciling. Snapshot refresh failed: snapshot unavailable",
	);
	await controller.close();
});

Deno.test("an attached controller never retries an external send implicitly", async () => {
	const remote = new FakeRemote();
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	let refused = false;
	try {
		await controller.say("room", "once");
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	assertEquals(remote.calls.length, 1);
	await controller.close();
});

Deno.test("attached room authority retries reuse the intent operation after a lost response", async () => {
	const remote = new LostRoomAuthorityRemote();
	remote.snapshotValue = {
		...remote.snapshotValue,
		checkpoint: {
			...emptyRoomsSessionState(),
			directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
			conversations: [{
				kind: "room",
				id: "room",
				directory: "directory",
				name: "general",
				held: false,
				standing: null,
				draft: "",
			}],
		},
	};
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	let refused = false;
	try {
		await controller.ensureRoomLink("room");
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	await controller.ensureRoomLink("room");
	let moderatorRefused = false;
	try {
		await controller.takeRoomModerator("room");
	} catch {
		moderatorRefused = true;
	}
	assertEquals(moderatorRefused, true);
	await controller.takeRoomModerator("room");
	assertEquals(remote.lost.size, 2);
	const ensureCalls = remote.calls.filter((call) => call.name === "ensureRoomLink");
	const moderatorCalls = remote.calls.filter((call) => call.name === "takeRoomModerator");
	assertEquals(ensureCalls.length, 2);
	assertEquals(moderatorCalls.length, 2);
	assertEquals(ensureCalls[0].id, ensureCalls[1].id);
	assertEquals(moderatorCalls[0].id, moderatorCalls[1].id);
	await controller.close();
});

Deno.test("each attached watch stream begins at sequence one", async () => {
	const first = new FakeRemote();
	const firstController = new AttachedRoomsController(first);
	await firstController.start();
	first.event?.({
		source: "first",
		sequence: 1,
		conversationId: "room",
		from: "bo",
		text: "one",
		at: 1,
		lineId: null,
		change: null,
		editable: false,
		system: false,
		history: null,
		attachments: [],
	});
	assertEquals(first.snapshots, 0);

	const second = new FakeRemote();
	const secondController = new AttachedRoomsController(second);
	await secondController.start();
	second.event?.({
		source: "second",
		sequence: 1,
		conversationId: "room",
		from: "bo",
		text: "one",
		at: 1,
		lineId: null,
		change: null,
		editable: false,
		system: false,
		history: null,
		attachments: [],
	});
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(second.snapshots, 0);

	await secondController.close();
	await firstController.close();
});

Deno.test("an attached capability bundle preserves foreign scopes and replaces its visualizer", async () => {
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [
			{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null },
			{ id: "elsewhere", locator: "127.0.0.1:2", home: false, nick: "ada", standing: null },
		],
		capabilities: {
			archivePeer: null,
			operations: [
				{ capability: "listeners" as const, scope: "directory", swiss: "old-listeners" },
				{ capability: "diagnostics" as const, scope: "elsewhere", swiss: "elsewhere-diagnostics" },
				{ capability: "viz" as const, scope: "ws://old.test/viz", swiss: "old-viz" },
			],
		},
	};
	const credentials = await attachedOperationsCredentials(
		checkpoint,
		new Map([
			["operator", "operator-swiss"],
			["viz", "viz-swiss"],
		]),
		() => Promise.resolve("ws://rooms.test/viz"),
	);
	assertEquals(credentials, [
		{ capability: "diagnostics", scope: "elsewhere", swiss: "elsewhere-diagnostics" },
		{ capability: "operator", scope: "directory", swiss: "operator-swiss" },
		{ capability: "viz", scope: "ws://old.test/viz", swiss: "viz-swiss" },
	]);
	assertEquals(
		attachedOperationsBundle({ ...checkpoint, capabilities: { operations: credentials, archivePeer: null } }),
		"ROOMS-OPERATOR operator-swiss\nROOMS-VIZ viz-swiss",
	);
});
