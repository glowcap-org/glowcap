import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { applyRoomsSessionCommand } from "../../session/commands.ts";
import { reconcileRuntimeState } from "../../session/state_sync.ts";
import { assertEquals } from "../assert.ts";
import { fixtureSturdyref } from "../support/workspace.ts";
import { registrationId } from "../support/registration.ts";

Deno.test("opening conversations commits navigation and public join defaults atomically", () => {
	const home = {
		id: "ocapn://127.0.0.1%3A1.tcp",
		locator: "127.0.0.1:1",
		home: true,
		nick: "ada",
		standing: null,
	};
	const foreign = {
		id: "ocapn://127.0.0.1%3A2.tcp",
		locator: "127.0.0.1:2",
		home: false,
		nick: "ada-elsewhere",
		standing: null,
	};
	let state = applyRoomsSessionCommand(emptyRoomsSessionState(), "joinRoom", [JSON.stringify({
		locator: home.locator,
		nick: home.nick,
		conversation: {
			kind: "room",
			id: "home-room",
			directory: home.id,
			name: "general",
			held: false,
			standing: null,
			draft: "",
		},
	})]);
	assertEquals(state.directories, [home]);
	assertEquals(state.active, "home-room");
	assertEquals(state.join, { room: "general", locator: "", nick: home.nick });
	state = applyRoomsSessionCommand(state, "joinRoom", [JSON.stringify({
		locator: foreign.locator,
		nick: foreign.nick,
		conversation: {
			kind: "room",
			id: "foreign-room",
			directory: foreign.id,
			name: "elsewhere",
			held: false,
			standing: null,
			draft: "",
		},
	})]);
	assertEquals(state.active, "foreign-room");
	assertEquals(state.join, { room: "elsewhere", locator: foreign.locator, nick: foreign.nick });
	state = applyRoomsSessionCommand(state, "joinRoom", [JSON.stringify({
		locator: foreign.locator,
		nick: foreign.nick,
		conversation: {
			kind: "room",
			id: "duplicate-attempt",
			directory: foreign.id,
			name: "ELSEWHERE",
			held: false,
			standing: null,
			draft: "",
		},
	})]);
	assertEquals(state.active, "foreign-room");
	assertEquals(state.conversations.length, 2);

	state = applyRoomsSessionCommand(state, "joinRoom", [JSON.stringify({
		locator: home.locator,
		nick: home.nick,
		conversation: {
			kind: "room",
			id: "held-room",
			directory: home.id,
			name: "private label",
			held: true,
			link: fixtureSturdyref("ocapn://127.0.0.1%3A1.tcp", "private"),
			standing: null,
			draft: "",
		},
	})]);
	assertEquals(state.active, "held-room");
	assertEquals(state.join, { room: "elsewhere", locator: foreign.locator, nick: foreign.nick });

	state = applyRoomsSessionCommand(state, "startDirect", [JSON.stringify({
		kind: "direct",
		id: "background-direct",
		directory: home.id,
		peer: "bo",
		peerRegistrationId: registrationId(1),
		closed: false,
		draft: "",
	})]);
	assertEquals(state.active, "held-room");
	state = applyRoomsSessionCommand(state, "openDirect", [JSON.stringify({
		kind: "direct",
		id: "opened-direct",
		directory: home.id,
		peer: "cy",
		peerRegistrationId: registrationId(2),
		closed: false,
		draft: "",
	})]);
	assertEquals(state.active, "opened-direct");
	let mismatch = "";
	try {
		applyRoomsSessionCommand(state, "joinRoom", [JSON.stringify({
			kind: "room",
			id: "old-client-room",
			directory: home.id,
			name: "old shape",
			held: false,
			standing: null,
			draft: "",
		})]);
	} catch (error) {
		mismatch = error instanceof Error ? error.message : String(error);
	}
	assertEquals(mismatch.includes("client and session may be from different builds"), true);
});

Deno.test("a shared join records the session-owned publication identity", () => {
	const directory = "ocapn://127.0.0.1%3A1.tcp";
	const joined = applyRoomsSessionCommand(
		emptyRoomsSessionState(),
		"joinRoom",
		[JSON.stringify({
			locator: "127.0.0.1:1",
			nick: "ada",
			conversation: {
				kind: "room",
				id: "bridge-room",
				directory,
				name: "network/#channel",
				held: false,
				standing: null,
				draft: "",
			},
		})],
		{ roomPublicationId: () => "bridge-generation" },
	);
	const room = joined.conversations[0];
	assertEquals(room.kind === "room" ? room.publicationId : null, "bridge-generation");
});

Deno.test("explicit room recovery stays pending until its live result is known", () => {
	const directory = {
		id: "ocapn://127.0.0.1%3A1.tcp",
		locator: "127.0.0.1:1",
		home: true,
		nick: "ada",
		standing: null,
	};
	const publicRoom = {
		kind: "room" as const,
		id: "public-room",
		directory: directory.id,
		name: "general",
		held: false,
		reconnect: "manual" as const,
		standing: null,
		draft: "",
	};
	const base = { ...emptyRoomsSessionState(), directories: [directory], conversations: [publicRoom] };
	const requested = applyRoomsSessionCommand(base, "joinRoom", [JSON.stringify({
		locator: directory.locator,
		nick: directory.nick,
		conversation: publicRoom,
	})]);
	assertEquals(requested.conversations[0].kind === "room" ? requested.conversations[0].reconnect : null, "requested");
	const failed = reconcileRuntimeState(requested, {
		type: "room-reconnect",
		conversationId: publicRoom.id,
		connected: false,
	});
	assertEquals(failed?.conversations[0].kind === "room" ? failed.conversations[0].reconnect : null, "manual");
	const connected = reconcileRuntimeState(requested, {
		type: "room-reconnect",
		conversationId: publicRoom.id,
		connected: true,
	});
	assertEquals(connected?.conversations[0].kind === "room" ? connected.conversations[0].reconnect : null, undefined);

	const staleBridge = { ...publicRoom, publicationId: "old-bridge-generation" };
	const bridgeBase = { ...base, conversations: [staleBridge] };
	const currentBridge = applyRoomsSessionCommand(bridgeBase, "joinRoom", [JSON.stringify({
		locator: directory.locator,
		nick: directory.nick,
		conversation: staleBridge,
	})], { roomPublicationId: () => "new-bridge-generation" });
	assertEquals(
		currentBridge.conversations[0].kind === "room" ? currentBridge.conversations[0].publicationId : null,
		"new-bridge-generation",
	);
	let missingBridgeRefused = false;
	try {
		applyRoomsSessionCommand(bridgeBase, "joinRoom", [JSON.stringify({
			locator: directory.locator,
			nick: directory.nick,
			conversation: staleBridge,
		})], { roomPublicationId: () => null });
	} catch (error) {
		missingBridgeRefused = error instanceof Error && error.message.includes("no current publication");
	}
	assertEquals(missingBridgeRefused, true);

	const privateRoom = { ...publicRoom, id: "private-room", name: "private", held: true };
	const privateBase = { ...base, conversations: [privateRoom] };
	let refused = false;
	try {
		applyRoomsSessionCommand(privateBase, "joinRoom", [JSON.stringify({
			locator: directory.locator,
			nick: directory.nick,
			conversation: privateRoom,
		})]);
	} catch {
		refused = true;
	}
	assertEquals(refused, true);
	const currentLink = `${directory.id}/s/Y3VycmVudA`;
	const privateRequested = applyRoomsSessionCommand(privateBase, "joinRoom", [JSON.stringify({
		locator: directory.locator,
		nick: directory.nick,
		conversation: { ...privateRoom, link: currentLink },
	})]);
	const recoveredPrivate = privateRequested.conversations[0];
	assertEquals(recoveredPrivate.kind === "room" ? recoveredPrivate.reconnect : null, "requested");
	assertEquals(recoveredPrivate.kind === "room" ? recoveredPrivate.link : null, currentLink);
});
