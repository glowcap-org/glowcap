// Projection cost stays linear while exact held and unheld lines stay distinct.
import { assertEquals } from "../assert.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { initializeApplication } = await import("../support/application.ts");
await initializeApplication();
const { projectionCost } = await import("../support/projection_cost.ts");

Deno.test("managed projection visits conversations and line custody once per pass", () => {
	for (const conversations of [16, 64]) {
		const cost = projectionCost(conversations, 64);
		assertEquals(cost.conversationVisits, conversations);
		assertEquals(cost.lineIdReads, conversations * 32);
	}
});
