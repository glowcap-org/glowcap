// Projection cost stays linear while exact held and unheld lines stay distinct.
import "../support/match_media.ts";
import { assertEquals } from "../assert.ts";
const { initializeApplication } = await import("../support/application.ts");
await initializeApplication();
const { projectionCost } = await import("../support/projection_cost.ts");

Deno.test("managed projection visits conversations and line custody once per pass", () => {
	for (const conversations of [16, 64]) {
		const cost = projectionCost(conversations, 64);
		assertEquals(cost.conversationVisits, conversations);
		assertEquals(cost.lineIdReads, conversations * 32);
		assertEquals(cost.historyWrites, 0);
	}
});

Deno.test("managed projection publishes changed line authority once per conversation", () => {
	for (const conversations of [4, 16]) {
		const cost = projectionCost(conversations, 64, true);
		assertEquals(cost.historyWrites, conversations);
		assertEquals(cost.lineIdReads, conversations * 32);
	}
});
