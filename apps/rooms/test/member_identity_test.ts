// Member identity is one projection across avatars and the roster: IRC-only
// names are attributed without becoming a second linked-person row, and a
// Rooms member's IRC seat keeps both network and presence facts visible.

import { assertEquals } from "./assert.ts";
import { foreignName, hueOf, initials, memberDetail, memberIdentity } from "../web/ui/member_identity.ts";

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
	// The prefix is the room's, so it is handed in rather than known here.
	const irc = { prefix: "irc/", badge: "IRC", said: "IRC only", scope: "Libera" };
	assertEquals(foreignName("irc/alice", irc), "alice");
	assertEquals(foreignName("alice", irc), null);
	assertEquals(foreignName("irc/", irc), null);
	assertEquals(foreignName("IRC/alice", irc), null);
	// A room that named no bridge has no foreign members, whatever a name looks
	// like, so a Rooms member called `irc/alice` is called that.
	assertEquals(foreignName("irc/alice", undefined), null);
	// And a different bridge's prefix is a different bridge's.
	assertEquals(
		foreignName("irc/alice", { prefix: "xmpp/", badge: "XMPP", said: "XMPP only", scope: "example.org" }),
		null,
	);
	// A bridged person keeps their own initial and their own tint rather than the
	// network's, which is the property that mattered. What changed is who strips:
	// the caller hands in the name a reader sees, because these two cannot tell a
	// roster key from a name and should not guess.
	const shown = (key: string) => foreignName(key, irc) ?? key;
	assertEquals(initials(shown("irc/alice")), "A");
	assertEquals(hueOf(shown("irc/alice")), hueOf("alice"));
	assertEquals(hueOf(shown("irc/bob")), hueOf("bob"));
	assertEquals(hueOf(shown("irc/alice")) === hueOf(shown("irc/bob")), false);
	assertEquals(hueOf("alice").startsWith("var(--avatar-"), true);
});

Deno.test("a roster distinguishes IRC-only, Rooms-only, linked, and unhealthy bridge seats", () => {
	const present = { online: true, away: "" };
	const irc = { prefix: "irc/", badge: "IRC", said: "IRC only", scope: "Libera" };
	assertEquals(memberIdentity("irc/alice", present, irc), {
		name: "alice",
		mark: "IRC",
		said: "IRC only",
		network: "foreign",
	});
	// The seat cases hand in no bridge facts: a seated member is a
	// Rooms member, so a room's foreign prefix has nothing to say about them.
	//
	// Not IRC's words. A bridge writes its own badge and sentence
	// and this reading carries them; asserting IRC's here would only prove that
	// two copies of one vocabulary still agree, which is the arrangement this
	// replaced. Nonsense words fail loudly if anything starts spelling its own.
	assertEquals(
		memberIdentity("alice", {
			...present,
			seat: { network: "Elsewhere", state: "rooms", nick: "alice_there", badge: "HERE", said: "Only here" },
		}, undefined),
		{ name: "alice", mark: "HERE", said: "Only here", network: "rooms" },
	);
	assertEquals(
		memberIdentity("alice", {
			...present,
			seat: {
				network: "Elsewhere",
				state: "linked",
				nick: "alice_there",
				badge: "BOTH",
				said: "Here and Elsewhere as alice_there",
			},
		}, undefined),
		{ name: "alice", mark: "BOTH", said: "Here and Elsewhere as alice_there", network: "rooms-linked" },
	);
	// The link state is the room's fact and the page styles on it, so unlike the
	// words it is not the bridge's to choose.
	assertEquals(
		memberIdentity("alice", {
			...present,
			seat: { network: "Elsewhere", state: "connecting", nick: "a", badge: "X", said: "y" },
		}, undefined).network,
		"rooms-connecting",
	);
	assertEquals(
		memberIdentity("alice", {
			...present,
			seat: { network: "Elsewhere", state: "failed", nick: "a", badge: "X", said: "y" },
		}, undefined).network,
		"rooms-failed",
	);
});

Deno.test("network treatment keeps an away reason instead of flattening it to presence", () => {
	const away = { online: true, away: "back after lunch" };
	assertEquals(memberDetail(memberIdentity("alice", away, undefined), away), "back after lunch");
	const linked = {
		...away,
		seat: {
			network: "Elsewhere",
			state: "linked" as const,
			nick: "alice_there",
			badge: "BOTH",
			said: "Here and Elsewhere as alice_there",
		},
	};
	assertEquals(
		memberDetail(memberIdentity("alice", linked, undefined), linked),
		"Here and Elsewhere as alice_there · back after lunch",
	);
	const offline = { online: false, away: "stale reason" };
	assertEquals(memberDetail(memberIdentity("alice", offline, undefined), offline), "offline");
	// A plain member who is here draws no line at all: the filled pip on their
	// chip has said it, and the chip announces it to a screen reader, so a word
	// under the name would be the same fact twice down a column of names.
	const here = { online: true, away: "" };
	assertEquals(memberDetail(memberIdentity("alice", here, undefined), here), "");
});
