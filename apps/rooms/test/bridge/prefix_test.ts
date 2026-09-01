// The namespace one room server hands out to its bridges.
//
// The reservation carries the whole weight here, which is what these are about:
// `nickRefusal` admits `irc/bo` as an ordinary Rooms name, so nothing about a
// name's shape says whether it belongs to a bridge. Only a claim does.

import { BridgePrefixes } from "../../lib/bridge/prefix.ts";
import { MAX_SEAT_PREFIX, nickRefusal } from "../../lib/limits.ts";
import { assertEquals } from "../assert.ts";

Deno.test("a bridge prefix is refused unless it ends at a separator", () => {
	const held = new BridgePrefixes();
	// Without the separator a claim on `irc` swallows `ircfan`, who would be
	// shown as somebody called `fan`. This is the whole reason for the rule.
	assertEquals(held.claim("irc", "a") === null, false);
	assertEquals(held.claim("", "a") === null, false);
	assertEquals(held.claim("a".repeat(MAX_SEAT_PREFIX + 1) + "/", "a") === null, false);
	// One separator, ending it. `a/b/` would claim a namespace inside a namespace
	// and there is no reading of a roster where that is one thing.
	assertEquals(held.claim("a/b/", "a") === null, false);
	assertEquals(held.claim("irc/", "a"), null);
	assertEquals(held.size, 1);
});

Deno.test("two bridges cannot claim overlapping namespaces", () => {
	const held = new BridgePrefixes();
	assertEquals(held.claim("irc/", "irc"), null);
	// Exactly the same, and the same folded differently: both are one namespace.
	assertEquals(held.claim("irc/", "xmpp") === null, false);
	assertEquals(held.claim("IRC/", "xmpp") === null, false);
	// A different one is fine, and the first holder keeps what it had.
	assertEquals(held.claim("xmpp/", "xmpp"), null);
	assertEquals(held.holderOf("irc/bo"), "irc");
	assertEquals(held.holderOf("xmpp/eve"), "xmpp");
	assertEquals(held.holderOf("bo"), null);
	// Re-claiming what you already hold is not a collision with yourself.
	assertEquals(held.claim("irc/", "irc"), null);
	assertEquals(held.size, 2);
});

Deno.test("a released namespace is free, and a bridge that left holds nothing", () => {
	const held = new BridgePrefixes();
	assertEquals(held.claim("irc/", "irc"), null);
	held.release("irc");
	assertEquals(held.holderOf("irc/bo"), null);
	assertEquals(held.nickRefusal("irc/bo"), null);
	// Which is the point: a bridge that went away must not keep a namespace
	// nobody can use, and the name it reserved becomes an ordinary name again.
	assertEquals(held.claim("irc/", "someone-else"), null);
});

Deno.test("a name under a claimed prefix is refused, and one that merely looks like it is not", () => {
	const held = new BridgePrefixes();
	held.claim("irc/", "irc");
	assertEquals(held.nickRefusal("irc/bo") === null, false);
	assertEquals(held.nickRefusal("IRC/bo") === null, false);
	assertEquals(held.nickRefusal("bo"), null);
	// The name the reservation exists for. Rooms' own rules admit it, so without
	// a claim nothing would stop a member taking it and being drawn as somebody
	// arriving from IRC.
	assertEquals(nickRefusal("irc/bo"), null);
	// And a prefix nobody claimed reserves nothing, which is why installing a
	// second bridge is a decision the server has to make rather than discover:
	// this name is ordinary until an XMPP bridge asks for that namespace.
	assertEquals(held.nickRefusal("xmpp/eve"), null);
});
