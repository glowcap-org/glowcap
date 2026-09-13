// A durable-session snapshot bounds each room's membership independently.

import { MAX_ROSTER_SEEN } from "../../lib/limits.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { parseRoomsSessionSnapshot } from "../../lib/session/messages.ts";
import { assert, assertEquals } from "../assert.ts";

function room(conversationId: string, memberCount: number) {
	return {
		conversationId,
		membershipKind: "participant",
		policy: { visibility: "listed", entry: "open", speaking: "open" },
		members: Array.from(
			{ length: memberCount },
			(_, index) => [`member-${index}`, { online: true, away: "" }],
		),
		topic: null,
		lineBytes: null,
	};
}

function snapshot(roomViews: unknown[]): unknown[] {
	return [
		0n,
		JSON.stringify(emptyRoomsSessionState()),
		[],
		[],
		[],
		[],
		null,
		JSON.stringify(roomViews),
		"[]",
		"[]",
		JSON.stringify({ version: 1, rights: "admin", workspaceAdoption: "closed", grants: [] }),
		"[]",
	];
}

Deno.test("snapshot membership limits apply to each room", () => {
	const parsed = parseRoomsSessionSnapshot(snapshot([
		room("first", MAX_ROSTER_SEEN),
		room("second", MAX_ROSTER_SEEN),
	]));
	assertEquals(
		parsed.roomViews.map((view) => view.members.length),
		[MAX_ROSTER_SEEN, MAX_ROSTER_SEEN],
		"two valid rooms",
	);

	let refused = false;
	try {
		parseRoomsSessionSnapshot(snapshot([room("oversized", MAX_ROSTER_SEEN + 1)]));
	} catch {
		refused = true;
	}
	assert(refused, "one oversized room was accepted");
});
