// What an address names beyond its path round-trips through the fragment and never enters an HTTP request.
import { assertEquals } from "./assert.ts";
import { addressFields, directoryAddress, joinAddress, joinAddressOf, roomAddress } from "../web/ui/route_address.ts";

function joinFields(url: URL): { room: string | null; address: string | null; directory: string | null } {
	const fields = addressFields(url);
	return { room: fields.get("room"), address: fields.get("address"), directory: fields.get("dir") };
}

Deno.test("join, room, and directory addresses keep capabilities out of the request and preserve named fields", () => {
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
		const room = new URL(roomAddress("workshop", { directory: capability }), "https://rooms.test");
		assertEquals(room.pathname + room.search, "/room/workshop?dm=relay");
		assertEquals(addressFields(room).get("dir"), capability);
		const held = new URL(roomAddress("workshop", { private: true }), "https://rooms.test");
		assertEquals(held.pathname + held.search + held.hash, "/room/workshop?dm=relay#private=1");
		const directory = new URL(directoryAddress({ directory: capability }), "https://rooms.test");
		assertEquals(directory.pathname + directory.search, "/directory?dm=relay");
		assertEquals(addressFields(directory).get("dir"), capability);
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
