/// <reference lib="dom" />

import type { RoomsSessionSnapshot } from "../lib/rooms_session.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../web/ui/session/projection.ts");
const { emptyRoomsSessionState } = await import("../lib/rooms_state.ts");
const store = await import("../web/ui/store.ts");
const { assertEquals } = await import("./assert.ts");
const { roomsSessionSnapshot } = await import("./support/session_snapshot.ts");

Deno.test("attached IRC seat state updates the roster without drawing an empty line", () => {
	store.set({
		...store.initial,
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	const projection = new AttachedSessionProjection();
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "bridge",
			directory: "directory",
			name: "libera/#pancake",
			held: false,
			standing: null,
			draft: "",
		}],
		active: "bridge",
	};
	const roomViews = [{
		conversationId: "bridge",
		members: [["ada", { online: true, away: "" }]],
		topic: null,
		lineBytes: null,
	}] satisfies RoomsSessionSnapshot["roomViews"];
	projection.apply(roomsSessionSnapshot({
		checkpoint,
		connectedDirectories: ["directory"],
		roomViews,
	}));
	const room = [...store.get().convs.values()][0];
	if (room?.type !== "room") throw new Error("the attached bridge fixture created no room");
	projection.line({
		source: "lines",
		sequence: 1,
		conversationId: "bridge",
		from: "room",
		text: "",
		at: 1,
		lineId: null,
		change: null,
		editable: false,
		system: true,
		presence: { kind: "irc-seat", name: "ada", state: "connecting", nick: "ada_irc" },
		history: null,
		attachments: [],
	});
	const updated = store.getConv(room.key);
	assertEquals(updated?.type === "room" ? updated.members.get("ada")?.irc?.state : null, "connecting");
	assertEquals(updated?.history.length, 0);
	projection.apply(roomsSessionSnapshot({
		revision: 1,
		checkpoint: {
			...checkpoint,
			conversations: [{
				...checkpoint.conversations[0],
				irc: { nick: "ada", account: "", password: "" },
			}],
		},
		connectedDirectories: ["directory"],
		roomViews,
	}));
	const sameRoom = [...store.get().convs.values()].find((conversation) => conversation.persistId === "bridge");
	assertEquals(sameRoom?.key, room.key);
	assertEquals(store.get().activeKey, room.key);
	assertEquals(sameRoom?.type === "room" ? sameRoom.irc?.nick : null, "ada");
});

Deno.test("attached IRC reconciliation issues remain reactive after command acknowledgement", () => {
	store.set({
		...store.initial,
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	const projection = new AttachedSessionProjection();
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "bridge",
			directory: "directory",
			name: "libera/#pancake",
			held: false,
			standing: null,
			draft: "",
			irc: { nick: "ada_irc", account: "ada", password: "secret" },
		}],
	};
	projection.apply(roomsSessionSnapshot({
		checkpoint,
		issues: [{ subject: "room-irc:directory:bridge", reason: "IRC refused the registered account" }],
	}));
	const room = [...store.get().convs.values()][0];
	assertEquals(room?.type === "room" ? room.ircIssue : null, "IRC refused the registered account");

	projection.apply(roomsSessionSnapshot({ revision: 1, checkpoint, issues: [] }));
	const retrying = [...store.get().convs.values()][0];
	assertEquals(retrying?.type === "room" ? retrying.ircIssue : null, "");
});
