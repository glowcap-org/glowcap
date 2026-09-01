// Durable-session checkpoint ownership for room links and moderator authority.

import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { formatRoomsSturdyref, roomsLocator } from "../../lib/locator.ts";
import { roomAuthorityToken } from "../../lib/room/authority.ts";
import { applyRoomsSessionCommand } from "../../session/commands.ts";
import {
	applyRoomsSessionResult,
	prepareRoomsSessionResult,
	resumeRoomsSessionResult,
} from "../../session/result_commands.ts";
import { assertEquals } from "../assert.ts";

function syncRefused(work: () => unknown): boolean {
	try {
		work();
		return false;
	} catch {
		return true;
	}
}

Deno.test("room links and moderator authorities apply to the exact conversation", () => {
	const directory = {
		id: "ocapn://127.0.0.1%3A1.tcp",
		locator: "127.0.0.1:1",
		home: true,
		nick: "ada",
		standing: null,
	};
	const room = {
		kind: "room" as const,
		id: "room-1",
		directory: directory.id,
		name: "plans",
		held: true,
		standing: null,
		draft: "draft",
	};
	const initial = { ...emptyRoomsSessionState(), directories: [directory], conversations: [room] };
	const roomLink = formatRoomsSturdyref(roomsLocator(directory.locator), "room-link");
	const linkPlan = prepareRoomsSessionResult(initial, "ensureRoomLink", [room.id]);
	assertEquals(linkPlan.kind, "room-link");
	let linked = applyRoomsSessionResult(
		initial,
		linkPlan.kind,
		linkPlan.intent,
		JSON.stringify({ roomLink }),
	);
	const suppliedModerator = formatRoomsSturdyref(roomsLocator(directory.locator), "supplied-room-moderator");
	const moderatorPlan = prepareRoomsSessionResult(linked, "takeRoomModerator", [room.id, suppliedModerator]);
	assertEquals(moderatorPlan.kind, "room-steward");
	assertEquals(moderatorPlan.stewardLink, suppliedModerator);
	assertEquals(
		syncRefused(() =>
			applyRoomsSessionResult(
				linked,
				moderatorPlan.kind,
				moderatorPlan.intent,
				JSON.stringify({
					roomLink,
					stewardLink: formatRoomsSturdyref(roomsLocator(directory.locator), "a-different-room-moderator"),
				}),
			)
		),
		true,
	);
	linked = applyRoomsSessionResult(
		linked,
		moderatorPlan.kind,
		moderatorPlan.intent,
		JSON.stringify({ roomLink, stewardLink: suppliedModerator }),
	);
	const saved = linked.conversations[0];
	assertEquals(saved.kind === "room" ? saved.link : null, roomLink);
	assertEquals(saved.kind === "room" ? saved.steward : null, suppliedModerator);
	const moderatorToken = roomAuthorityToken(suppliedModerator);
	const dropped = applyRoomsSessionCommand(linked, "dropRoomModerator", [room.id, moderatorToken]);
	const afterDrop = dropped.conversations[0];
	assertEquals(afterDrop.kind === "room" ? afterDrop.link : null, roomLink);
	assertEquals(afterDrop.kind === "room" ? afterDrop.steward : null, undefined);
	assertEquals(
		syncRefused(() => applyRoomsSessionCommand(dropped, "dropRoomModerator", [room.id, moderatorToken])),
		true,
	);
	assertEquals(
		syncRefused(() => applyRoomsSessionCommand(linked, "dropRoomModerator", [room.id, "older-generation"])),
		true,
	);
	assertEquals(
		syncRefused(() => applyRoomsSessionCommand(linked, "dropRoomModerator", ["another-room", moderatorToken])),
		true,
	);
	const resumed = resumeRoomsSessionResult(linked, moderatorPlan.kind, moderatorPlan.intent);
	assertEquals(resumed.kind, "room-steward");

	const managerLink = formatRoomsSturdyref(roomsLocator(directory.locator), "room-manager");
	const recoveredManager = prepareRoomsSessionResult(dropped, "recoverRoomManager", [room.id]);
	assertEquals(recoveredManager.kind, "room-manager");
	assertEquals(recoveredManager.managerLink, undefined);
	const managed = applyRoomsSessionResult(
		dropped,
		recoveredManager.kind,
		recoveredManager.intent,
		JSON.stringify({ roomLink, managerLink }),
	);
	assertEquals(managed.conversations[0]?.kind === "room" && managed.conversations[0].manager, managerLink);
	const resumedRecovery = resumeRoomsSessionResult(managed, recoveredManager.kind, recoveredManager.intent);
	assertEquals(resumedRecovery.kind, "room-manager");
	assertEquals(resumedRecovery.managerLink, undefined);
	const explicitTake = prepareRoomsSessionResult(dropped, "takeRoomManager", [room.id, managerLink]);
	assertEquals(explicitTake.kind, "room-manager");
	assertEquals(explicitTake.managerLink, managerLink);
});
