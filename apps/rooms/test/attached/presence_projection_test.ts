// Attached IRC presence updates roster and issue state without inventing conversation lines.
/// <reference lib="dom" />

import type { RoomsSessionSnapshot } from "../../lib/session/client.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { assertEquals } = await import("../assert.ts");
const { roomsSessionSnapshot } = await import("../support/session_snapshot.ts");

Deno.test("attached IRC seat state updates the roster without drawing an empty line", () => {
	const page = new RoomsPage();
	page.projection.set({
		...store.initialState(),
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	const projection = new AttachedSessionProjection(page);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "bridge",
			directory: "directory",
			name: "libera/#glowcap",
			held: false,
			standing: null,
			draft: "",
		}],
		active: "bridge",
	};
	const roomViews = [{
		conversationId: "bridge",
		membershipKind: "participant",
		policy: { visibility: "listed", entry: "open", speaking: "open" },
		members: [["ada", { online: true, away: "" }]],
		topic: null,
		lineBytes: null,
	}] satisfies RoomsSessionSnapshot["roomViews"];
	projection.apply(roomsSessionSnapshot({
		checkpoint,
		connectedDirectories: ["directory"],
		roomViews,
	}));
	const room = [...page.projection.get().convs.values()][0];
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
		presence: {
			kind: "seat",
			name: "ada",
			state: "connecting",
			nick: "ada_irc",
			network: "Libera",
			badge: "LINKING",
			said: "Linking Libera as ada_irc",
		},
		history: null,
		previewUrls: [],
		attachments: [],
	});
	const afterLine = store.getConv(page.projection, room.key);
	assertEquals(
		afterLine?.type === "room" ? store.membersOf(page.projection, room.key).get("ada")?.seat?.state : null,
		undefined,
	);
	assertEquals(store.historyOf(page.projection, room.key).length, 0);
	const seatedRoomViews = [{
		...roomViews[0],
		members: [["ada", {
			online: true,
			away: "",
			seat: {
				state: "connecting" as const,
				nick: "ada_irc",
				network: "Libera",
				badge: "LINKING",
				said: "Linking Libera as ada_irc",
			},
		}]],
	}] satisfies RoomsSessionSnapshot["roomViews"];
	projection.apply(roomsSessionSnapshot({
		revision: 1,
		checkpoint,
		connectedDirectories: ["directory"],
		roomViews: seatedRoomViews,
	}));
	const updated = store.getConv(page.projection, room.key);
	assertEquals(
		updated?.type === "room" ? store.membersOf(page.projection, room.key).get("ada")?.seat?.state : null,
		"connecting",
	);
	projection.apply(roomsSessionSnapshot({
		revision: 2,
		checkpoint: {
			...checkpoint,
			conversations: [{
				...checkpoint.conversations[0],
				bridgeIntent: { scope: "Libera", action: "link", answers: { nick: "ada" }, secretsGiven: false },
			}],
		},
		connectedDirectories: ["directory"],
		roomViews: seatedRoomViews,
	}));
	const sameRoom = [...page.projection.get().convs.values()].find((conversation) =>
		conversation.type !== "directory" && conversation.persistId === "bridge"
	);
	assertEquals(sameRoom?.key, room.key);
	assertEquals(page.projection.get().activeKey, room.key);
	assertEquals(sameRoom?.type === "room" ? sameRoom.bridgeIntent?.answers["nick"] : null, "ada");
});

Deno.test("attached IRC reconciliation issues remain reactive after command acknowledgement", () => {
	const page = new RoomsPage();
	page.projection.set({
		...store.initialState(),
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	const projection = new AttachedSessionProjection(page);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "bridge",
			directory: "directory",
			name: "libera/#glowcap",
			held: false,
			standing: null,
			draft: "",
			bridgeIntent: {
				scope: "Libera",
				action: "link",
				answers: { nick: "ada_irc", account: "ada" },
				secretsGiven: true,
			},
		}],
	};
	projection.apply(roomsSessionSnapshot({
		checkpoint,
		issues: [{ subject: "room-bridge:directory:bridge", reason: "IRC refused the registered account" }],
	}));
	const room = [...page.projection.get().convs.values()][0];
	assertEquals(room?.type === "room" ? room.bridgeIssue : null, "IRC refused the registered account");

	projection.apply(roomsSessionSnapshot({ revision: 1, checkpoint, issues: [] }));
	const retrying = [...page.projection.get().convs.values()][0];
	assertEquals(retrying?.type === "room" ? retrying.bridgeIssue : null, "");
});
