import { assertEquals } from "@std/assert";
import { devListen } from "./vite-dev-listen.ts";

Deno.test("a missing or blank host stays on loopback and Vite's default allowlist", () => {
	assertEquals(devListen(undefined), { host: "127.0.0.1" });
	assertEquals(devListen(""), { host: "127.0.0.1" });
	assertEquals(devListen("  "), { host: "127.0.0.1" });
});

Deno.test("loopback binds keep Vite's default Host allowlist", () => {
	assertEquals(devListen("127.0.0.1"), { host: "127.0.0.1" });
	assertEquals(devListen("localhost"), { host: "localhost" });
	assertEquals(devListen("::1"), { host: "::1" });
});

Deno.test("a wide bind answers any Host header", () => {
	assertEquals(devListen("0.0.0.0"), { host: "0.0.0.0", allowedHosts: true });
	assertEquals(devListen("::"), { host: "::", allowedHosts: true });
});
