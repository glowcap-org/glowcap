// Address spaces and the browser permission required to reach a more private network.
import { assertEquals } from "./assert.ts";
import {
	type AddressSpace,
	addressSpace,
	localNetworkBlock,
	type PermissionsQuery,
	reachesLocalNetwork,
} from "../web/ui/local_network.ts";

Deno.test("a browser is asked about the local network when a page reaches a more private space", async () => {
	const spaces: Record<AddressSpace, string[]> = {
		loopback: ["localhost", "app.localhost", "127.0.0.1", "127.1.2.3", "[::1]", "::1"],
		local: ["10.0.0.8", "172.16.0.1", "172.31.9.9", "192.168.1.1", "169.254.1.1", "fd12::1", "fe80::1"],
		public: ["glowcap.org", "172.32.0.1", "11.0.0.1", "193.168.1.1", "2606:4700::1", "localhost.example"],
	};
	for (const [space, hosts] of Object.entries(spaces)) {
		for (const host of hosts) assertEquals(addressSpace(host), space, host);
	}
	const loopback = new URL("http://127.0.0.1:8080/locator");
	const lan = new URL("http://192.168.1.20:8080/locator");
	assertEquals(reachesLocalNetwork(loopback, "glowcap.org"), true);
	assertEquals(reachesLocalNetwork(lan, "glowcap.org"), true);
	assertEquals(reachesLocalNetwork(loopback, "192.168.1.5"), true);
	assertEquals(reachesLocalNetwork(lan, "192.168.1.5"), false);
	assertEquals(reachesLocalNetwork(loopback, "localhost"), false);
	assertEquals(reachesLocalNetwork(lan, "localhost"), false);
	assertEquals(reachesLocalNetwork(new URL("https://rooms.example/"), "glowcap.org"), false);
	assertEquals(reachesLocalNetwork(loopback, undefined), false);
	const asked: string[] = [];
	const chrome: PermissionsQuery = {
		query: (descriptor) => {
			asked.push(descriptor.name);
			return Promise.resolve({ state: "denied" });
		},
	};
	const local = new URL("http://127.0.0.1:8080/locator");
	assertEquals(await localNetworkBlock(local, { page: "glowcap.org", permissions: chrome }), "denied");
	assertEquals(asked, ["local-network-access"]);
	// A local page is never blocked, a public server is not local, and a
	// browser without the permission, or that refuses the question, says nothing.
	assertEquals(await localNetworkBlock(local, { page: "localhost", permissions: chrome }), null);
	assertEquals(
		await localNetworkBlock(new URL("https://rooms.example/locator"), { page: "glowcap.org", permissions: chrome }),
		null,
	);
	assertEquals(await localNetworkBlock(local, { page: "glowcap.org" }), null);
	const firefox: PermissionsQuery = { query: () => Promise.reject(new TypeError("unknown")) };
	assertEquals(await localNetworkBlock(local, { page: "glowcap.org", permissions: firefox }), null);
});
