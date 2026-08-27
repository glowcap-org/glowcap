import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { applyRoomsSessionCommand } from "../session/commands.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";

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
			link: "ocapn://127.0.0.1%3A1.tcp/s/private",
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
