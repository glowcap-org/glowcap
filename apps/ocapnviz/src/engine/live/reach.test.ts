// A page served over https reaches a trace on its own machine and no other.
import { assertEquals, assertStrictEquals, assertThrows } from "@std/assert";
import { localNetworkBlock, outOfReach, TraceOutOfReach, traceSocketUrl } from "./reach.ts";

Deno.test("a page served over http dials any trace host", () => {
	for (const host of ["127.0.0.1", "localhost", "trace.example", "192.168.1.20"]) {
		assertEquals(traceSocketUrl("http:", host, 9300), `ws://${host}:9300/captp`);
	}
});

Deno.test("an IPv6 host a locator names bare is bracketed into an address a socket accepts", () => {
	for (const host of ["::1", "2001:db8::1", "[2001:db8::1]"]) {
		const address = new URL(traceSocketUrl("http:", host, 9300));
		assertEquals(address.hostname, host.startsWith("[") ? host : `[${host}]`);
		assertEquals(address.port, "9300");
	}
	assertEquals(traceSocketUrl("https:", "::1", 9300), "ws://[::1]:9300/captp");
});

Deno.test("a page served over https dials only its own machine", () => {
	for (const host of ["127.0.0.1", "127.8.0.1", "localhost", "LOCALHOST", "rooms.localhost"]) {
		assertEquals(traceSocketUrl("https:", host, 9300), `ws://${host}:9300/captp`);
	}
	for (const host of ["trace.example", "192.168.1.20", "localhost.example", "1127.0.0.1", "2001:db8::1", ""]) {
		const refused = assertThrows(() => traceSocketUrl("https:", host, 9300), TraceOutOfReach);
		assertEquals(refused.host, host);
	}
});

Deno.test("a refusal is found under the errors that wrap it", () => {
	const refused = new TraceOutOfReach("trace.example");
	assertStrictEquals(outOfReach(refused), refused);
	assertStrictEquals(
		outOfReach(new Error("dial failed", { cause: new Error("socket", { cause: refused }) })),
		refused,
	);
	assertEquals(outOfReach(new Error("dial failed", { cause: "text" })), null);
	assertEquals(outOfReach("text"), null);
});

/** A browser that knows `known` and refuses every other name. */
function browserHolding(known: Record<string, string>, asked: string[] = []) {
	return {
		asked,
		query: ({ name }: { name: string }) => {
			asked.push(name);
			const state = known[name];
			return state == null
				? Promise.reject(new TypeError(`unknown permission ${name}`))
				: Promise.resolve({ state });
		},
	};
}

const website = { protocol: "https:", hostname: "viewer.example" };

Deno.test("a website loaded over https learns what the browser holds about this computer", async () => {
	assertEquals(await localNetworkBlock(website, browserHolding({ "loopback-network": "denied" })), "denied");
	assertEquals(await localNetworkBlock(website, browserHolding({ "loopback-network": "prompt" })), "prompt");
	assertEquals(await localNetworkBlock(website, browserHolding({ "loopback-network": "granted" })), null);
});

Deno.test("the narrower permission answers first, and a browser without it answers the older name", async () => {
	const both = browserHolding({ "loopback-network": "granted", "local-network-access": "denied" });
	assertEquals(await localNetworkBlock(website, both), null);
	assertEquals(both.asked, ["loopback-network"]);
	const older = browserHolding({ "local-network-access": "denied" });
	assertEquals(await localNetworkBlock(website, older), "denied");
	assertEquals(older.asked, ["loopback-network", "local-network-access"]);
});

Deno.test("a browser that knows neither permission, or throws at the question, does not stand in the way", async () => {
	assertEquals(await localNetworkBlock(website, browserHolding({})), null);
	const throwing = {
		query: (): Promise<{ state: string }> => {
			throw new TypeError("no such permission");
		},
	};
	assertEquals(await localNetworkBlock(website, throwing), null);
});

Deno.test("a page this computer serves, or one loaded over http, is never asked", () => {
	const browser = browserHolding({ "loopback-network": "denied" });
	for (
		const page of [
			{ protocol: "https:", hostname: "localhost" },
			{ protocol: "http:", hostname: "viewer.example" },
			{ protocol: "http:", hostname: "127.0.0.1" },
		]
	) {
		assertStrictEquals(localNetworkBlock(page, browser), null);
	}
	assertStrictEquals(localNetworkBlock(undefined, browser), null);
	assertStrictEquals(localNetworkBlock(website, undefined), null);
	assertEquals(browser.asked, []);
});
