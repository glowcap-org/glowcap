import type { Message, Room } from "../../lib/room/client.ts";
import type { WorkspaceRoomConversation } from "../../lib/rooms_state.ts";
import type { LiveDirectory, LiveRoom } from "../../session/live.ts";
import { IRC_DISCONNECT_ACTION, IRC_NICK_FIELD } from "../../irc/bridge/identity_form.ts";
import type { WorkspaceRoomBridgeIntent } from "../../lib/rooms_state.ts";
import { RoomRealization } from "../../session/room_realization.ts";
import { roomsConversationTopology } from "../../session/topology.ts";
import { freshRoomView } from "../../session/room_view.ts";
import { assertEquals } from "../assert.ts";

Deno.test("a failed room drain retires its live owner through the complete callback contract", async () => {
	const realization = new RoomRealization();
	const room = {
		messages: {
			async *[Symbol.asyncIterator]() {
				yield await Promise.reject(new Error("stream ended badly"));
			},
		},
	} as unknown as Room;
	const live = { room } as LiveRoom;
	realization.rooms.set("room-1", live);
	const held = { id: "directory", nick: "ada" } as LiveDirectory;
	const conversation = {
		kind: "room",
		id: "room-1",
		directory: "directory",
		name: "general",
		held: false,
		standing: null,
		draft: "",
	} satisfies WorkspaceRoomConversation;
	let released = 0;
	let retried = 0;
	let issue = "";
	await realization.drain(held, conversation, room, {
		release: (owned) => {
			if (owned === live) released += 1;
		},
		message: () => {},
		typing: () => {},
		scheduleRetry: () => retried += 1,
		scheduleRoomViewNotify: () => {},
		setIssue: (_subject, error) => issue = error instanceof Error ? error.message : String(error),
	});
	assertEquals(released, 1);
	assertEquals(retried, 1);
	assertEquals(issue, "stream ended badly");
	assertEquals(realization.rooms.has("room-1"), false);
});

Deno.test("room events follow current intent rather than a past reconciliation generation", () => {
	const realization = new RoomRealization();
	const room = {} as Room;
	const conversation = {
		kind: "room",
		id: "room-1",
		directory: "directory",
		name: "general",
		held: false,
		standing: null,
		draft: "",
	} satisfies WorkspaceRoomConversation;
	realization.rooms.set("room-1", {
		room,
		topology: roomsConversationTopology(conversation),
	} as LiveRoom);
	realization.expectEvents("directory", [conversation]);
	assertEquals(realization.acceptsEvent("room-1", room), true);
	realization.expectEvents("directory", []);
	assertEquals(realization.acceptsEvent("room-1", room), false);
	realization.expectEvents("directory", [conversation]);
	assertEquals(realization.acceptsEvent("room-1", room), true);
});

Deno.test("closing a room realization fences callbacks before leave settles", async () => {
	const realization = new RoomRealization();
	const leaving = Promise.withResolvers<void>();
	const room = { leave: () => leaving.promise } as unknown as Room;
	const conversation = {
		kind: "room" as const,
		id: "room-1",
		directory: "directory",
		name: "general",
		held: false,
		standing: null,
		draft: "",
	};
	realization.rooms.set(conversation.id, {
		room,
		topology: roomsConversationTopology(conversation),
	} as LiveRoom);
	realization.expectEvents(conversation.directory, [conversation]);
	const closing = realization.close(() => {}, async (work) => {
		await work;
	});
	assertEquals(realization.acceptsEvent(conversation.id, room), false);
	leaving.resolve();
	await closing;
});

Deno.test("IRC identity reconciliation keeps the live Rooms membership", async () => {
	const realization = new RoomRealization();
	const identities: string[] = [];
	let disconnects = 0;
	// One verb now carries both acts, so the stub tells them apart the way the
	// bridge does: by which action was pressed.
	const room = {
		submitBridgeForm: (action: string, answers: Record<string, string>) => {
			if (action === IRC_DISCONNECT_ACTION) disconnects += 1;
			else identities.push(answers[IRC_NICK_FIELD] ?? "");
			return Promise.resolve("");
		},
	} as unknown as Room;
	const base = {
		kind: "room",
		id: "room-1",
		directory: "directory",
		name: "bridge",
		held: false,
		standing: null,
		draft: "",
	} satisfies WorkspaceRoomConversation;
	const live = {
		topology: roomsConversationTopology(base),
		bridgeIntent: "automatic",
		room,
	} as LiveRoom;
	realization.rooms.set(base.id, live);
	const held = { id: base.directory, nick: "ada" } as LiveDirectory;
	const issues = new Map<string, unknown>();
	let releases = 0;
	const reconcile = (
		conversation: typeof base & { bridgeIntent?: WorkspaceRoomBridgeIntent | null },
	) => realization.reconcile(
		held,
		[conversation],
		(subject, error) => {
			if (error == null) issues.delete(subject);
			else issues.set(subject, error);
			return true;
		},
		() => Promise.resolve(),
		() => releases += 1,
		async () => {},
		async () => {},
		async () => {},
		() => true,
		() => {},
		() => {},
		() => ({}),
		() => {},
	);
	await reconcile({
		...base,
		bridgeIntent: { scope: "Libera", action: "link", answers: { nick: "chosen" }, secretsGiven: false },
	});
	assertEquals(identities, ["chosen"]);
	assertEquals(realization.rooms.get(base.id), live);
	assertEquals(releases, 0);
	// Disconnecting is a submission like any other, because staying Rooms-only
	// is a state a reader chose and a reconnect has to restore it too.
	await reconcile({
		...base,
		bridgeIntent: { scope: "Libera", action: IRC_DISCONNECT_ACTION, answers: {}, secretsGiven: false },
	});
	assertEquals(disconnects, 1);
	assertEquals(realization.rooms.get(base.id), live);
	assertEquals(issues.size, 0);
	// Having no saved intent is not the same as having chosen to disconnect: it
	// means nobody has answered this bridge, so nothing is replayed to it.
	await reconcile({ ...base, bridgeIntent: null });
	assertEquals(disconnects, 1);
	assertEquals(identities, ["chosen"]);
});

Deno.test("a failed IRC seat makes the saved identity retryable", async () => {
	const realization = new RoomRealization();
	const stop = Promise.withResolvers<void>();
	const delivered = Promise.withResolvers<void>();
	const failed: Message = {
		from: "room",
		text: "",
		system: true,
		presence: {
			kind: "seat",
			name: "ada",
			state: "failed",
			nick: "ada",
			network: "Libera",
			badge: "FAILED",
			said: "Libera link failed as ada",
		},
		attachments: [],
	};
	const room = {
		messages: {
			async *[Symbol.asyncIterator]() {
				yield failed;
				await stop.promise;
			},
		},
	} as unknown as Room;
	const live = {
		room,
		bridgeIntent: JSON.stringify({ nick: "ada", account: "" }),
		files: { apply() {}, project: () => [] },
		view: freshRoomView("participant", { visibility: "listed", entry: "open", speaking: "open" }),
		postedLines: new Map(),
		pendingLines: [],
	} as unknown as LiveRoom;
	realization.rooms.set("room-1", live);
	const conversation = {
		kind: "room",
		id: "room-1",
		directory: "directory",
		name: "bridge",
		held: false,
		standing: null,
		draft: "",
	} satisfies WorkspaceRoomConversation;
	const draining = realization.drain({ id: "directory", nick: "ada" } as LiveDirectory, conversation, room, {
		release: () => {},
		message: () => delivered.resolve(),
		typing: () => {},
		scheduleRetry: () => {},
		scheduleRoomViewNotify: () => {},
		setIssue: () => {},
	});
	await delivered.promise;
	assertEquals(live.bridgeIntent, "failed");
	realization.rooms.delete(conversation.id);
	stop.resolve();
	await draining;
});
