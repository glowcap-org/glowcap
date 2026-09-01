// Attach signaling nicks are directory-legal and independent of session nicks.

import { nickRefusal } from "../lib/limits.ts";
import { attachSignalingNick } from "../web/ui/session/attach_signaling_nick.ts";
import { assertEquals } from "./assert.ts";

Deno.test("an attach signaling nick is a legal directory name from the Host designator", () => {
	const nick = attachSignalingNick("aa".repeat(32));
	assertEquals(nickRefusal(nick), null);
	assertEquals(nick.startsWith("s"), true);
	assertEquals(attachSignalingNick(""), "sattach");
	assertEquals(nickRefusal(attachSignalingNick("")), null);
});
