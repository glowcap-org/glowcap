// Member identity is one projection across avatars and the roster: IRC-only
// names are attributed without becoming a second linked-person row, and a
// Rooms member's IRC seat keeps both network and presence facts visible.

import { assertEquals } from "./assert.ts";
import { hueOf, initials, ircName, memberDetail, memberIdentity } from "../web/ui/member_identity.ts";

Deno.test("initials take the first letter of up to two words", () => {
	assertEquals(initials("alice"), "A");
	assertEquals(initials("alice liddell"), "AL");
	assertEquals(initials("mary_jane-watson"), "MJ");
});

Deno.test("initials survive names outside the basic plane whole", () => {
	// The nick rule admits letters of every script, and an astral-plane letter
	// is two UTF-16 code units. Half of one is replacement-character garbage.
	assertEquals(initials("\u{10437}ee"), "\u{1040F}"); // Deseret yee, uppercased whole
	assertEquals(initials("\u{1D541}im"), "\u{1D541}"); // mathematical double-struck J
	assertEquals(initials("alice").includes("�"), false);
});

Deno.test("initials answer something for a name that is all symbols", () => {
	assertEquals(initials("!!!"), "?");
});

Deno.test("a name keeps one tint and the tint is a ramp slot", () => {
	assertEquals(hueOf("alice"), hueOf("alice"));
	assertEquals(/^var\(--avatar-([1-9]|10)\)$/.test(hueOf("alice")), true);
	assertEquals(/^var\(--avatar-([1-9]|10)\)$/.test(hueOf("bob")), true);
});

Deno.test("a bridged identity is named bare, marked as IRC, and keeps a person's tint", () => {
	assertEquals(ircName("irc/alice"), "alice");
	assertEquals(ircName("alice"), null);
	assertEquals(ircName("irc/"), null);
	assertEquals(ircName("IRC/alice"), null);
	assertEquals(initials("irc/alice"), "A");
	assertEquals(hueOf("irc/alice"), hueOf("alice"));
	assertEquals(hueOf("irc/bob"), hueOf("bob"));
	assertEquals(hueOf("irc/alice") === hueOf("irc/bob"), false);
	assertEquals(hueOf("alice").startsWith("var(--avatar-"), true);
});

Deno.test("a roster distinguishes IRC-only, Rooms-only, linked, and unhealthy bridge seats", () => {
	const present = { online: true, away: "" };
	assertEquals(memberIdentity("irc/alice", present), {
		name: "alice",
		mark: "IRC",
		said: "IRC only",
		network: "irc",
	});
	assertEquals(memberIdentity("alice", { ...present, irc: { state: "rooms", nick: "alice_irc" } }), {
		name: "alice",
		mark: "ROOMS",
		said: "Rooms only",
		network: "rooms",
	});
	assertEquals(memberIdentity("alice", { ...present, irc: { state: "linked", nick: "alice_irc" } }), {
		name: "alice",
		mark: "LINKED",
		said: "Rooms + IRC as alice_irc",
		network: "rooms-linked",
	});
	assertEquals(
		memberIdentity("alice", { ...present, irc: { state: "connecting", nick: "alice_irc" } }).network,
		"rooms-connecting",
	);
	assertEquals(
		memberIdentity("alice", { ...present, irc: { state: "failed", nick: "alice_irc" } }).network,
		"rooms-failed",
	);
});

Deno.test("network treatment keeps an away reason instead of flattening it to presence", () => {
	const away = { online: true, away: "back after lunch" };
	assertEquals(memberDetail(memberIdentity("alice", away), away), "back after lunch");
	const linked = { ...away, irc: { state: "linked" as const, nick: "alice_irc" } };
	assertEquals(memberDetail(memberIdentity("alice", linked), linked), "Rooms + IRC as alice_irc · back after lunch");
	const offline = { online: false, away: "stale reason" };
	assertEquals(memberDetail(memberIdentity("alice", offline), offline), "offline");
});
