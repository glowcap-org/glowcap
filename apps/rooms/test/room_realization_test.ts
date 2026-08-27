import type { Message, Room } from "../lib/room_client.ts";
import type { WorkspaceConversation } from "../lib/rooms_state.ts";
import type { LiveDirectory, LiveRoom } from "../session/live.ts";
import { RoomRealization } from "../session/room_realization.ts";
import { roomsConversationTopology } from "../session/topology.ts";
import { freshRoomView } from "../session/room_view.ts";
import { assertEquals } from "./assert.ts";

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
	} satisfies Extract<WorkspaceConversation, { kind: "room" }>;
	let released = 0;
	let retried = 0;
	let issue = "";
	await realization.drain(held, conversation, room, {
		release: (owned) => {
			if (owned === live) released += 1;
		},
		message: () => {},
		scheduleRetry: () => retried += 1,
		scheduleRoomViewNotify: () => {},
		setIssue: (_subject, error) => issue = error instanceof Error ? error.message : String(error),
	});
	assertEquals(released, 1);
	assertEquals(retried, 1);
	assertEquals(issue, "stream ended badly");
	assertEquals(realization.rooms.has("room-1"), false);
});

Deno.test("IRC identity reconciliation keeps the live Rooms membership", async () => {
	const realization = new RoomRealization();
	const identities: string[] = [];
	let disconnects = 0;
	const room = {
		ircIdentity: (nick: string) => {
			identities.push(nick);
			return Promise.resolve("");
		},
		disconnectIrc: () => {
			disconnects += 1;
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
	} satisfies Extract<WorkspaceConversation, { kind: "room" }>;
	const live = {
		topology: roomsConversationTopology(base),
		ircIntent: "automatic",
		room,
	} as LiveRoom;
	realization.rooms.set(base.id, live);
	const held = { id: base.directory, nick: "ada" } as LiveDirectory;
	const issues = new Map<string, unknown>();
	let releases = 0;
	const reconcile = (
		conversation: typeof base & { irc?: { nick: string; account: string; password: string } | null },
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
		() => {},
	);
	await reconcile({ ...base, irc: { nick: "chosen", account: "", password: "" } });
	assertEquals(identities, ["chosen"]);
	assertEquals(realization.rooms.get(base.id), live);
	assertEquals(releases, 0);
	await reconcile({ ...base, irc: null });
	assertEquals(disconnects, 1);
	assertEquals(realization.rooms.get(base.id), live);
	assertEquals(issues.size, 0);
});

Deno.test("a failed IRC seat makes the saved identity retryable", async () => {
	const realization = new RoomRealization();
	const stop = Promise.withResolvers<void>();
	const delivered = Promise.withResolvers<void>();
	const failed: Message = {
		from: "room",
		text: "",
		system: true,
		presence: { kind: "irc-seat", name: "ada", state: "failed", nick: "ada" },
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
		ircIntent: JSON.stringify({ nick: "ada", account: "", password: "" }),
		files: { apply() {}, project: () => [] },
		view: freshRoomView(),
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
	} satisfies Extract<WorkspaceConversation, { kind: "room" }>;
	const draining = realization.drain({ id: "directory", nick: "ada" } as LiveDirectory, conversation, room, {
		release: () => {},
		message: () => delivered.resolve(),
		scheduleRetry: () => {},
		scheduleRoomViewNotify: () => {},
		setIssue: () => {},
	});
	await delivered.promise;
	assertEquals(live.ircIntent, "failed");
	realization.rooms.delete(conversation.id);
	stop.resolve();
	await draining;
});
