// Shared page addresses retain startup choices and omit private presentation state.
import { assertEquals } from "./assert.ts";
import { directoryAddress, dmAddress, roomAddress } from "../web/ui/route_address.ts";

Deno.test("shared room and directory addresses carry only the DM startup choice", () => {
	const prior = Object.getOwnPropertyDescriptor(globalThis, "location");
	Object.defineProperty(globalThis, "location", {
		configurable: true,
		value: { search: "?dm=relay&pane=settings&unrelated=private" },
	});
	try {
		assertEquals(roomAddress("lobby"), "/room/lobby?dm=relay", "room configuration");
		assertEquals(directoryAddress(), "/directory?dm=relay", "directory configuration");
		assertEquals(dmAddress("grace hopper"), "/dm/grace%20hopper?dm=relay", "direct configuration");
	} finally {
		if (prior) Object.defineProperty(globalThis, "location", prior);
		else Reflect.deleteProperty(globalThis, "location");
	}
});
