// The name-derived text the interface draws: a chip's initials, its stable
// tint, and the one line under the reader's own name. Pure functions, so the
// cases are exact.

import { assertEquals } from "./assert.ts";
import { footState, hueOf, initials } from "../web/ui/text.ts";

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

// The rail foot's state row says how the reader stands, and the connection
// only when standing cannot be the answer. It was written the other way once:
// any sentence the net layer had written won, so a reader who stepped away
// watched their own standing replaced by whichever directory was reaching a
// locator, and the line under their name showed an address instead.
Deno.test("the foot says the reader's standing on a settled connection", () => {
	assertEquals(footState("connected", "back in ten", true), { said: "back in ten", away: true });
	assertEquals(footState("connected", "", true), { said: "here", away: false });
});

Deno.test("the foot says the phase before a connection settles, never an address", () => {
	assertEquals(footState("connecting", "", true), { said: "connecting…", away: false });
	assertEquals(footState("reconnecting", "back in ten", true), { said: "reconnecting…", away: false });
	assertEquals(footState("disconnected", "", true), { said: "not connected", away: false });
});

Deno.test("with no name granted the foot says the plain connected word", () => {
	assertEquals(footState("connected", "", false), { said: "connected", away: false });
	// A standing is the reader's own, so it is said even before a directory
	// has granted them a name.
	assertEquals(footState("connected", "away", false), { said: "away", away: true });
});
