// The page shows and shares the route each directory was dialed through, in
// every tab that opens the session. The snapshot carries that route per row.
/// <reference lib="dom" />
import "../support/match_media.ts";
import { assertEquals } from "../assert.ts";
import { initializeApplication } from "../support/application.ts";

const { dirId } = await import("../../web/ui/directory.ts");
const { dirAddress } = await import("../../web/ui/page_bootstrap.ts");
await initializeApplication();
const { fixture, room } = await import("./managed_projection/fixture.ts");

const directory = dirId("directory");

Deno.test("a reloaded page opens a held directory at the address the session dialed", () => {
	const f = fixture(room(), ["ocapn://aaaa.iroh"]);
	try {
		const dirs = f.page.projection.get().dirs;
		assertEquals(dirs.get(directory)?.address, "ocapn://aaaa.iroh");
		assertEquals(dirAddress(dirs, directory), "ocapn://aaaa.iroh", "a shared link names the dialed route");
		// A reroute saves a new route, and the next snapshot carries it.
		const rerouted = "ocapn://aaaa.noise-relay?rendezvous-relay=wss%3A%2F%2Frooms.example%2Frelay";
		f.current.addresses = [rerouted];
		f.apply();
		assertEquals(f.page.projection.get().dirs.get(directory)?.address, rerouted);
	} finally {
		f.close();
	}
});

Deno.test("a directory without a dialed address keeps the address the tab holds", () => {
	const f = fixture(room(), [null]);
	try {
		assertEquals(f.page.projection.get().dirs.get(directory)?.address, "");
		assertEquals(dirAddress(f.page.projection.get().dirs, directory), directory, "no address falls back to the id");
		f.current.addresses = ["127.0.0.1:7000"];
		f.apply();
		f.current.addresses = [null];
		f.apply();
		assertEquals(f.page.projection.get().dirs.get(directory)?.address, "127.0.0.1:7000");
	} finally {
		f.close();
	}
});
