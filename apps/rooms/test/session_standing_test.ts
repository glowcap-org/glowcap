import { emptyRoomsSessionState, type RoomsSessionState } from "../lib/rooms_state.ts";
import type { Room } from "../lib/room_client.ts";
import type { LiveDirectory, LiveRoom } from "../session/live.ts";
import { reconcileRoomStanding } from "../session/standing.ts";
import { assertEquals } from "./assert.ts";

function checkpoint(
	standing: string,
	directoryStanding: string | null,
	roomStanding: string | null,
): RoomsSessionState {
	const directory = "ocapn://127.0.0.1%3A1.tcp";
	return {
		...emptyRoomsSessionState(),
		standing,
		directories: [{ id: directory, locator: "127.0.0.1:1", home: true, nick: "ada", standing: directoryStanding }],
		conversations: [{
			kind: "room",
			id: "general",
			directory,
			name: "general",
			held: false,
			standing: roomStanding,
			draft: "",
		}],
	};
}

function liveDirectory(away: (standing: string) => Promise<void>): LiveDirectory {
	const room = { away } as unknown as Room;
	const live = { room, standing: null } as LiveRoom;
	return {
		roomRealization: { rooms: new Map([["general", live]]) },
	} as unknown as LiveDirectory;
}

Deno.test("shared standing applies its room, directory, and workspace precedence once", async () => {
	const seen: string[] = [];
	const directory = liveDirectory((standing) => {
		seen.push(standing);
		return Promise.resolve();
	});
	const directories = new Map([["ocapn://127.0.0.1%3A1.tcp", directory]]);
	const issues = new Map<string, unknown>();
	const setIssue = (subject: string, error: unknown | null) => {
		if (error == null) issues.delete(subject);
		else issues.set(subject, error);
		return true;
	};

	await reconcileRoomStanding(checkpoint("away", null, null), directories, setIssue, issues.keys());
	await reconcileRoomStanding(checkpoint("away", null, null), directories, setIssue, issues.keys());
	await reconcileRoomStanding(checkpoint("away", "busy", null), directories, setIssue, issues.keys());
	await reconcileRoomStanding(checkpoint("away", "busy", "focused"), directories, setIssue, issues.keys());
	assertEquals(seen, ["away", "busy", "focused"]);
});

Deno.test("one refused standing update does not block another room and remains retryable", async () => {
	const state = checkpoint("away", null, null);
	state.conversations.push({
		kind: "room",
		id: "second",
		directory: state.directories[0].id,
		name: "second",
		held: false,
		standing: null,
		draft: "",
	});
	const calls: string[] = [];
	const first = { room: { away: () => Promise.reject(new Error("refused")) }, standing: null } as unknown as LiveRoom;
	const second = {
		room: {
			away: (standing: string) => {
				calls.push(standing);
				return Promise.resolve();
			},
		},
		standing: null,
	} as unknown as LiveRoom;
	const directory = {
		roomRealization: { rooms: new Map([["general", first], ["second", second]]) },
	} as unknown as LiveDirectory;
	const issues = new Map<string, unknown>();
	await reconcileRoomStanding(
		state,
		new Map([[state.directories[0].id, directory]]),
		(subject, error) => {
			if (error == null) issues.delete(subject);
			else issues.set(subject, error);
			return true;
		},
		issues.keys(),
	);
	assertEquals(calls, ["away"]);
	assertEquals([...issues.keys()], [`standing:${state.directories[0].id}:general`]);
});
