// Room presence describes current membership, not a history of departed names.
import { assertEquals } from "../assert.ts";
import { applyRoomPresence, type Presence, type RoomMemberState } from "../../lib/room/presence.ts";
import { readPresence } from "../../lib/room/message.ts";
import { MAX_PROFILE_BATCH, MAX_ROOM_OFFLINE } from "../../lib/limits.ts";

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

Deno.test("a member profile belongs to the current seat and room", () => {
	const joined = applyRoomPresence(new Map(), { kind: "join", name: "scout" });
	const notice = readPresence(["room", "", "profile", "scout", "assisted", "Review notes"]);
	if (!notice || notice.kind !== "profile") throw new Error("missing profile");
	const published = applyRoomPresence(joined, notice);
	assertEquals(published.get("scout")?.profile, { kind: "assisted", about: "Review notes" });
	assertEquals(joined.get("scout")?.profile, undefined);
	const resets: Presence[] = [
		{ kind: "join", name: "scout" },
		{ kind: "roster", names: ["scout"] },
		{ kind: "offline", names: ["scout"] },
		{ ...notice, memberKind: "", about: "" },
	];
	for (const event of resets) {
		assertEquals(applyRoomPresence(published, event).get("scout")?.profile, undefined);
	}
	const left = applyRoomPresence(published, { kind: "leave", name: "scout" });
	assertEquals(applyRoomPresence(left, notice).has("scout"), false);
	for (
		const fields of [
			["scout", "", "profile", "scout", "bot", "Reviews"],
			["room", "unrelated text", "profile", "scout", "bot", ""],
			["room", "", "profile", "scout", "verified", ""],
			["room", "", "profile", "scout", "person", "two\nlines"],
			["room", "", "profile", "scout", "bot", "x".repeat(121)],
			["room", "", "profile", "scout", "bot", "\ud800"],
		]
	) assertEquals(readPresence(fields), undefined);
});

Deno.test("a profile batch applies atomically to current seats within the replay bound", () => {
	const names = Array.from({ length: MAX_PROFILE_BATCH }, (_, i) => "member" + i);
	const triples = names.flatMap((name) => [name, "bot", "Research"]);
	const head = ["room", "", "profiles"];
	const event = readPresence([...head, ...triples]);
	if (event?.kind !== "profiles") throw new Error("valid replay was refused");
	const current = applyRoomPresence(new Map(), { kind: "roster", names: names.slice(1) });
	const updated = applyRoomPresence(current, event);
	assertEquals(updated.has(names[0]), false);
	assertEquals(updated.get(names.at(-1)!)?.profile, { kind: "bot", about: "Research" });
	for (
		const tail of [[], ["a", "bot"], ["a", "", ""], ["a", "bot", "", "A", "person", ""], [
			...triples,
			"more",
			"bot",
			"",
		], ["a", "bot", "", "b", "invalid", ""]]
	) {
		assertEquals(readPresence([...head, ...tail]), undefined);
	}
});
