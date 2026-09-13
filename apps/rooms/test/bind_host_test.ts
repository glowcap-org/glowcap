// Bind-host classification distinguishes wildcard, loopback, and interface-specific addresses.
import { isLoopbackHost, isWildcardHost } from "./support/bind_host.ts";
import { assertEquals } from "./assert.ts";

Deno.test("a wildcard bind is recognized in every spelling of the any-address", () => {
	// The three literals the rooms fronts used to compare against by hand.
	for (const host of ["0.0.0.0", "::", "[::]"]) {
		assertEquals(isWildcardHost(host), true, host);
	}
	// The spellings a literal comparison misses. An operator who writes one of
	// these binds every interface, and a front that reads it as an ordinary
	// address advertises a locator nothing can dial.
	for (
		const host of [
			"0:0:0:0:0:0:0:0",
			"[0:0:0:0:0:0:0:0]",
			"::0",
			"0000:0000:0000:0000:0000:0000:0000:0000",
			"0.0.0.0 ",
		]
	) {
		assertEquals(isWildcardHost(host), true, host);
	}
});

Deno.test("an address that reaches one interface is not a wildcard", () => {
	for (const host of ["127.0.0.1", "::1", "192.168.1.20", "rooms.example", "localhost", "0.0.0.1", "1::"]) {
		assertEquals(isWildcardHost(host), false, host);
	}
});

Deno.test("loopback covers the whole 127 block and both IPv6 spellings", () => {
	for (const host of ["127.0.0.1", "127.1.2.3", "::1", "[::1]", "0:0:0:0:0:0:0:1", "localhost", "LocalHost"]) {
		assertEquals(isLoopbackHost(host), true, host);
	}
	for (const host of ["0.0.0.0", "::", "128.0.0.1", "192.168.1.20", "rooms.example"]) {
		assertEquals(isLoopbackHost(host), false, host);
	}
});
