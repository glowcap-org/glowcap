// The roster reads you first, then who is here, then each group by name in the reader's own
// collation. The collation is the runtime's default, so a name whose place depends on the locale
// (an accented capital sorts after `z` in some Nordic ones) is checked pairwise against that same
// collator. The fixed example uses only names whose order no locale contests.
/// <reference lib="dom" />
import "../support/match_media.ts";
import "../support/browser_application.ts";
import { assert, assertEquals } from "../assert.ts";
import type { RoomMemberState } from "../../lib/room/presence.ts";

const { rosterOf } = await import("../../web/ui/panes/Members.tsx");

function roster(names: readonly string[], offline: readonly string[] = []): Map<string, RoomMemberState> {
	const members = new Map<string, RoomMemberState>();
	for (const name of names) members.set(name, { online: !offline.includes(name), away: "" });
	return members;
}

Deno.test("the reader is first, then who is here, each group in collator order", () => {
	const names = [
		"bob",
		"Bob",
		"alice",
		"Émile",
		"emile",
		"zed",
		"Zed",
		"a10",
		"a2",
		"a1",
		"Ångström",
		"carol",
		"mia",
	];
	const offline = ["Zed", "alice"];
	const ordered = rosterOf(roster(names, offline), "carol").rows.map(([name]) => name);
	assertEquals(ordered.length, names.length);
	assertEquals(ordered[0], "carol");
	assertEquals(ordered.slice(-2).sort(), [...offline].sort());
	const collator = new Intl.Collator();
	const here = ordered.slice(1, -2);
	for (let at = 1; at < here.length; at++) {
		assert(collator.compare(here[at - 1], here[at]) <= 0, `${here[at - 1]} was listed before ${here[at]}`);
	}
	assert(
		collator.compare(ordered[ordered.length - 2], ordered[ordered.length - 1]) <= 0,
		"offline names out of order",
	);
});

Deno.test("names no locale orders differently keep one order", () => {
	const names = ["b2", "Carol", "a10", "a2", "Alice", "a1", "Zed", "c", "me"];
	const { rows } = rosterOf(roster(names, ["c"]), "me");
	assertEquals(rows.map(([name]) => name), ["me", "a1", "a10", "a2", "Alice", "b2", "Carol", "Zed", "c"]);
});

Deno.test("the reader leads even when offline, and the order does not depend on arrival", () => {
	const names = ["b", "A", "c", "a", "B"];
	const forward = rosterOf(roster(names, ["c"]), "c").rows.map(([name]) => name);
	const backward = rosterOf(roster([...names].reverse(), ["c"]), "c").rows.map(([name]) => name);
	assertEquals(forward[0], "c");
	assertEquals(forward, backward);
});
