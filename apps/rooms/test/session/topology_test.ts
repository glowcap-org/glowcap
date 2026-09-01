import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { roomsSessionCommandImpact } from "../../session/commands.ts";
import { DurableRoomsOperations } from "../../session/operations.ts";
import { roomsDirectoryTopology, roomsSessionTopology } from "../../session/topology.ts";
import { assertEquals } from "../assert.ts";
import { registrationId } from "../support/registration.ts";

Deno.test("view and storage mutations do not change live Rooms topology", () => {
	assertEquals(roomsSessionCommandImpact("setDraft"), "presentation");
	assertEquals(roomsSessionCommandImpact("setRoomStanding"), "standing");
	assertEquals(roomsSessionCommandImpact("joinRoom"), "realization");
	const base = {
		...emptyRoomsSessionState(),
		directories: [{
			id: "ocapn://127.0.0.1%3A1.tcp",
			locator: "127.0.0.1:1",
			home: true,
			nick: "ada",
			standing: null,
		}],
		conversations: [{
			kind: "room" as const,
			id: "room-id",
			directory: "ocapn://127.0.0.1%3A1.tcp",
			name: "general",
			held: false,
			standing: null,
			draft: "",
		}],
	};
	assertEquals(roomsSessionTopology({ ...base, standing: "away" }), roomsSessionTopology(base));
	assertEquals(
		roomsSessionTopology({ ...base, conversations: [{ ...base.conversations[0], draft: "half written" }] }),
		roomsSessionTopology(base),
	);
	assertEquals(
		roomsSessionTopology({
			...base,
			conversations: [{
				...base.conversations[0],
				bridgeIntent: { scope: "Libera", action: "link", answers: { nick: "ada_irc" }, secretsGiven: false },
			}],
		}),
		roomsSessionTopology(base),
	);
	assertEquals(
		roomsSessionTopology({ ...base, directories: [{ ...base.directories[0], nick: "bo" }] }) ===
			roomsSessionTopology(base),
		false,
	);
	assertEquals(
		roomsSessionTopology({
			...base,
			conversations: [{ ...base.conversations[0], steward: "ocapn://directory.iroh/s/steward" }],
		}) === roomsSessionTopology(base),
		true,
	);
	const direct = {
		kind: "direct" as const,
		id: "direct-id",
		directory: base.directories[0].id,
		peer: "bo",
		peerRegistrationId: registrationId(1),
		closed: false,
		draft: "",
	};
	const withDirect = { ...base, conversations: [...base.conversations, direct] };
	assertEquals(
		roomsSessionTopology({
			...withDirect,
			conversations: [...base.conversations, { ...direct, draft: "still presentation state" }],
		}),
		roomsSessionTopology(withDirect),
	);
	assertEquals(
		roomsSessionTopology({
			...withDirect,
			conversations: [...base.conversations, { ...direct, peer: "charles" }],
		}) === roomsSessionTopology(withDirect),
		false,
	);
	assertEquals(
		roomsSessionTopology({
			...withDirect,
			conversations: [...base.conversations, { ...direct, closed: true }],
		}) === roomsSessionTopology(withDirect),
		false,
	);
	assertEquals(
		roomsSessionTopology({
			...base,
			capabilities: {
				...base.capabilities,
				operations: [{ capability: "diagnostics", scope: base.directories[0].id, swiss: "a".repeat(64) }],
			},
		}) === roomsSessionTopology(base),
		false,
	);
});

Deno.test("shared operation domains state their mutation owner", () => {
	const operations = new DurableRoomsOperations(() => false, () => {});
	let reason = "";
	try {
		operations.operationEffect("directory", "diagnostics", "clear", []);
	} catch (error) {
		reason = error instanceof Error ? error.message : String(error);
	}
	assertEquals(reason.includes("inspect-only"), true);
	try {
		operations.operationEffect("directory", "peering", "publish", []);
	} catch (error) {
		reason = error instanceof Error ? error.message : String(error);
	}
	assertEquals(reason.includes("durable publication intents"), true);
});

Deno.test("durable Rooms reconciliation scopes topology changes to their directory", () => {
	const first = { id: "ocapn://127.0.0.1%3A1.tcp", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null };
	const second = {
		id: "ocapn://127.0.0.1%3A2.tcp",
		locator: "127.0.0.1:2",
		home: false,
		nick: "ada",
		standing: null,
	};
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [first, second],
		conversations: [
			{
				kind: "room" as const,
				id: "first-room",
				directory: first.id,
				name: "general",
				held: false,
				standing: null,
				draft: "",
			},
			{
				kind: "room" as const,
				id: "second-room",
				directory: second.id,
				name: "elsewhere",
				held: false,
				standing: null,
				draft: "",
			},
		],
	};
	const firstBefore = roomsDirectoryTopology(first, checkpoint.conversations);
	const secondBefore = roomsDirectoryTopology(second, checkpoint.conversations);
	const renamed = { ...first, nick: "grace" };
	assertEquals(roomsDirectoryTopology(renamed, checkpoint.conversations) === firstBefore, false);
	assertEquals(roomsDirectoryTopology(second, checkpoint.conversations), secondBefore);
	const drafted = checkpoint.conversations.map((conversation) =>
		conversation.id === "first-room" ? { ...conversation, draft: "not a network change" } : conversation
	);
	assertEquals(roomsDirectoryTopology(first, drafted), firstBefore);
	assertEquals(roomsDirectoryTopology(second, drafted), secondBefore);
});
