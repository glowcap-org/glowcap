import { AttachedRoomsController } from "../../web/ui/session/attached.ts";
import { assertEquals } from "../assert.ts";
import { attachedOperationsBundle, attachedOperationsCredentials } from "../../web/ui/session/operations_bundle.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { roomsSessionSnapshot } from "../support/session_snapshot.ts";
import {
	DraftRemote,
	FakeRemote,
	GapSnapshotFailureRemote,
	HeldCommandRemote,
	LostRoomAuthorityRemote,
	PendingRoomAuthorityRemote,
	StaleRevisionRemote,
} from "../support/attached_remote.ts";

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
const { firstAttachedSnapshot, settleAttachedOpening } = await import("../../web/ui/session/attached_connection.ts");

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

Deno.test("attached workspace methods own positional command encoding", async () => {
	const remote = new FakeRemote();
	remote.conflict = false;
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	await controller.setDirectoryNick("directory", "ada");
	await controller.setDirectoryStanding("directory", null);
	await controller.setRoomStanding("room", "away");
	await controller.dropRoomModerator("room", "moderator-token");
	await controller.setIgnoredNames(["bo"]);
	await controller.chooseHistoryRetention(false);
	await controller.chooseConnection("relay", "wss://rooms.test/viz");
	await controller.selectArchive(null);
	assertEquals(remote.calls.map(({ name, args }) => ({ name, args })), [
		{ name: "setDirectoryNick", args: ["directory", "ada"] },
		{ name: "setDirectoryStanding", args: ["directory"] },
		{ name: "setRoomStanding", args: ["room", "away"] },
		{ name: "dropRoomModerator", args: ["room", "moderator-token"] },
		{ name: "setIgnoredNames", args: ['["bo"]'] },
		{ name: "chooseHistoryRetention", args: ["false"] },
		{ name: "chooseConnection", args: ["relay", "wss://rooms.test/viz"] },
		{ name: "selectArchive", args: [] },
	]);
});

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
		controller.current?.issues.find((issue) => issue.subject === "event-gap:room")?.reason,
		"The shared event stream skipped a sequence. Retained history is reconciling for this conversation. Snapshot refresh failed: snapshot unavailable",
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
		controller.current?.issues.find((issue) => issue.subject === "event-gap:room")?.reason,
		"The shared event stream exceeded its initial buffer. Retained history is reconciling for this conversation. Snapshot refresh failed: snapshot unavailable",
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

Deno.test("an attached authority action reconciles a prior recoverable result before starting another", async () => {
	const remote = new PendingRoomAuthorityRemote();
	remote.conflict = false;
	remote.snapshotValue = roomsSessionSnapshot({
		revision: 4,
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
		pendingEffects: ["lost-link"],
		pendingEffectDetails: [{
			id: "lost-link",
			kind: "room-link",
			subject: 'Save a durable link for room "general"',
			phase: "prepared",
		}],
	});
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	const settled = await controller.ensureRoomLink("room");
	assertEquals(remote.resumed, ["lost-link"]);
	assertEquals(remote.calls.length, 0);
	assertEquals(
		settled.checkpoint.conversations[0]?.kind === "room" && settled.checkpoint.conversations[0].link,
		"ocapn://directory.example/s/recovered-link",
	);
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

// Measured against both ways of getting it wrong: never claiming the operation
// — which is what the page did, and why the notice arrived on every line
// anybody sent — turns the first of these red, and claiming it and never
// letting go, which would silence the notice for good, turns the second red.
//
// A pending operation is only the page's business when nobody is answering for
// it. While this tab awaits one it will settle, or fail where it was asked for,
// and the notice that asks a reader to decide something must stay away — it
// appeared and left again on every line anybody sent.
Deno.test("a controller claims the operation it is awaiting and lets go either way", async () => {
	const remote = new HeldCommandRemote();
	remote.conflict = false;
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	assertEquals([...controller.driving()], []);

	const sending = controller.say("room", "a line on its way");
	const id = await remote.opened.promise;
	assertEquals([...controller.driving()], [id], "the tab does not claim the operation it is awaiting");
	assertEquals(remote.snapshotValue.pendingEffectDetails.map((effect) => effect.id), [id]);
	remote.answer.resolve();
	await sending;
	assertEquals([...controller.driving()], [], "the tab still claims an operation that has settled");
	await controller.close();
});

Deno.test("a controller lets go of an operation whose command refused", async () => {
	const remote = new HeldCommandRemote();
	remote.conflict = false;
	remote.refuse = new Error("the session would not take it");
	const controller = new AttachedRoomsController(remote);
	await controller.start();
	const sending = controller.say("room", "a line that will not land");
	await remote.opened.promise;
	remote.answer.resolve();
	let refused = "";
	try {
		await sending;
	} catch (error) {
		refused = error instanceof Error ? error.message : String(error);
	}
	assertEquals(refused, "the session would not take it");
	// The operation is still in the ledger and nothing is answering for it now,
	// which is exactly when a reader has to be asked about it.
	assertEquals(remote.snapshotValue.pendingEffectDetails.length, 1);
	assertEquals([...controller.driving()], [], "a refused command left the tab still claiming its operation");
	await controller.close();
});
