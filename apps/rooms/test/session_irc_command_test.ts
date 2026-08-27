import type { Session } from "@pancake/runtime";
import { emptyRoomsSessionState } from "../lib/rooms_state.ts";
import { dispatchRoomsSessionCommand } from "../session/command_dispatch.ts";
import type { DurableRoomsRuntime } from "../session/runtime.ts";
import { DurableRoomsSessionState } from "../session/state.ts";
import { assertEquals } from "./assert.ts";

function deadline<T>(work: Promise<T>): Promise<T> {
	return Promise.race([
		work,
		new Promise<T>((_resolve, reject) => setTimeout(() => reject(new Error("command did not answer")), 100)),
	]);
}

Deno.test("IRC identity commands answer from durable intent without waiting on network realization", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-irc-command-" });
	try {
		const state = await DurableRoomsSessionState.open(directory);
		const room = {
			kind: "room" as const,
			id: "room",
			directory: "ocapn://directory.id",
			name: "bridge",
			held: false,
			standing: null,
			draft: "",
		};
		await state.replace("setup", 0, {
			...emptyRoomsSessionState(),
			directories: [{
				id: "ocapn://directory.id",
				locator: "ocapn://directory.id",
				home: true,
				nick: "ada",
				standing: null,
			}],
			conversations: [room],
		});
		let settledCalls = 0;
		const runtime = {
			settled: () => {
				settledCalls += 1;
				return new Promise<void>(() => {});
			},
		} as unknown as DurableRoomsRuntime;
		const context = { state, runtime, session: {} as Session };
		const connected = dispatchRoomsSessionCommand("admin", [
			"connect-irc",
			1n,
			"connectRoomIrc",
			room.id,
			"ircAda",
			"account",
			"password",
		], context);
		assertEquals(Number(await deadline(Promise.resolve(connected))), 2);
		const intended = state.snapshot().checkpoint.conversations[0];
		assertEquals(intended.kind === "room" ? intended.irc : null, {
			nick: "ircAda",
			account: "account",
			password: "password",
		});

		const disconnected = dispatchRoomsSessionCommand("admin", [
			"disconnect-irc",
			2n,
			"disconnectRoomIrc",
			room.id,
		], context);
		assertEquals(Number(await deadline(Promise.resolve(disconnected))), 3);
		const roomsOnly = state.snapshot().checkpoint.conversations[0];
		assertEquals(roomsOnly.kind === "room" ? roomsOnly.irc : undefined, null);
		assertEquals(settledCalls, 0);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});
