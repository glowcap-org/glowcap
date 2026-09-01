import type { Session } from "@pancake/runtime";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { dispatchRoomsSessionCommand } from "../../session/command_dispatch.ts";
import type { DurableRoomsRuntime } from "../../session/runtime.ts";
import { ResultEffectCoordinator } from "../../session/result_effect.ts";
import { assertEquals } from "../assert.ts";
import { ROOM_RETIRED, RoomError } from "../../lib/errors.ts";
import { RoomBridgeSecrets } from "../../session/bridge_secrets.ts";
import { openSessionState } from "../support/session_disk.ts";

function deadline<T>(work: Promise<T>): Promise<T> {
	return Promise.race([
		work,
		new Promise<T>((_resolve, reject) => setTimeout(() => reject(new Error("command did not answer")), 100)),
	]);
}

Deno.test("bridge secrets follow one directory scope across sibling rooms", () => {
	const secrets = new RoomBridgeSecrets();
	secrets.stage("directory", "Libera", { password: "password" });
	// A scope is matched however the bridge spelled it, because one network is
	// one identity whatever case a room's name arrived in.
	assertEquals(secrets.answers("directory", "libera"), { password: "password" });
	assertEquals(secrets.answers("directory", "LIBERA"), { password: "password" });
	assertEquals(secrets.answers("another-directory", "Libera"), null);
	// Nothing held and nothing to give are different answers: the first means a
	// reader must be asked again, the second that they already said no secret.
	secrets.stage("directory", "Libera", {});
	assertEquals(secrets.answers("directory", "Libera"), null);
	secrets.stage("directory", "Libera", { password: "password" });
	secrets.clear();
	assertEquals(secrets.answers("directory", "Libera"), null);
});

Deno.test("a staged secret is given back only to the command that staged it", () => {
	const secrets = new RoomBridgeSecrets();
	const first = secrets.stage("directory", "Libera", { password: "first" });
	const second = secrets.stage("directory", "Libera", { password: "second" });
	// The older command refusing must not take back what the newer one staged,
	// or the newer submission replays with nothing.
	secrets.discard("directory", "Libera", first!);
	assertEquals(secrets.answers("directory", "Libera"), { password: "second" });
	secrets.discard("directory", "Libera", second!);
	assertEquals(secrets.answers("directory", "Libera"), null);
});

Deno.test("IRC identity commands answer from durable intent without waiting on network realization", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-irc-command-" });
	try {
		const state = await openSessionState(directory);
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
		const staged: unknown[] = [];
		const discarded: unknown[] = [];
		const runtime = {
			bridgeSecrets: {
				stage: (...args: unknown[]) => {
					staged.push(args);
					return Symbol("credential");
				},
				discard: (...args: unknown[]) => discarded.push(args),
			},
			settled: () => {
				settledCalls += 1;
				return new Promise<void>(() => {});
			},
		} as unknown as DurableRoomsRuntime;
		const context = { state, runtime, session: {} as Session, resultEffects: new ResultEffectCoordinator() };
		const submit = (id: string, at: bigint, action: string, answers: unknown, secrets: unknown) =>
			dispatchRoomsSessionCommand("admin", [
				id,
				at,
				"submitRoomBridgeForm",
				room.id,
				"Libera",
				action,
				JSON.stringify(answers),
				JSON.stringify(secrets),
			], context);

		const connected = submit("link-irc", 1n, "link", { nick: "ircAda", account: "account" }, {
			password: "hunter2",
		});
		assertEquals(Number(await deadline(Promise.resolve(connected))), 2);
		const intended = state.snapshot().checkpoint.conversations[0];
		assertEquals(intended.kind === "room" ? intended.bridgeIntent : null, {
			scope: "Libera",
			action: "link",
			answers: { nick: "ircAda", account: "account" },
			// Recorded rather than the secret itself, so a reconnect can tell "no
			// secret was needed" from "the password is gone and must be asked for".
			secretsGiven: true,
		});
		assertEquals(staged, [[room.directory, "Libera", { password: "hunter2" }]]);
		const persisted = await Deno.readTextFile(`${directory}/session.json`);
		assertEquals(persisted.includes("hunter2"), false, "a secret answer reached the checkpoint");
		let refused = false;
		try {
			await Promise.resolve(submit("stale-irc", 0n, "link", { nick: "ircAda" }, { password: "later" }));
		} catch {
			refused = true;
		}
		assertEquals(refused, true);
		assertEquals(discarded.length, 1);

		const disconnected = submit("disconnect-irc", 2n, "disconnect", {}, {});
		assertEquals(Number(await deadline(Promise.resolve(disconnected))), 3);
		// Staying Rooms-only is a choice a reader made, so it is remembered as
		// one. Clearing the intent instead would let a reconnect put them back on
		// IRC against it.
		const roomsOnly = state.snapshot().checkpoint.conversations[0];
		assertEquals(roomsOnly.kind === "room" ? roomsOnly.bridgeIntent : null, {
			scope: "Libera",
			action: "disconnect",
			answers: {},
			secretsGiven: false,
		});
		assertEquals(settledCalls, 0);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});

Deno.test("a send to a parted IRC room is abandoned as definitively unsent", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-parted-send-" });
	try {
		const state = await openSessionState(directory);
		const room = {
			kind: "room" as const,
			id: "bridge-room",
			directory: "ocapn://directory.id",
			name: "Libera/#room",
			held: false,
			publicationId: "retired-generation",
			standing: null,
			draft: "",
		};
		await state.replace("setup", 0, {
			...emptyRoomsSessionState(),
			directories: [{
				id: room.directory,
				locator: room.directory,
				home: true,
				nick: "ada",
				standing: null,
			}],
			conversations: [room],
		});
		const runtime = {
			requireConversation: () => {},
			say: () => Promise.reject(new RoomError(ROOM_RETIRED, "this IRC bridge has been parted")),
		} as unknown as DurableRoomsRuntime;
		let refusal = "";
		try {
			await Promise.resolve(dispatchRoomsSessionCommand("admin", [
				"parted-send",
				1n,
				"say",
				room.id,
				"hello?",
			], { state, runtime, session: {} as Session, resultEffects: new ResultEffectCoordinator() }));
		} catch (error) {
			refusal = error instanceof Error ? error.message : String(error);
		}
		assertEquals(refusal, "This room publication was retired. Reopen the current room before sending again.");
		assertEquals(state.pendingEffectIds(), []);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});
