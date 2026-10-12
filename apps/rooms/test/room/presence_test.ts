// Room presence describes current membership, not a history of departed names.
import { assertEquals } from "../assert.ts";
import { applyRoomPresence, type RoomMemberState } from "../../lib/room/presence.ts";
import { readPresence } from "../../lib/room/message.ts";
import { MAX_ROOM_OFFLINE } from "../../lib/limits.ts";

Deno.test("leaving removes only that room membership and a rejoin starts fresh", () => {
	const current = new Map<string, RoomMemberState>([
		["ada", { online: true, away: "lunch" }],
		["bo", { online: true, away: "" }],
	]);
	const left = applyRoomPresence(current, { kind: "leave", name: "ada" });
	assertEquals([...left.keys()], ["bo"]);
	assertEquals([...current.keys()], ["ada", "bo"], "other projections retain their own membership");
	assertEquals([...applyRoomPresence(left, { kind: "leave", name: "unknown" })], [...left]);
	assertEquals(applyRoomPresence(left, { kind: "join", name: "ada" }).get("ada"), { online: true, away: "" });
});

Deno.test("connection loss retains offline rows and a return replaces them", () => {
	const current = new Map<string, RoomMemberState>([
		["ada", { online: true, away: "" }],
		["bo", { online: true, away: "lunch" }],
	]);
	const event = readPresence(["room", "bo went offline", "offline", "bo", "cy"]);
	assertEquals(event, { kind: "offline", names: ["bo", "cy"] });
	if (event === undefined) throw new Error("offline metadata was lost");
	const offline = applyRoomPresence(current, event);
	assertEquals([...offline], [["ada", { online: true, away: "" }], ["bo", { online: false, away: "" }], ["cy", {
		online: false,
		away: "",
	}]]);
	assertEquals(applyRoomPresence(offline, { kind: "join", name: "bo" }).get("bo"), { online: true, away: "" });
	const away = applyRoomPresence(offline, { kind: "away", name: "bo", reason: "late" });
	const seated = applyRoomPresence(away, {
		kind: "seat",
		name: "bo",
		state: "linked",
		nick: "bo_irc",
		network: "Libera",
		badge: "IRC",
		said: "Linked",
	});
	assertEquals(seated.get("bo"), { online: false, away: "" }, "late details cannot restore live membership");
	assertEquals(applyRoomPresence(offline, { kind: "leave", name: "bo" }).has("bo"), false);
	assertEquals(readPresence(["room", "", "offline", ""]), undefined);
	assertEquals(readPresence(["room", "", "offline", ...Array(MAX_ROOM_OFFLINE + 1).fill("bo")]), undefined);
});

Deno.test("a roster removes absent names, preserves current away state and resets bridge seats", () => {
	const current = new Map<string, RoomMemberState>([
		["ada", { online: true, away: "lunch" }],
		["bo", {
			online: true,
			away: "reading",
			seat: { state: "linked", nick: "bo_irc", network: "Libera", badge: "IRC", said: "Linked" },
		}],
	]);
	const roster = applyRoomPresence(current, { kind: "roster", names: ["bo", "cy"] });
	assertEquals([...roster], [["bo", { online: true, away: "reading" }], ["cy", { online: true, away: "" }]]);
	assertEquals([...applyRoomPresence(roster, { kind: "roster", names: [] })], []);
	assertEquals([...applyRoomPresence(roster, { kind: "away", name: "ada", reason: "back" })], [...roster]);
	assertEquals(
		[...applyRoomPresence(roster, {
			kind: "seat",
			name: "ada",
			state: "linked",
			nick: "ada_irc",
			network: "Libera",
			badge: "IRC",
			said: "Linked",
		})],
		[...roster],
		"late bridge updates cannot recreate a departed membership",
	);
});
