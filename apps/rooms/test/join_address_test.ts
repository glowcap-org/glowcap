// Join destinations round-trip through fragments without entering HTTP requests.
import { assertEquals } from "./assert.ts";
import { joinAddress, joinAddressOf, joinFields } from "../web/ui/route_address.ts";

Deno.test("join addresses keep capabilities out of the request and preserve named fields", () => {
	const prior = Object.getOwnPropertyDescriptor(globalThis, "location");
	Object.defineProperty(globalThis, "location", {
		configurable: true,
		value: { search: "?dm=relay&room=discard&address=discard" },
	});
	try {
		const capability = "ocapn://room.iroh/s/token?route=one&other=two+#end";
		for (const field of ["room", "address", "directory"] as const) {
			const url = new URL(joinAddress({ [field]: capability }), "https://rooms.test");
			assertEquals(url.pathname + url.search, "/join?dm=relay");
			const read = joinFields(url);
			assertEquals(read[field], capability);
		}
		assertEquals(joinAddress(), "/join?dm=relay");
		const named = new URL(joinAddress({ room: "", address: "", directory: "" }), "https://rooms.test");
		assertEquals(joinFields(named), { room: "", address: "", directory: "" });
		assertEquals(joinFields(new URL("https://rooms.test/join?room=old&address=old")), {
			room: null,
			address: null,
			directory: null,
		});
		const act = joinAddressOf({
			room: { firmness: "named", value: "workshop" },
			address: { firmness: "implied", value: "" },
		});
		assertEquals(joinFields(new URL(act, "https://rooms.test")), {
			room: "workshop",
			address: null,
			directory: "",
		});
	} finally {
		if (prior) Object.defineProperty(globalThis, "location", prior);
		else Reflect.deleteProperty(globalThis, "location");
	}
});
