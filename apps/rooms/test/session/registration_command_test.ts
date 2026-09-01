// A shared session unregisters through its live room manager as one external
// effect. The effect ledger owns ambiguity, while the room view carries the
// resulting private policy without discarding independent authority.

import type { Session } from "@pancake/runtime";
import { formatRoomsSturdyref, roomsLocator } from "../../lib/locator.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { dispatchRoomsSessionCommand } from "../../session/command_dispatch.ts";
import { ResultEffectCoordinator } from "../../session/result_effect.ts";
import type { DurableRoomsRuntime } from "../../session/runtime.ts";
import { assertEquals } from "../assert.ts";
import { openSessionState } from "../support/session_disk.ts";

Deno.test("a durable session unregisters one managed room through the effect ledger", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-registration-" });
	try {
		const state = await openSessionState(directory);
		const directoryId = "ocapn://directory.id";
		await state.replace("setup", 0, {
			...emptyRoomsSessionState(),
			directories: [{
				id: directoryId,
				locator: directoryId,
				home: true,
				nick: "owner",
				standing: null,
			}],
			conversations: [{
				kind: "room",
				id: "managed-room",
				directory: directoryId,
				name: "registered",
				held: false,
				link: formatRoomsSturdyref(roomsLocator(directoryId), "room"),
				manager: formatRoomsSturdyref(roomsLocator(directoryId), "manager"),
				steward: formatRoomsSturdyref(roomsLocator(directoryId), "steward"),
				standing: null,
				draft: "",
			}],
		});
		const calls: string[] = [];
		const runtime = {
			unregisterManagedRoom: (conversationId: string) => {
				calls.push(conversationId);
				return Promise.resolve();
			},
		} as unknown as DurableRoomsRuntime;
		const answer = await Promise.resolve(dispatchRoomsSessionCommand("admin", [
			"unregister-room",
			1n,
			"unregisterManagedRoom",
			"managed-room",
		], { state, runtime, session: {} as Session, resultEffects: new ResultEffectCoordinator() }));
		assertEquals(Number(answer), 1);
		assertEquals(calls, ["managed-room"]);
		assertEquals(state.pendingEffectIds(), []);
	} finally {
		await Deno.remove(directory, { recursive: true });
	}
});
