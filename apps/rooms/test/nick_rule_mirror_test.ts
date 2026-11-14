// The name rule is written twice: in the Rust application, which the server
// and the page ask, and in `lib/limits.ts`, which a client without the
// application asks. This holds the two to one answer, in the same words, for
// every character a name could carry.

import { assertEquals } from "@std/assert";
import { nickRefusal } from "../lib/limits.ts";
import { nickRefusal as applicationRefusal } from "../web/ui/limits.ts";
import { initializeApplication } from "./support/application.ts";

await initializeApplication();

Deno.test("both name rules answer every character alike", () => {
	const differ: string[] = [];
	for (let point = 0; point <= 0x10ffff; point++) {
		if (point >= 0xd800 && point <= 0xdfff) continue;
		const name = `a${String.fromCodePoint(point)}b`;
		if (nickRefusal(name) !== applicationRefusal(name)) {
			differ.push(`U+${point.toString(16).toUpperCase().padStart(4, "0")}`);
		}
	}
	assertEquals(differ, []);
});

Deno.test("both name rules answer whole names alike", () => {
	const names = ["", "room", "Room", "everyone", "Here", "a".repeat(200), "ordinary", "名前", "a b", "bell\u0007"];
	for (const name of names) {
		assertEquals(nickRefusal(name), applicationRefusal(name), JSON.stringify(name));
	}
});
