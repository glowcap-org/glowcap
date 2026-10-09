// Attached history invalidation is scoped, coalesced, and retired with the projection that requested it.
/// <reference lib="dom" />
import { assertEquals } from "../assert.ts";
import { parseHistoryChange } from "../../lib/archive/invalidation.ts";
import { MAX_ARCHIVE_CONVERSATION_BYTES } from "../../lib/archive/protocol.ts";

Deno.test("history invalidation admits only whole-account or bounded conversation scopes", () => {
	assertEquals(parseHistoryChange([]), null);
	for (const kind of ["room", "direct"]) {
		assertEquals(parseHistoryChange([kind, "directory", "conversation"]), {
			kind,
			directory: "directory",
			conversation: "conversation",
		});
	}
	for (
		const args of [
			[null],
			["standing", "d", "c"],
			["room", "", "c"],
			["room", 3, "c"],
			["room", "d", "a".repeat(MAX_ARCHIVE_CONVERSATION_BYTES + 1)],
			["direct", "é".repeat(4097), "c"],
			["room", "d", "c", 1],
		]
	) {
		assertEquals(
			(() => {
				try {
					parseHistoryChange(args);
					return false;
				} catch {
					return true;
				}
			})(),
			true,
		);
	}
});
