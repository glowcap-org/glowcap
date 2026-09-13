// Mixed direct-message projection restores liveness without crossing lines between conversation identities.
/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { emptyRoomsSessionState } = await import("../lib/rooms_state.ts");
const { AttachedSessionProjection } = await import("../web/ui/session/projection.ts");
const store = await import("../web/ui/store.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { assertEquals } = await import("./assert.ts");
const { roomsSessionSnapshot } = await import("./support/session_snapshot.ts");
const { registrationId } = await import("./support/registration.ts");

Deno.test("mixed DM projection recovers liveness without crossing lines", () => {
	const page = new RoomsPage();
	page.projection.reset();
	const projection = new AttachedSessionProjection(page);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "alice", standing: null }],
		conversations: [{
			kind: "direct" as const,
			id: "alice-bob",
			directory: "directory",
			peer: "bob",
			peerRegistrationId: registrationId(1),
			closed: false,
			draft: "",
		}],
	};
	projection.apply(roomsSessionSnapshot({
		revision: 1,
		checkpoint,
		issues: [{ subject: "direct:directory:alice-bob", reason: "bob was unavailable" }],
	}));
	const direct = [...page.projection.get().convs.values()].find((conversation) =>
		conversation.type !== "directory" && conversation.persistId === "alice-bob"
	);
	if (direct?.type !== "dm") throw new Error("the mixed direct fixture was not projected");
	const lineState = () => {
		const conversation = store.getConv(page.projection, direct.key);
		return conversation?.type === "dm" ? conversation.line : null;
	};
	assertEquals(direct.line, "introducing");

	projection.line({
		source: "mixed-lines",
		sequence: 1,
		conversationId: "alice-bob",
		from: "bob",
		text: "first",
		at: 1,
		lineId: 1,
		change: "said",
		editable: true,
		system: false,
		history: { source: "archive", generation: "direct-generation", id: "1" },
		previewUrls: [],
		attachments: [],
	});
	projection.line({
		source: "mixed-lines",
		sequence: 2,
		conversationId: "alice-bob",
		from: "bob",
		text: "second",
		at: 2,
		lineId: 2,
		change: "said",
		editable: true,
		system: false,
		history: { source: "archive", generation: "direct-generation", id: "2" },
		previewUrls: [],
		attachments: [],
	});
	assertEquals(lineState(), "live");
	assertEquals(
		store.historyOf(page.projection, direct.key).map((item) => item.kind === "chat" ? item.text : ""),
		[
			"first",
			"second",
		],
	);
	assertEquals(store.unreadOf(page.projection, direct.key).kind, "unread");

	projection.apply(roomsSessionSnapshot({
		revision: 1,
		checkpoint,
		issues: [],
		connectedDirectories: ["directory"],
	}));
	assertEquals(lineState(), "live");

	projection.line({
		source: "mixed-lines",
		sequence: 3,
		conversationId: "alice-bob",
		from: "bob",
		text: "first edited",
		at: 3,
		lineId: 1,
		change: "edited",
		editable: true,
		system: false,
		history: { source: "archive", generation: "direct-generation", id: "1" },
		previewUrls: [],
		attachments: [],
	});
	projection.line({
		source: "mixed-lines",
		sequence: 4,
		conversationId: "alice-bob",
		from: "bob",
		text: "",
		at: 4,
		lineId: 2,
		change: "withdrawn",
		editable: false,
		system: false,
		history: { source: "archive", generation: "direct-generation", id: "2" },
		previewUrls: [],
		attachments: [],
	});
	const lines = store.historyOf(page.projection, direct.key).filter((item) => item.kind === "chat");
	assertEquals(lines.map((item) => item.kind === "chat" ? item.text : ""), ["first edited", "second"]);
	assertEquals(lines.map((item) => item.kind === "chat" ? item.withdrawn === true : false), [false, true]);

	const beforeTyping = store.getConv(page.projection, direct.key);
	projection.line({
		source: "mixed-lines",
		sequence: 5,
		conversationId: "alice-bob",
		from: "bob",
		text: "",
		at: 5,
		lineId: null,
		change: null,
		editable: false,
		system: true,
		presence: { kind: "typing", name: "bob", on: true },
		history: null,
		previewUrls: [],
		attachments: [],
	});
	assertEquals([...(store.typersOf(page.projection, direct.key))], ["bob"]);
	assertEquals(store.getConv(page.projection, direct.key), beforeTyping);
	projection.line({
		source: "mixed-lines",
		sequence: 6,
		conversationId: "alice-bob",
		from: "bob",
		text: "",
		at: 6,
		lineId: null,
		change: null,
		editable: false,
		system: true,
		presence: { kind: "typing", name: "bob", on: false },
		history: null,
		previewUrls: [],
		attachments: [],
	});
	assertEquals([...(store.typersOf(page.projection, direct.key))], []);
	assertEquals(store.getConv(page.projection, direct.key), beforeTyping);
});
